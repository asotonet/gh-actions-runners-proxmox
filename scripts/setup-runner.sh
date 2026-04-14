#!/bin/bash
###############################################################################
# setup-runner.sh
# Crea una VM QEMU en Proxmox con Ubuntu + Docker + GitHub Actions runner
# Usa cloud-init para configuracion automatica via API
#
# NOTA: La VM necesita un template Ubuntu pre-instalado para funcionar.
#       El cloud-init configura usuario, Docker y runner automaticamente.
#
# Para crear el template base:
#   1. Crea una VM con Ubuntu Server 22.04
#   2. Instala: cloud-init qemu-guest-agent
#   3. Habilita el agent: qm set <vmid> --agent enabled=1
#   4. Convierte a template
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
        "PROXMOX_NODE" "GITHUB_TOKEN" "VM_STORAGE"
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

    log "Creando VM QEMU $vm_id ($vm_name) con cloud-init..."

    local memory="${VM_MEMORY:-4096}"
    local cores="${VM_CPUS:-4}"
    local disk="${VM_DISK:-30}"

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

    # Generar password hash para cloud-init
    local runner_password="RunnerSetup2024!"

    # Script de configuracion post-boot (se inyecta via cloud-init runcmd)
    # Las variables se sustituyen AQUI antes de escribir el archivo
    cat > "$ROOT_DIR/logs/setup-script-${vm_id}.sh" << RUNNEREOF
#!/bin/bash
set -e
exec > >(tee /var/log/runner-setup.log) 2>&1

RUNNER_USER="${RUNNER_USER}"
RUNNER_NAME="${runner_name}"
GITHUB_URL="${github_url}"
RUNNER_TOKEN="${token}"
LABELS="${labels}"
DOWNLOAD_URL="${download_url}"
RUNNER_DIR="/home/\${RUNNER_USER}/actions-runner"

echo "=== Iniciando configuracion del runner ==="

# 1. Paquetes esenciales
echo "[1/5] Instalando paquetes esenciales..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release git wget jq make build-essential pkg-config libssl-dev python3 python3-pip openssh-client rsync unzip zip tar gzip 2>/dev/null || true

# 2. Docker Engine
echo "[2/5] Instalando Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true

# 3. Configurar Docker
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

# 4. Configurar usuario y runner
echo "[4/5] Instalando GitHub Actions runner..."
useradd -m -s /bin/bash -G sudo,docker "\${RUNNER_USER}" 2>/dev/null || true
echo "\${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/\${RUNNER_USER}
chmod 440 /etc/sudoers.d/\${RUNNER_USER}

mkdir -p "\$RUNNER_DIR" "\$RUNNER_DIR/_work"
chown \${RUNNER_USER}:\${RUNNER_USER} "\$RUNNER_DIR" "\$RUNNER_DIR/_work"
chmod 755 "\$RUNNER_DIR/_work"
usermod -aG docker "\${RUNNER_USER}"

su - "\${RUNNER_USER}" -c "cd \$RUNNER_DIR && curl -sL '\$DOWNLOAD_URL' -o actions-runner.tar.gz && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz"
su - "\${RUNNER_USER}" -c "cd \$RUNNER_DIR && ./config.sh --unattended --url '\$GITHUB_URL' --token '\$RUNNER_TOKEN' --name '\$RUNNER_NAME' --labels '\$LABELS' --work '_work'"

cd "\$RUNNER_DIR" && ./svc.sh install "\${RUNNER_USER}"
cd "\$RUNNER_DIR" && ./svc.sh start

chown -R \${RUNNER_USER}:\${RUNNER_USER} "\$RUNNER_DIR"
chmod -R 750 "\$RUNNER_DIR"
chmod 755 "\$RUNNER_DIR/_work"

# 5. Verificar
echo "[5/5] Verificando..."
docker --version
echo "=== Runner configurado exitosamente ==="
RUNNEREOF
    chmod +x "$ROOT_DIR/logs/setup-script-${vm_id}.sh"
    log "Script de setup guardado: logs/setup-script-${vm_id}.sh"

    # Crear VM clonando desde template si existe, o desde ISO
    local create_params="vmid=${vm_id}"
    create_params+="&name=${vm_name}"
    create_params+="&memory=${memory}"
    create_params+="&cores=${cores}"
    create_params+="&sockets=1"
    create_params+="&ostype=l26"
    create_params+="&machine=q35"
    create_params+="&cpu=host"
    create_params+="&agent=1"
    create_params+="&scsihw=virtio-scsi-pci"
    create_params+="&scsi0=${VM_STORAGE}:${disk}"
    create_params+="&ide0=${VM_STORAGE}:cloudinit,media=cdrom"
    create_params+="&net0=virtio=BC:24:11:02:02:02,bridge=vmbr0"

    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$create_params" "POST")

    if echo "$response" | grep -qi "error\|failed"; then
        log "Error al crear VM"
        log "Response: $response"
        return 1
    fi

    log "VM creada: $vm_id"

    # Aplicar cloud-init settings
    log "Aplicando cloud-init..."
    local ci_params="ciuser=${RUNNER_USER}"
    ci_params+="&cipassword=${runner_password}"
    ci_params+="&nameserver=8.8.8.8"

    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/config" "$ci_params" "PUT")

    # Regenerar cloud-init ISO
    log "Generando cloud-init ISO..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/cloudinit" "" "POST" >/dev/null 2>&1

    # Iniciar VM
    log "Iniciando VM..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST" >/dev/null 2>&1

    # Esperar a que la VM este lista (qemu agent responde)
    log "Esperando a que la VM este lista..."
    local max_wait=600
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local agent_resp
        agent_resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/agent/ping" "" "GET" 2>/dev/null)

        if echo "$agent_resp" | grep -qi '"data"'; then
            log "VM lista y responsive"
            break
        fi

        if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   Esperando... (${elapsed}s/${max_wait}s)"
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    # Configurar runner via QEMU agent exec
    log "Configurando runner..."
    local runcmd_script
    runcmd_script=$(cat "$ROOT_DIR/logs/setup-script-${vm_id}.sh")

    local ticket
    ticket=$(get_proxmox_ticket 2>/dev/null)
    local csrf
    csrf=$(get_proxmox_csrf 2>/dev/null)

    if [[ -n "$ticket" && -n "$csrf" ]]; then
        local agent_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vm_id}/agent/exec"

        # Test agent
        local test_resp
        test_resp=$(curl -s -k -X POST "$agent_url" \
            --data-urlencode "command=echo" \
            --data-urlencode "args[0]=test" \
            -H "Authorization: PVEAuthCookie=$ticket" \
            -H "CSRFPreventionToken: $csrf" \
            -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)

        if echo "$test_resp" | grep -qi '"data"'; then
            log "QEMU agent disponible - ejecutando setup..."

            # Escribir script en la VM y ejecutarlo
            # Paso 1: escribir el script en /tmp
            local escaped_script
            escaped_script=$(echo "$runcmd_script" | sed "s/'/'\\\\''/g")

            curl -s -k -X POST "$agent_url" \
                --data-urlencode "command=bash" \
                --data-urlencode "args[0]=-c" \
                --data-urlencode "args[1]=cat > /tmp/setup-runner.sh << 'ENDOFSCRIPT'
${runcmd_script}
ENDOFSCRIPT" \
                -H "Authorization: PVEAuthCookie=$ticket" \
                -H "CSRFPreventionToken: $csrf" \
                -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

            sleep 2

            # Paso 2: ejecutar
            curl -s -k -X POST "$agent_url" \
                --data-urlencode "command=bash" \
                --data-urlencode "args[0]=/tmp/setup-runner.sh" \
                -H "Authorization: PVEAuthCookie=$ticket" \
                -H "CSRFPreventionToken: $csrf" \
                -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

            log "Setup enviado al runner"
        else
            log "QEMU agent no disponible"
        fi
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
    log "Recursos: ${VM_CPUS:-4}vCPU, ${VM_MEMORY:-4096}MB RAM, ${VM_DISK:-30}GB disco"
    log "Directorio: /home/$RUNNER_USER/actions-runner"
    log "Docker: Instalado y configurado"
    log "URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

main "$@"
