#!/bin/bash
###############################################################################
# check-runners.sh
# Script para verificar el estado de los GitHub Actions runners
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
LOG_FILE="$ROOT_DIR/logs/check-runners-$(date +%Y-%m-%d).log"
mkdir -p "$ROOT_DIR/logs"

###############################################################################
# Funciones
###############################################################################

usage() {
    cat <<EOF
Uso: $0 [OPCIONES]

Opciones:
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO
  --org ORGANIZACION     Organización
  --status ESTADO        Filtrar por estado (online, offline, all)
  --detailed             Mostrar información detallada
  --json                 Salida en formato JSON
  --help                 Mostrar esta ayuda

Ejemplos:
  $0 --repo usuario/mi-repo
  $0 --org mi-organizacion --status online
  $0 --repo usuario/mi-repo --detailed
  $0 --org mi-organizacion --json
EOF
    exit 0
}

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

get_repo_runners() {
    local repo="$1"
    
    local response
    response=$(curl -s -X GET "https://api.github.com/repos/$repo/actions/runners" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    echo "$response"
}

get_org_runners() {
    local org="$1"
    
    local response
    response=$(curl -s -X GET "https://api.github.com/orgs/$org/actions/runners" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    echo "$response"
}

display_runners_table() {
    local runners_json="$1"
    local detailed="$2"
    
    local runners
    runners=$(echo "$runners_json" | jq -r '.runners // []')
    
    local count
    count=$(echo "$runners" | jq 'length')
    
    if [[ $count -eq 0 ]]; then
        echo "📝 No hay runners registrados"
        return 0
    fi
    
    # Contadores por estado
    local online=0
    local offline=0
    
    echo "$runners" | jq -r '.[] | .status' | while read -r status; do
        if [[ "$status" == "online" ]]; then
            online=$((online + 1))
        else
            offline=$((offline + 1))
        fi
    done
    
    echo "================================================"
    echo "📊 Resumen de Runners"
    echo "================================================"
    echo "Total: $count | 🟢 Online: $online | 🔴 Offline: $offline"
    echo "================================================"
    echo ""
    
    # Tabla de runners
    if [[ "$detailed" == "true" ]]; then
        printf "%-5s | %-20s | %-10s | %-15s | %-25s | %-10s\n" "ID" "Nombre" "Estado" "Sistema Op." "Labels" "Ocupado"
        printf "%-5s-+-%-20s-+-%-10s-+-%-15s-+-%-25s-+-%-10s\n" "-----" "--------------------" "----------" "---------------" "-------------------------" "----------"
        
        echo "$runners" | jq -r '.[] | "\(.id) | \(.name) | \(.status) | \(.os) | \(.labels | map(.name) | join(",")) | \(.busy)"' | \
        while IFS='|' read -r id name status os labels busy; do
            local status_icon
            if [[ "$status" == "online" ]]; then
                status_icon="🟢"
            else
                status_icon="🔴"
            fi
            
            printf "%-5s | %-20s | ${status_icon} %-8s | %-15s | %-25s | %-10s\n" \
                "$(echo "$id" | xargs)" \
                "$(echo "$name" | xargs)" \
                "$(echo "$status" | xargs)" \
                "$(echo "$os" | xargs)" \
                "$(echo "$labels" | xargs)" \
                "$(echo "$busy" | xargs)"
        done
    else
        printf "%-5s | %-25s | %-10s | %-10s\n" "ID" "Nombre" "Estado" "Ocupado"
        printf "%-5s-+-%-25s-+-%-10s-+-%-10s\n" "-----" "-------------------------" "----------" "----------"
        
        echo "$runners" | jq -r '.[] | "\(.id) | \(.name) | \(.status) | \(.busy)"' | \
        while IFS='|' read -r id name status busy; do
            local status_icon
            if [[ "$status" == "online" ]]; then
                status_icon="🟢"
            else
                status_icon="🔴"
            fi
            
            printf "%-5s | %-25s | ${status_icon} %-8s | %-10s\n" \
                "$(echo "$id" | xargs)" \
                "$(echo "$name" | xargs)" \
                "$(echo "$status" | xargs)" \
                "$(echo "$busy" | xargs)"
        done
    fi
    
    echo ""
}

display_runners_json() {
    local runners_json="$1"
    
    echo "$runners_json" | jq '.'
}

check_vms_status() {
    echo ""
    echo "================================================"
    echo "🖥️  Estado de VMs en Proxmox"
    echo "================================================"
    
    local vms
    vms=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "" "GET")
    
    local runner_vms
    runner_vms=$(echo "$vms" | jq -r '.data[] | select(.name | test("runner")) | "\(.vmid) | \(.name) | \(.status) | \(.maxmem // 0) | \(.maxdisk // 0)"')
    
    if [[ -z "$runner_vms" ]]; then
        echo "📝 No hay VMs de runners encontradas"
        return 0
    fi
    
    printf "%-10s | %-25s | %-10s | %-15s | %-15s\n" "VM ID" "Nombre" "Estado" "Memoria" "Disco"
    printf "%-10s-+-%-25s-+-%-10s-+-%-15s-+-%-15s\n" "----------" "-------------------------" "----------" "---------------" "---------------"
    
    echo "$runner_vms" | while IFS='|' read -r vmid name status mem disk; do
        local status_icon
        if [[ "$status" == "running" ]]; then
            status_icon="🟢"
        else
            status_icon="⚫"
        fi
        
        local mem_mb=$((mem / 1024 / 1024))
        local disk_gb=$((disk / 1024 / 1024 / 1024))
        
        printf "%-10s | %-25s | ${status_icon} %-8s | %-14sMB | %-14sGB\n" \
            "$(echo "$vmid" | xargs)" \
            "$(echo "$name" | xargs)" \
            "$(echo "$status" | xargs)" \
            "$mem_mb" \
            "$disk_gb"
    done
    
    echo ""
}

###############################################################################
# Argumentos
###############################################################################

REPO=""
ORG=""
STATUS_FILTER="all"
DETAILED=false
JSON_OUTPUT=false

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
        --status)
            STATUS_FILTER="$2"
            shift 2
            ;;
        --detailed)
            DETAILED=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
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

# Validar argumentos
if [[ -z "$REPO" && -z "$ORG" ]]; then
    echo "❌ Error: Debes especificar --repo o --org"
    usage
fi

if [[ "$STATUS_FILTER" != "all" && "$STATUS_FILTER" != "online" && "$STATUS_FILTER" != "offline" ]]; then
    echo "❌ Error: Estado inválido. Debe ser: all, online u offline"
    exit 1
fi

###############################################################################
# Main
###############################################################################

main() {
    log "================================================"
    log "🔍 Verificando estado de runners"
    if [[ -n "$REPO" ]]; then
        log "📦 Repositorio: $REPO"
    else
        log "🏢 Organización: $ORG"
    fi
    log "================================================"
    log ""
    
    # Obtener runners
    local runners
    if [[ -n "$REPO" ]]; then
        runners=$(get_repo_runners "$REPO")
    else
        runners=$(get_org_runners "$ORG")
    fi
    
    # Filtrar por estado si es necesario
    if [[ "$STATUS_FILTER" != "all" ]]; then
        runners=$(echo "$runners" | jq ".runners = [.runners[] | select(.status==\"$STATUS_FILTER\")]")
    fi
    
    # Mostrar resultados
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        display_runners_json "$runners"
    else
        display_runners_table "$runners" "$DETAILED"
        check_vms_status
    fi
    
    log "✅ Verificación completada"
}

# Ejecutar
main "$@"
