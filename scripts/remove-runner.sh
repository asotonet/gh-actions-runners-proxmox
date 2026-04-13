#!/bin/bash
###############################################################################
# remove-runner.sh
# Script para eliminar un GitHub Actions runner y su VM asociada en Proxmox
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
LOG_FILE="$ROOT_DIR/logs/remove-runner-$(date +%Y-%m-%d).log"
mkdir -p "$ROOT_DIR/logs"

###############################################################################
# Funciones
###############################################################################

usage() {
    cat <<EOF
Uso: $0 --name NOMBRE --repo REPOSITORIO [OPCIONES]

Opciones:
  --name NOMBRE          Nombre del runner a eliminar (requerido)
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organización en lugar de repositorio
  --vm-id ID             ID de la VM a eliminar (opcional, se busca automáticamente)
  --keep-vm              No eliminar la VM, solo el runner de GitHub
  --force                Forzar eliminación sin confirmación
  --help                 Mostrar esta ayuda

Ejemplos:
  $0 --name mi-runner --repo usuario/mi-repo
  $0 --name org-runner --org mi-organizacion --force
  $0 --name old-runner --repo usuario/repo --keep-vm
EOF
    exit 0
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

confirm_action() {
    local message="$1"
    
    if [[ "${FORCE:-false}" == "true" ]]; then
        return 0
    fi
    
    echo -n "$message [y/N]: "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        echo "❌ Operación cancelada"
        exit 0
    fi
}

find_runner_id_by_name() {
    local name="$1"
    local repo="$2"
    local org="$3"
    
    local runners
    if [[ -n "$repo" ]]; then
        runners=$(curl -s -X GET "https://api.github.com/repos/$repo/actions/runners" \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28")
    elif [[ -n "$org" ]]; then
        runners=$(curl -s -X GET "https://api.github.com/orgs/$org/actions/runners" \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "X-GitHub-Api-Version: 2022-11-28")
    fi
    
    local runner_id
    runner_id=$(echo "$runners" | jq -r ".runners[] | select(.name==\"$name\") | .id")
    
    if [[ -z "$runner_id" ]]; then
        log "⚠️  Runner '$name' no encontrado en GitHub"
        return 1
    fi
    
    echo "$runner_id"
}

remove_github_runner() {
    local runner_id="$1"
    local repo="$2"
    local org="$3"
    
    log "🗑️  Eliminando runner ID $runner_id de GitHub..."
    
    local url
    if [[ -n "$repo" ]]; then
        url="https://api.github.com/repos/$repo/actions/runners/$runner_id"
    elif [[ -n "$org" ]]; then
        url="https://api.github.com/orgs/$org/actions/runners/$runner_id"
    fi
    
    local response
    response=$(curl -s -X DELETE "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    if [[ $? -eq 0 ]]; then
        log "✅ Runner eliminado de GitHub exitosamente"
        return 0
    else
        log "❌ Error al eliminar runner de GitHub"
        return 1
    fi
}

find_lxc_by_name() {
    local name="$1"
    
    local lxc_list
    lxc_list=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc" "" "GET")
    
    local ct_id
    ct_id=$(echo "$lxc_list" | jq -r ".data[] | select(.name==\"runner-$name\" or .name==\"$name\") | .vmid")
    
    if [[ -z "$ct_id" ]]; then
        log "⚠️  Contenedor LXC para runner '$name' no encontrado en Proxmox"
        return 1
    fi
    
    echo "$ct_id"
}

###############################################################################
# Argumentos
###############################################################################

RUNNER_NAME=""
REPO=""
ORG=""
VM_ID=""
KEEP_VM=false
FORCE=false

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
        --vm-id)
            VM_ID="$2"
            shift 2
            ;;
        --keep-vm)
            KEEP_VM=true
            shift
            ;;
        --force)
            FORCE=true
            shift
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
    log "🗑️  Iniciando eliminación del runner: $RUNNER_NAME"
    log "================================================"
    
    # Confirmación
    if [[ "$KEEP_VM" == "true" ]]; then
        confirm_action "¿Eliminar runner '$RUNNER_NAME' de GitHub (se mantendrá la VM)?"
    else
        confirm_action "¿Eliminar runner '$RUNNER_NAME' y su VM asociada? Esta acción no se puede deshacer"
    fi
    
    # Paso 1: Buscar runner ID en GitHub
    log "🔍 Buscando runner en GitHub..."
    local runner_id
    runner_id=$(find_runner_id_by_name "$RUNNER_NAME" "$REPO" "$ORG")
    
    if [[ $? -eq 0 && -n "$runner_id" ]]; then
        # Paso 2: Eliminar runner de GitHub
        remove_github_runner "$runner_id" "$REPO" "$ORG"
    else
        log "⚠️  Runner no encontrado en GitHub, continuando..."
    fi
    
    # Paso 3: Eliminar contenedor LXC si no se debe mantener
    if [[ "$KEEP_VM" == "false" ]]; then
        log "🔍 Buscando contenedor LXC asociado..."
        
        if [[ -z "$VM_ID" ]]; then
            VM_ID=$(find_lxc_by_name "$RUNNER_NAME")
        fi
        
        if [[ $? -eq 0 && -n "$VM_ID" ]]; then
            log "🗑️  Eliminando contenedor LXC $VM_ID..."
            delete_lxc "$VM_ID"
        else
            log "⚠️  Contenedor LXC no encontrado en Proxmox"
        fi
    fi
    
    log "================================================"
    if [[ "$KEEP_VM" == "true" ]]; then
        log "✅ Runner '$RUNNER_NAME' eliminado de GitHub (LXC mantenido)"
    else
        log "✅ Runner '$RUNNER_NAME' y contenedor LXC eliminados exitosamente"
    fi
    log "================================================"
}

# Ejecutar
main "$@"
