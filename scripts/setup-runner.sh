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
        "PROXMOX_NODE" "GITHUB_TOKEN" "VM_TEMPLATE" "VM_STORAGE"
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

    log "🔧 Creando VM QEMU $vm_id ($vm_name) con cloud-init..."

    # Recursos mínimos optimizados
    local memory="${VM_MEMORY:-1024}"  # 1GB mínimo
    local cores="${VM_CPUS:-1}"        # 1 vCPU
    local disk="${VM_DISK:-8}"         # 8GB suficiente para Docker
    local sockets="${VM_SOCKETS:-1}"

    local ostemplate_param
    if echo "$VM_TEMPLATE" | grep -q ":"; then
        ostemplate_param="$VM_TEMPLATE"
    else
        ostemplate_param="local:iso/${VM_TEMPLATE}"
    fi

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

    # Script cloud-init que se ejecuta al primer arranque
    local ci_script="#cloud-config
hostname: $vm_name
users:
  - name: $RUNNER_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [docker, sudo]
    lock_passwd: false
    plain_text_passwd: RunnerSetup2024!

runcmd:
  - echo '=== Iniciando configuración del runner ==='
  - echo '[1/5] Instalando paquetes esenciales...'
  - apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release git wget jq make build-essential pkg-config libssl-dev python3 python3-pip openssh-client rsync unzip zip tar gzip
  - echo '[2/5] Instalando Docker Engine...'
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  - echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - echo '[3/5] Configurando Docker...'
  - mkdir -p /etc/docker
  - |
    cat > /etc/docker/daemon.json << 'DEOF'
    {
      \"storage-driver\": \"overlay2\",
      \"data-root\": \"/var/lib/docker\",
      \"log-driver\": \"json-file\",
      \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"},
      \"features\": {\"buildkit\": true}
    }
    DEOF
  - systemctl daemon-reload
  - systemctl enable docker
  - systemctl restart docker
  - echo '[4/5] Instalando GitHub Actions runner...'
  - mkdir -p /home/$RUNNER_USER/actions-runner /home/$RUNNER_USER/actions-runner/_work
  - chown $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/actions-runner /home/$RUNNER_USER/actions-runner/_work
  - chmod 755 /home/$RUNNER_USER/actions-runner/_work
  - su - $RUNNER_USER -c \"cd /home/$RUNNER_USER/actions-runner && curl -sL '$download_url' -o actions-runner.tar.gz && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz\"
  - su - $RUNNER_USER -c \"cd /home/$RUNNER_USER/actions-runner && ./config.sh --unattended --url '$github_url' --token '$token' --name '$runner_name' --labels '$labels' --work '_work'\"
  - cd /home/$RUNNER_USER/actions-runner && ./svc.sh install $RUNNER_USER
  - cd /home/$RUNNER_USER/actions-runner && ./svc.sh start
  - chown -R $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/actions-runner
  - chmod -R 750 /home/$RUNNER_USER/actions-runner
  - chmod 755 /home/$RUNNER_USER/actions-runner/_work
  - echo '[5/5] Verificando...'
  - docker run --rm hello-world 2>&1 | head -3 || true
  - echo '=== Configuración completada ==='
  - echo 'RUNNER_SETUP_COMPLETE=true' >> /etc/environment"

    # Guardar cloud-init script para referencia
    echo "$ci_script" > "$ROOT_DIR/logs/cloudinit-${vm_id}.yaml"
    log "💾 Cloud-init guardado: logs/cloudinit-${vm_id}.yaml"

    # Crear VM con clon desde template
    local create_params="vmid=$vm_id"
    create_params+="&name=$vm_name"
    create_params+="&storage=$VM_STORAGE"
    create_params+="&full=1"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$VM_TEMPLATE/clone" "$create_params" "POST")

    if echo "$response" | grep -qi "error\|failed"; then
        log "❌ Error al crear VM"
        log "Response: $response"
        return 1
    fi
    
    log "✅ VM clonada, configurando cloud-init..."
    sleep 5

    # Configurar recursos mínimos
    local config_params="name=$vm_name"
    config_params+="&memory=$memory"
    config_params+="&cores=$cores"
    config_params+="&sockets=$sockets"
    config_params+="&ostype=l26"
    # VirtIO para mejor rendimiento con menos recursos
    config_params+="&agent=enabled=1"
    # Red
    config_params+="&net0=virtio,bridge=vmbr0"
    # Cloud-init drive
    config_params+="&ide2=$VM_STORAGE:cloudinit"
    # Boot order
    config_params+="&boot=order=virtio0"
    # CPU mínimo pero eficiente
    config_params+="&cpu=host"
    # Machine q35 (más moderna y eficiente)
    config_params+="&machine=q35"

    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/config" "$config_params" "PUT")
    
    if echo "$response" | grep -qi '"data"'; then
        log "✅ Recursos configurados: ${cores}vCPU, ${memory}MB RAM"
    fi

    # Configurar cloud-init
    log "📝 Aplicando cloud-init..."
    local ci_params="ciuser=$RUNNER_USER"
    ci_params+="&cipassword=RunnerSetup2024!"
    ci_params+="&searchdomain=local"
    # Codificar script para URL
    local ci_encoded
    ci_encoded=$(echo "$ci_script" | base64 -w 0 2>/dev/null || echo "$ci_script" | base64 | tr -d '\n')
    ci_encoded=$(echo "$ci_encoded" | sed 's/+/%2B/g; s/=/%3D/g; s/\//%2F/g; s/\n/%0A/g')
    ci_params+="&cicustom=vendor%3D$VM_STORAGE%3Asnippets%2Fci-${vm_id}.yaml"

    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/config" "$ci_params" "PUT")

    # Generar cloud-init ISO
    log "🔄 Generando cloud-init ISO..."
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/cloudinit" "" "GET")

    # Iniciar VM
    log "🚀 Iniciando VM..."
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST")
    
    if echo "$response" | grep -qi '"data"'; then
        log "✅ VM iniciada"
    fi

    # Esperar a que cloud-init complete
    log "⏳ Esperando cloud-init (3-5 minutos)..."
    local max_wait=300
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        # Verificar si cloud-init terminó
        local status_response
        status_response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/agent/exec" "" "POST" 2>/dev/null)
        
        # Verificar IP asignada
        local interfaces
        interfaces=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/interfaces" "" "GET" 2>/dev/null)
        local vm_ip
        vm_ip=$(echo "$interfaces" | grep -o '"ip-address":"[0-9.]*"' | head -1 | cut -d: -f2 | tr -d '"')
        
        if [[ -n "$vm_ip" && "$vm_ip" != "127.0.0.1" ]]; then
            log "✅ VM configurada: $vm_ip"
            log "💾 Cloud-init: logs/cloudinit-${vm_id}.yaml"
            break
        fi
        
        if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   ⏳ Configurando... (${elapsed}s/${max_wait}s)"
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done

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
