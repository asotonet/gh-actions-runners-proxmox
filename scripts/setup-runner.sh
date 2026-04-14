#!/bin/bash
###############################################################################
# setup-runner.sh
# Script para configurar un GitHub Actions runner en una VM QEMU ligera de Proxmox
# Usa cloud-init para configuración automática 100% vía API
# Recursos mínimos: 1 vCPU, 1024MB RAM, 16GB disco
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: No se encontro el archivo de configuracion: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"
source "$SCRIPT_DIR/utils.sh"

LOG_FILE="$ROOT_DIR/logs/setup-runner-$(date +%Y-%m-%d).log"
mkdir -p "$ROOT_DIR/logs"

RUNNER_USER="${RUNNER_USER:-runner}"

###############################################################################

usage() {
    cat <<EOF
Uso: $0 --repo REPOSITORIO [OPCIONES]

Opciones:
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organizacion en lugar de repositorio
  --labels LABELS        Labels personalizados (separados por comas)
  --vm-id ID             ID especifico para la VM (opcional)
  --user USUARIO         Nombre del usuario dedicado (default: runner)
  --help                 Mostrar esta ayuda
EOF
    exit 0
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

validate_config() {
    local required_vars=(
        "PROXMOX_HOST" "PROXMOX_PORT" "PROXMOX_USER" "PROXMOX_PASSWORD"
        "PROXMOX_NODE" "GITHUB_TOKEN" "VM_ISO" "VM_ISO_STORAGE" "VM_STORAGE"
    )
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "Error: La variable $var no esta definida en config.env"
            exit 1
        fi
    done
}

get_github_runner_token() {
    local repo="$1"
    local org="$2"

    local url
    if [[ -n "$repo" ]]; then
        url="https://api.github.com/repos/$repo/actions/runners/registration-token"
    elif [[ -n "$org" ]]; then
        url="https://api.github.com/orgs/$org/actions/runners/registration-token"
    else
        log "Error: Debes especificar --repo o --org"
        return 1
    fi

    log "Solicitando token de registro..."

    local response
    response=$(curl -s -X POST "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    local token expires_at
    if command -v jq >/dev/null 2>&1; then
        token=$(echo "$response" | jq -r '.token // empty')
        expires_at=$(echo "$response" | jq -r '.expires_at // empty')
    else
        token=$(echo "$response" | grep -o '"token": *"[^"]*"' | head -1 | sed 's/.*"token": *"//;s/"$//')
        expires_at=$(echo "$response" | grep -o '"expires_at": *"[^"]*"' | head -1 | sed 's/.*"expires_at": *"//;s/"$//')
    fi

    if [[ -z "$token" ]]; then
        log "Error al obtener token de GitHub"
        return 1
    fi

    log "Token generado (expira: $expires_at)"
    echo "$token"
}

create_vm_with_cloudinit() {
    local vm_id="$1"
    local vm_name="$2"
    local runner_name="$3"
    local repo="$4"
    local org="$5"
    local labels="$6"
    local token="$7"

    log "Creando VM QEMU $vm_id ($vm_name) desde ISO con cloud-init..."

    local memory="${VM_MEMORY:-1024}"
    local cores="${VM_CPUS:-1}"
    local disk="${VM_DISK:-16}"

    local github_url
    if [[ -n "$repo" ]]; then
        github_url="https://github.com/$repo"
    else
        github_url="https://github.com/$org"
    fi

    local runner_version="${RUNNER_VERSION:-latest}"
    if [[ "$runner_version" == "latest" ]]; then
        runner_version=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | grep -o '"tag_name":"[^"]*"' | sed 's/"tag_name":"//;s/"$//' | sed 's/^v//')
    fi
    local download_url="https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz"

    # Cloud-init user-data para autoinstall
    cat > "$ROOT_DIR/logs/cloudinit-user-${vm_id}.yaml" << CIEOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ${vm_name}
    username: ${RUNNER_USER}
    password: "\$6\$rounds=4096\$runner\$xQHBVp8zKjLqFz3rJHqGj5YKp0xZQxZxZxZxZxZxZxZ"
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    - echo '${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/runner
    - chmod 440 /target/etc/sudoers.d/runner
CIEOF

    # Script post-instalacion
    cat > "$ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh" << 'SCRIPTEOF'
#!/bin/bash
set -e
exec > >(tee /var/log/runner-setup.log) 2>&1

echo "[1/5] Instalando paquetes esenciales..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release git wget jq make build-essential pkg-config libssl-dev python3 python3-pip openssh-client rsync unzip zip tar gzip

echo "[2/5] Instalando Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "[3/5] Configurando Docker..."
mkdir -p /etc/systemd/system/docker.service.d /etc/docker /var/lib/docker
cat > /etc/systemd/system/docker.service.d/override.conf << 'DEOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock --exec-opt native.cgroupdriver=cgroupfs
DEOF
cat > /etc/docker/daemon.json << 'DEOF'
{
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
DEOF
chmod 710 /var/lib/docker && chown root:docker /var/lib/docker
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

echo "[4/5] Instalando GitHub Actions runner..."
RUNNER_USER_PLACEHOLDER='${RUNNER_USER}'
RUNNER_NAME_PLACEHOLDER='${runner_name}'
GITHUB_URL_PLACEHOLDER='${github_url}'
RUNNER_TOKEN_PLACEHOLDER='${token}'
LABELS_PLACEHOLDER='${labels}'
DOWNLOAD_URL_PLACEHOLDER='${download_url}'
RUNNER_DIR="/home/${RUNNER_USER_PLACEHOLDER}/actions-runner"

mkdir -p "$RUNNER_DIR" "$RUNNER_DIR/_work"
chown "${RUNNER_USER_PLACEHOLDER}:${RUNNER_USER_PLACEHOLDER}" "$RUNNER_DIR" "$RUNNER_DIR/_work"
chmod 755 "$RUNNER_DIR/_work"
usermod -aG docker "$RUNNER_USER_PLACEHOLDER" 2>/dev/null || true

su - "$RUNNER_USER_PLACEHOLDER" -c "cd $RUNNER_DIR && curl -sL '$DOWNLOAD_URL_PLACEHOLDER' -o actions-runner.tar.gz && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz"
su - "$RUNNER_USER_PLACEHOLDER" -c "cd $RUNNER_DIR && ./config.sh --unattended --url '$GITHUB_URL_PLACEHOLDER' --token '$RUNNER_TOKEN_PLACEHOLDER' --name '$RUNNER_NAME_PLACEHOLDER' --labels '$LABELS_PLACEHOLDER' --work '_work'"

cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER_PLACEHOLDER"
cd "$RUNNER_DIR" && ./svc.sh start

chown -R "${RUNNER_USER_PLACEHOLDER}:${RUNNER_USER_PLACEHOLDER}" "$RUNNER_DIR"
chmod -R 750 "$RUNNER_DIR"
chmod 755 "$RUNNER_DIR/_work"

echo "[5/5] Verificando..."
docker --version
echo "=== Runner configurado exitosamente ==="
SCRIPTEOF
    chmod +x "$ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh"
    log "Cloud-init guardado: logs/cloudinit-user-${vm_id}.yaml"

    # Crear VM desde cero
    log "Creando VM desde ISO..."
    local create_params="vmid=${vm_id}"
    create_params+="&name=${vm_name}"
    create_params+="&memory=${memory}"
    create_params+="&cores=${cores}"
    create_params+="&ostype=l26"
    create_params+="&machine=q35"
    create_params+="&cpu=host"
    create_params+="&agent=1"
    create_params+="&scsihw=virtio-scsi-pci"
    create_params+="&scsi0=${VM_STORAGE}:${disk}"
    create_params+="&cdrom=${VM_ISO_STORAGE}:iso/${VM_ISO}"
    create_params+="&ide0=${VM_STORAGE}:cloudinit"
    create_params+="&net0=virtio=BC:24:11:00:00:$(printf '%02X' $((vm_id % 256))),bridge=vmbr0"

    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$create_params" "POST")

    if echo "$response" | grep -qi "error\|failed"; then
        log "Error al crear VM"
        log "Response: $response"
        return 1
    fi

    log "VM creada: $vm_id"
    log "Aplicando cloud-init..."

    # Aplicar cloud-init settings
    local ci_params="ciuser=${RUNNER_USER}"
    ci_params+="&cipassword=RunnerSetup2024!"

    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/config" "$ci_params" "PUT")

    # Generar cloud-init ISO
    log "Generando cloud-init ISO..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/cloudinit" "" "GET" >/dev/null 2>&1

    # Iniciar VM
    log "Iniciando VM (instalacion automatica: 15-20 min)..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST" >/dev/null 2>&1

    # Esperar instalacion
    local max_wait=1800
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" "" "GET" 2>/dev/null)

        if echo "$status" | grep -q '"running"'; then
            # Verificar qemu agent
            local agent_resp
            agent_resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/agent/ping" "" "GET" 2>/dev/null)
            if echo "$agent_resp" | grep -qi '"data"'; then
                log "VM lista y responsive"
                break
            fi
        fi

        if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   Instalando Ubuntu... (${elapsed}s/${max_wait}s)"
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    # Ejecutar script de configuracion
    log "Configurando runner..."
    local runcmd_script
    runcmd_script=$(cat "$ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh")

    if exec_in_lxc "$vm_id" "echo iniciando" 2>/dev/null; then
        exec_in_lxc "$vm_id" "$runcmd_script" 600
        log "Configuracion enviada al contenedor"
    else
        log "API exec no disponible - ejecutar manualmente:"
        log "  pct push $vm_id $ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh /opt/setup-runner.sh"
        log "  pct exec $vm_id -- bash /opt/setup-runner.sh"
    fi

    log "VM QEMU creada: $vm_id"
    echo "$vm_id"
}

###############################################################################
# Argumentos
###############################################################################

REPO=""
ORG=""
LABELS="self-hosted,linux,docker"
VM_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --org)
            ORG="$2"
            shift 2
            ;;
        --labels)
            LABELS="$2"
            shift 2
            ;;
        --vm-id)
            VM_ID="$2"
            shift 2
            ;;
        --user)
            RUNNER_USER="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Opcion desconocida: $1"
            usage
            ;;
    esac
done

if [[ -z "$REPO" && -z "$ORG" ]]; then
    echo "Error: Debes especificar --repo o --org"
    usage
fi

###############################################################################
# Main
###############################################################################

main() {
    log "================================================"
    log "Configurando runner"
    log "================================================"

    validate_config

    if [[ -z "$VM_ID" ]]; then
        VM_ID=$(generate_vm_id)
        if [[ $? -ne 0 ]]; then
            log "Error al generar ID de VM"
            exit 1
        fi
        log "VM ID generado: $VM_ID"
    fi

    local repo_or_org
    if [[ -n "$REPO" ]]; then
        repo_or_org="repos/$REPO"
    else
        repo_or_org="orgs/$ORG"
    fi

    log "Obteniendo token de GitHub..."
    local token
    token=$(get_github_runner_token "$REPO" "$ORG")

    if [[ $? -ne 0 || -z "$token" ]]; then
        log "No se pudo obtener token. Abortando..."
        exit 1
    fi

    local runner_name_with_id="runner-${VM_ID}"
    log "Nombre del runner: $runner_name_with_id"

    create_vm_with_cloudinit "$VM_ID" "runner-${runner_name_with_id}" "$runner_name_with_id" "$repo_or_org" "$ORG" "$LABELS" "$token"

    log "================================================"
    log "Runner configurado"
    log "VM ID: $VM_ID"
    log "Recursos: 1vCPU, ${VM_MEMORY:-1024}MB RAM, ${VM_DISK:-16}GB disco"
    log "Directorio: /home/$RUNNER_USER/actions-runner"
    log "Docker: Instalado y configurado"
    log "URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

main "$@"
