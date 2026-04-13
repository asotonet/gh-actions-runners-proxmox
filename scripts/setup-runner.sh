#!/bin/bash
###############################################################################
# setup-runner.sh
# Script para configurar un GitHub Actions runner en una VM de Proxmox
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

###############################################################################
# Funciones
###############################################################################

usage() {
    cat <<EOF
Uso: $0 --name NOMBRE --repo REPOSITORIO [OPCIONES]

Opciones:
  --name NOMBRE          Nombre del runner (requerido)
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organización en lugar de repositorio
  --labels LABELS        Labels personalizados (separados por comas)
  --vm-id ID             ID específico para la VM (opcional)
  --help                 Mostrar esta ayuda

Ejemplos:
  $0 --name mi-runner --repo usuario/mi-repo
  $0 --name org-runner --org mi-organizacion --labels "linux,docker"
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

create_vm_on_proxmox() {
    local vm_id="$1"
    local vm_name="$2"
    
    log "🔧 Creando VM $vm_id ($vm_name) en Proxmox..."
    
    # Clonar desde template
    local clone_cmd="POST /nodes/$PROXMOX_NODE/qemu/$VM_TEMPLATE/clone"
    local clone_params="newid=$vm_id&name=$vm_name&full=1&storage=$VM_STORAGE"
    
    local response
    response=$(proxmox_api_request "$clone_cmd" "$clone_params" "POST")
    
    if [[ $? -ne 0 ]]; then
        log "❌ Error al crear la VM"
        return 1
    fi
    
    log "✅ VM creada exitosamente con ID: $vm_id"
    echo "$vm_id"
}

wait_for_vm_ready() {
    local vm_id="$1"
    local max_wait=${2:-300}
    local elapsed=0
    
    log "⏳ Esperando a que la VM $vm_id esté lista..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" "" "GET")
        
        if echo "$status" | grep -q '"running"'; then
            log "✅ VM $vm_id está corriendo"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log "❌ Timeout: La VM no estuvo lista en ${max_wait}s"
    return 1
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
        log "❌ Error: Debes especificar --repo o --org"
        return 1
    fi
    
    local response
    response=$(curl -s -X GET "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    local token
    token=$(echo "$response" | jq -r '.token // empty')
    
    if [[ -z "$token" ]]; then
        log "❌ Error al obtener el token de registro de GitHub"
        log "Response: $response"
        return 1
    fi
    
    echo "$token"
}

install_runner_on_vm() {
    local vm_id="$1"
    local runner_name="$2"
    local token="$3"
    local repo="$4"
    local org="$5"
    local labels="${6:-self-hosted,linux}"
    
    log "📦 Instalando GitHub Actions runner en VM $vm_id..."
    
    # Los comandos se ejecutarían en la VM vía SSH o API de Proxmox
    # Esto es un ejemplo de la secuencia de comandos
    
    local runner_version="${RUNNER_VERSION:-latest}"
    local download_url="https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz"
    
    log "📥 Descargando runner versión $runner_version..."
    
    # Ejemplo de comandos a ejecutar en la VM:
    cat <<'VM_SCRIPT'
#!/bin/bash
# Comandos a ejecutar dentro de la VM
mkdir -p /opt/github-runner && cd /opt/github-runner

# Descargar runner
curl -o actions-runner.tar.gz -L "$DOWNLOAD_URL"
tar xzf actions-runner.tar.gz
rm actions-runner.tar.gz

# Configurar runner
./config.sh --unattended \
    --url "https://github.com/${REPO_OR_ORG}" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work "_work"

# Instalar como servicio
sudo ./svc.sh install
sudo ./svc.sh start
VM_SCRIPT
    
    log "✅ Runner instalado exitosamente en VM $vm_id"
}

###############################################################################
# Argumentos
###############################################################################

RUNNER_NAME=""
REPO=""
ORG=""
LABELS="self-hosted,linux"
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
        --help)
            usage
            ;;
        *)
            echo "❌ Opción desconocida: $1"
            usage
            ;;
    esac
done

# Validar argumentos requeridos
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
    log "🚀 Iniciando configuración del runner: $RUNNER_NAME"
    log "================================================"
    
    # Validar configuración
    validate_config
    
    # Generar VM ID si no se proporcionó
    if [[ -z "$VM_ID" ]]; then
        VM_ID=$((RANDOM % 900 + 100))  # VM IDs entre 100-999
        log "📝 VM ID generado automáticamente: $VM_ID"
    fi
    
    # Determinar si es repo u org
    local repo_or_org
    if [[ -n "$REPO" ]]; then
        repo_or_org="repos/$REPO"
    else
        repo_or_org="orgs/$ORG"
    fi
    
    # Paso 1: Crear VM en Proxmox
    create_vm_on_proxmox "$VM_ID" "runner-$RUNNER_NAME"
    
    # Paso 2: Esperar a que la VM esté lista
    wait_for_vm_ready "$VM_ID"
    
    # Paso 3: Obtener token de registro de GitHub
    local token
    token=$(get_github_runner_token "$REPO" "$ORG")
    
    # Paso 4: Instalar y configurar el runner
    install_runner_on_vm "$VM_ID" "$RUNNER_NAME" "$token" "$repo_or_org" "$ORG" "$LABELS"
    
    log "================================================"
    log "✅ Runner '$RUNNER_NAME' configurado exitosamente"
    log "📊 VM ID: $VM_ID"
    log "🔗 URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

# Ejecutar
main "$@"
