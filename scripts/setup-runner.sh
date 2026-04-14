#!/bin/bash
###############################################################################
# setup-runner.sh
# Script para configurar un GitHub Actions runner en una VM QEMU ligera de Proxmox
# Usa cloud-init para configuración automática 100% vía API
# Recursos mínimos: 1 vCPU, 1024MB RAM, 8GB disco
###############################################################################

set -euo pipefail

# Directorio raíz del proyecto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Cargar configuración
CONFIG_FILE="$ROOT_DIR/config/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Error: No se encontró el archivo de configuración: $CONFIG_FILE"
    echo "💡 Copia config/config.example.env a config/config.env y configura tus credenciales"
    exit 1
fi

source "$CONFIG_FILE"

# Cargar funciones auxiliares
source "$SCRIPT_DIR/utils.sh"

# Configurar logging
LOG_FILE="$ROOT_DIR/logs/setup-runner-$(date +%Y-%m-%d).log"
mkdir -p "$ROOT_DIR/logs"

# Nombre del usuario dedicado para el runner
RUNNER_USER="${RUNNER_USER:-runner}"

###############################################################################
# Funciones
###############################################################################

usage() {
    cat <<EOF
Uso: $0 --name NOMBRE --repo REPOSITORIO [OPCIONES]

Opciones:
  --name NOMBRE          Nombre del runner (se usará runner-VM_ID)
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organización en lugar de repositorio
  --labels LABELS        Labels personalizados (separados por comas)
  --vm-id ID             ID específico para la VM (opcional)
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
            echo "❌ Error: La variable $var no está definida en config.env"
            exit 1
        fi
    done
}

get_github_runner_token() {
    local repo="$1"
    local org="$2"
    local runner_name="$3"
    
    local url
    if [[ -n "$repo" ]]; then
        url="https://api.github.com/repos/$repo/actions/runners/registration-token"
    elif [[ -n "$org" ]]; then
        url="https://api.github.com/orgs/$org/actions/runners/registration-token"
    else
        log "❌ Error: Debes especificar --repo o --org"
        return 1
    fi
    
    log "🔑 Solicitando token de registro..."
    
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
        log "❌ Error al obtener token de GitHub"
        return 1
    fi
    
    log "✅ Token generado (expira: $expires_at)"
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

    log "🔧 Creando VM QEMU $vm_id ($vm_name) desde ISO con cloud-init..."

    # Recursos mínimos optimizados
    local memory="${VM_MEMORY:-1024}"
    local cores="${VM_CPUS:-1}"
    local disk="${VM_DISK:-16}"
    local sockets="${VM_SOCKETS:-1}"

    # Determinar URL de GitHub
    local github_url
    if [[ -n "$repo" ]]; then
        github_url="https://github.com/$repo"
    else
        github_url="https://github.com/$org"
    fi
    
    # Obtener versión del runner
    local runner_version="${RUNNER_VERSION:-latest}"
    if [[ "$runner_version" == "latest" ]]; then
        runner_version=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | grep -o '"tag_name":"[^"]*"' | sed 's/"tag_name":"//;s/"$//' | sed 's/^v//')
    fi
    local download_url="https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz"

    # Cloud-init user-data para autoinstall + configuración post-instalación
    local cloudinit_user="#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: $vm_name
    username: $RUNNER_USER
    password: \"\$6\$rounds=4096\$runner\$xQHBVp8zKjLqFz3rJHqGj5YKp0xZQxZxZxZxZxZxZxZ\"
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    - echo '$RUNNER_USER ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/runner
    - chmod 440 /target/etc/sudoers.d/runner
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y ca-certificates curl gnupg lsb-release git wget jq make build-essential pkg-config libssl-dev python3 python3-pip openssh-client rsync unzip zip tar gzip
    - curtin in-target --target=/target -- install -m 0755 -d /etc/apt/keyrings
    - curtin in-target --target=/target -- curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    - curtin in-target --target=/target -- chmod a+r /etc/apt/keyrings/docker.gpg
    - curtin in-target --target=/target -- sh -c 'echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list'
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    - curtin in-target --target=/target -- systemctl enable docker
  error-commands:
    - sh -c 'cat /var/log/installer/syslog'
"

    # Script post-instalación para configurar runner
    local cloudinit_runcmd="#!/bin/bash
set -e
exec > >(tee /var/log/runner-setup.log) 2>&1

RUNNER_USER='$RUNNER_USER'
RUNNER_NAME='$runner_name'
GITHUB_URL='$github_url'
RUNNER_TOKEN='$token'
LABELS='$labels'
RUNNER_DIR=\"/home/\${RUNNER_USER}/actions-runner\"
DOWNLOAD_URL='$download_url'

echo '=== Configurando runner==='

# Configurar Docker
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DEOF'
{
  \"storage-driver\": \"overlay2\",
  \"data-root\": \"/var/lib/docker\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"},
  \"features\": {\"buildkit\": true}
}
DEOF

systemctl daemon-reload
systemctl restart docker

# Crear usuario si no existe
useradd -m -s /bin/bash -G sudo,docker \$RUNNER_USER 2>/dev/null || true
echo '\${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/\${RUNNER_USER}
chmod 440 /etc/sudoers.d/\${RUNNER_USER}

# Instalar runner
mkdir -p \$RUNNER_DIR \$RUNNER_DIR/_work
chown \$RUNNER_USER:\$RUNNER_USER \$RUNNER_DIR \$RUNNER_DIR/_work
chmod 755 \$RUNNER_DIR/_work

su - \$RUNNER_USER -c \"cd \$RUNNER_DIR && curl -sL '\$DOWNLOAD_URL' -o actions-runner.tar.gz && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz\"
su - \$RUNNER_USER -c \"cd \$RUNNER_DIR && ./config.sh --unattended --url '\$GITHUB_URL' --token '\$RUNNER_TOKEN' --name '\$RUNNER_NAME' --labels '\$LABELS' --work '_work'\"

cd \$RUNNER_DIR && ./svc.sh install \$RUNNER_USER
cd \$RUNNER_DIR && ./svc.sh start

chown -R \$RUNNER_USER:\$RUNNER_USER \$RUNNER_DIR
chmod -R 750 \$RUNNER_DIR
chmod 755 \$RUNNER_DIR/_work

echo '=== Runner configurado ==='
"

    # Guardar cloud-init scripts
    echo "$cloudinit_user" > "$ROOT_DIR/logs/cloudinit-user-${vm_id}.yaml"
    echo "$cloudinit_runcmd" > "$ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh"
    chmod +x "$ROOT_DIR/logs/cloudinit-runcmd-${vm_id}.sh"
    log "💾 Cloud-init guardado: logs/cloudinit-user-${vm_id}.yaml"

    # Crear VM desde cero
    log "📦 Creando VM desde ISO..."
    local create_params="vmid=$vm_id"
    create_params+="&name=$vm_name"
    create_params+="&memory=$memory"
    create_params+="&cores=$cores"
    create_params+="&sockets=$sockets"
    create_params+="&ostype=l26"
    create_params+="&machine=q35"
    create_params+="&cpu=host"
    create_params+="&agent=enabled=1"
    # Disco
    create_params+="&scsihw=virtio-scsi-pci"
    create_params+="&scsi0=$VM_STORAGE:${disk}"
    # CD-ROM con ISO de Ubuntu
    create_params+="&ide2=$VM_ISO_STORAGE:iso/$VM_ISO,media=cdrom"
    # Cloud-init drive
    create_params+="&ide0=$VM_STORAGE:cloudinit"
    # Boot from CD-ROM first
    create_params+="&boot=order=ide2;scsi0"
    # Red
    create_params+="&net0=virtio,bridge=vmbr0"

    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$create_params" "POST")

    if echo "$response" | grep -qi "error\|failed"; then
        log "❌ Error al crear VM"
        log "Response: $response"
        return 1
    fi

    log "✅ VM creada: $vm_id"
    log "📝 Cloud-init configurado"
    log "⏳ Iniciando instalación (15-20 minutos)..."
    
    # Iniciar VM
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST" >/dev/null 2>&1

    # Esperar a que la instalación termine
    local max_wait=1800  # 30 minutos
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" "" "GET" 2>/dev/null)
        
        # Verificar si cloud-init terminó
        if echo "$status" | grep -q '"running"'; then
            # Intentar ejecutar comando para verificar que está listo
            local test_response
            test_response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/agent/exec" '{"command":"echo"}" "POST" 2>/dev/null)
            
            if echo "$test_response" | grep -qi '"data"'; then
                log "✅ VM lista y responsive"
                break
            fi
        fi
        
        if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   ⏳ Instalando Ubuntu... (${elapsed}s/${max_wait}s)"
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done

    # Ejecutar script de configuración del runner
    log "🚀 Configurando runner..."
    exec_in_lxc "$vm_id" "$cloudinit_runcmd" 600

    log "✅ VM QEMU creada: $vm_id"
    echo "$vm_id"
}

###############################################################################
# Argumentos
###############################################################################

RUNNER_NAME=""
REPO=""
ORG=""
LABELS="self-hosted,linux,docker"
VM_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            RUNNER_NAME="$2"
            shift 2
            ;;
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
            echo "❌ Opción desconocida: $1"
            usage
            ;;
    esac
done

if [[ -z "$RUNNER_NAME" ]]; then
    echo "❌ Error: Debes especificar el nombre del runner con --name"
    usage
fi

if [[ -z "$REPO" && -z "$ORG" ]]; then
    echo "❌ Error: Debes especificar --repo o --org"
    usage
fi

###############################################################################
# Main
###############################################################################

main() {
    log "================================================"
    log "🚀 Configurando runner: $RUNNER_NAME"
    log "👤 Usuario: $RUNNER_USER"
    log "================================================"
    
    validate_config
    
    if [[ -z "$VM_ID" ]]; then
        VM_ID=$(generate_vm_id)
        if [[ $? -ne 0 ]]; then
            log "❌ Error al generar ID de VM"
            exit 1
        fi
        log "📝 VM ID generado: $VM_ID"
    fi
    
    local repo_or_org
    if [[ -n "$REPO" ]]; then
        repo_or_org="repos/$REPO"
    else
        repo_or_org="orgs/$ORG"
    fi
    
    # Obtener token de GitHub
    log "🔑 Obteniendo token de GitHub..."
    local token
    token=$(get_github_runner_token "$REPO" "$ORG" "$RUNNER_NAME")
    
    if [[ $? -ne 0 || -z "$token" ]]; then
        log "❌ No se pudo obtener token. Abortando..."
        exit 1
    fi
    
    local runner_name_with_id="runner-${VM_ID}"
    log "📝 Nombre del runner: $runner_name_with_id"
    
    # Crear VM con cloud-init
    create_vm_with_cloudinit "$VM_ID" "runner-${runner_name_with_id}" "$runner_name_with_id" "$repo_or_org" "$ORG" "$LABELS" "$token"
    
    log "================================================"
    log "✅ Runner '$runner_name_with_id' configurado"
    log "📊 VM ID: $VM_ID"
    log "💻 Recursos: 1vCPU, 1024MB RAM, 8GB disco"
    log "🏠 Directorio: /home/$RUNNER_USER/actions-runner"
    log "🐳 Docker: Instalado y configurado"
    log "🔗 URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

main "$@"
