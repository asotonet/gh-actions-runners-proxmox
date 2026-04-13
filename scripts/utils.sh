#!/bin/bash
###############################################################################
# utils.sh
# Funciones auxiliares para la gestión de GitHub Actions runners en Proxmox
###############################################################################

# ==============================================================================
# Funciones de logging
# ==============================================================================

# Función helper: parsear JSON con jq o fallback a grep/sed
parse_json() {
    local json="$1"
    local jq_expr="$2"
    
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r "$jq_expr" 2>/dev/null
    else
        # Fallback básico para extracciones simples
        echo "$json" | grep -o '"[^"]*":[^,}]*' | head -1 | cut -d: -f2- | tr -d '"'
    fi
}

# Función log por defecto (se sobrescribe en el script principal si existe)
# Esto evita "command not found" cuando utils.sh se carga antes de definir log
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
}

# Verificar dependencias necesarias
check_dependencies() {
    local missing=()
    
    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi
    
    # jq es opcional - usamos grep/sed como fallback
    if command -v jq >/dev/null 2>&1; then
        echo "✅ jq disponible"
    else
        echo "⚠️  jq no disponible - usando modo fallback (grep/sed)"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Dependencias faltantes: ${missing[*]}"
        echo ""
        echo "📦 Instalar en Windows (Git Bash):"
        echo "   curl -L https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-win64.exe -o /usr/bin/jq.exe"
        echo "   chmod +x /usr/bin/jq.exe"
        return 1
    fi
    
    return 0
}

log_debug() {
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        log "[DEBUG] $1"
    fi
}

log_info() {
    log "[INFO] $1"
}

log_warn() {
    log "[WARN] $1"
}

log_error() {
    log "[ERROR] $1" >&2
}

# ==============================================================================
# Funciones de la API de Proxmox
# ==============================================================================

# Obtener ticket de autenticación de Proxmox
get_proxmox_ticket() {
    local response
    response=$(curl -s -k -X POST \
        "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/access/ticket" \
        -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" 2>/dev/null)
    
    local ticket=""
    
    # Intentar con jq primero, fallback a grep/sed
    if command -v jq >/dev/null 2>&1; then
        ticket=$(echo "$response" | jq -r '.data.ticket // empty')
    else
        # Fallback sin jq
        ticket=$(echo "$response" | grep -o '"ticket":"[^"]*"' | sed 's/"ticket":"//;s/"//')
    fi
    
    if [[ -z "$ticket" ]]; then
        log_error "Error al obtener ticket de Proxmox"
        log_error "Response: $response"
        return 1
    fi
    
    echo "$ticket"
}

# Obtener CSRF token de Proxmox
get_proxmox_csrf() {
    local response
    response=$(curl -s -k -X POST \
        "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/access/ticket" \
        -d "username=${PROXMOX_USER}&password=${PROXMOX_PASSWORD}" 2>/dev/null)
    
    local csrf=""
    
    # Intentar con jq primero, fallback a grep/sed
    if command -v jq >/dev/null 2>&1; then
        csrf=$(echo "$response" | jq -r '.data.CSRFPreventionToken // empty')
    else
        # Fallback sin jq
        csrf=$(echo "$response" | grep -o '"CSRFPreventionToken":"[^"]*"' | sed 's/"CSRFPreventionToken":"//;s/"//')
    fi
    
    if [[ -z "$csrf" ]]; then
        log_error "Error al obtener CSRF token de Proxmox"
        return 1
    fi
    
    echo "$csrf"
}

# Realizar petición a la API de Proxmox
proxmox_api_request() {
    local endpoint="$1"
    local params="$2"
    local method="${3:-GET}"

    local ticket
    ticket=$(get_proxmox_ticket)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    local csrf
    csrf=$(get_proxmox_csrf)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    local url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json${endpoint}"

    local response

    if [[ "$method" == "POST" || "$method" == "PUT" ]]; then
        response=$(curl -s -k \
            -X "$method" \
            -H "Authorization: PVEAuthCookie=$ticket" \
            -H "CSRFPreventionToken: $csrf" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "$params" \
            "$url" 2>/dev/null)
    elif [[ "$method" == "DELETE" ]]; then
        response=$(curl -s -k \
            -X "$method" \
            -H "Authorization: PVEAuthCookie=$ticket" \
            -H "CSRFPreventionToken: $csrf" \
            "$url" 2>/dev/null)
    else
        response=$(curl -s -k \
            -X GET \
            -H "Authorization: PVEAuthCookie=$ticket" \
            -H "CSRFPreventionToken: $csrf" \
            "$url" 2>/dev/null)
    fi

    echo "$response"
}

# ==============================================================================
# Funciones de gestión de contenedores LXC
# ==============================================================================

# Generar nuevo ID de contenedor LXC disponible
generate_lxc_id() {
    local start_id="${1:-100}"
    local end_id="${2:-999}"

    # Obtener contenedores existentes
    local existing_cts
    existing_cts=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc" "" "GET")

    # Extraer IDs existentes
    local used_ids=""
    if command -v jq >/dev/null 2>&1; then
        used_ids=$(echo "$existing_cts" | jq -r '.data[].vmid // empty' 2>/dev/null)
    else
        # Fallback sin jq: extraer vmid con grep
        used_ids=$(echo "$existing_cts" | grep -o '"vmid":[0-9]*' | cut -d: -f2 | sort -n)
    fi

    if [[ -z "$used_ids" ]]; then
        log_warn "No se pudo obtener lista de contenedores existentes, usando ID por defecto: $start_id"
        echo "$start_id"
        return 0
    fi

    # Buscar ID disponible
    for id in $(seq "$start_id" "$end_id"); do
        if ! echo "$used_ids" | grep -qw "^${id}$"; then
            log "📋 IDs usados encontrados: $(echo $used_ids | tr '\n' ', ' | sed 's/,$//')" >&2
            echo "$id"
            return 0
        fi
    done

    log_error "No hay IDs de contenedor disponibles en el rango $start_id-$end_id"
    return 1
}

# Verificar si un contenedor LXC existe
lxc_exists() {
    local ct_id="$1"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/current" "" "GET")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Iniciar contenedor LXC
start_lxc() {
    local ct_id="$1"
    
    log_info "Iniciando contenedor LXC $ct_id..."
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/start" "" "POST")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ Contenedor LXC $ct_id iniciado correctamente"
        return 0
    else
        log_error "Error al iniciar contenedor LXC $ct_id"
        return 1
    fi
}

# Detener contenedor LXC
stop_lxc() {
    local ct_id="$1"
    
    log_info "Deteniendo contenedor LXC $ct_id..."
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/stop" "" "POST")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ Contenedor LXC $ct_id detenido correctamente"
        return 0
    else
        log_error "Error al detener contenedor LXC $ct_id"
        return 1
    fi
}

# Eliminar contenedor LXC
delete_lxc() {
    local ct_id="$1"
    
    log_warn "Eliminando contenedor LXC $ct_id..."
    
    # Primero detener si está corriendo
    stop_lxc "$ct_id" 2>/dev/null
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id" "" "DELETE")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ Contenedor LXC $ct_id eliminado correctamente"
        return 0
    else
        log_error "Error al eliminar contenedor LXC $ct_id"
        return 1
    fi
}

# Obtener estado de contenedor LXC
get_lxc_status() {
    local ct_id="$1"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/current" "" "GET")
    
    local status
    status=$(echo "$response" | jq -r '.data.status // "unknown"')
    
    echo "$status"
}

# Listar todos los contenedores LXC
list_lxc() {
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc" "" "GET")
    
    echo "$response" | jq -r '.data[] | "\(.vmid) | \(.name) | \(.status) | \(.mem // 0) | \(.disk // 0)"'
}

# Ejecutar comando en contenedor LXC
exec_in_lxc() {
    local ct_id="$1"
    local command="$2"
    local user="${3:-root}"
    
    # Usar pct exec para ejecutar comandos en el contenedor
    # Nota: Esto requiere acceso directo al host de Proxmox
    if command -v pct >/dev/null 2>&1; then
        if [[ "$user" == "root" ]]; then
            pct exec "$ct_id" -- bash -c "$command"
        else
            pct exec "$ct_id" -- sudo -u "$user" bash -c "$command"
        fi
    else
        log_error "pct no está disponible. Se requiere acceso al host de Proxmox"
        return 1
    fi
}

# ==============================================================================
# Funciones de gestión de VMs
# ==============================================================================

# Generar nuevo ID de VM disponible
generate_vm_id() {
    local start_id="${1:-100}"
    local end_id="${2:-999}"
    
    # Obtener VMs existentes
    local existing_vms
    existing_vms=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "" "GET")
    
    # Extraer IDs existentes
    local used_ids
    if command -v jq >/dev/null 2>&1; then
        used_ids=$(echo "$existing_vms" | jq -r '.data[].vmid // empty' 2>/dev/null)
    else
        used_ids=$(echo "$existing_vms" | grep -o '"vmid":[0-9]*' | cut -d: -f2 | sort -n)
    fi
    
    # Buscar ID disponible
    for id in $(seq "$start_id" "$end_id"); do
        if ! echo "$used_ids" | grep -qw "^${id}$"; then
            log "📋 IDs usados encontrados: $(echo $used_ids | tr '\n' ', ' | sed 's/,$//')" >&2
            echo "$id"
            return 0
        fi
    done
    
    log_error "No hay IDs de VM disponibles en el rango $start_id-$end_id"
    return 1
}

# Verificar si una VM existe
vm_exists() {
    local vm_id="$1"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" "" "GET")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Iniciar VM
start_vm() {
    local vm_id="$1"
    
    log_info "Iniciando VM $vm_id..."
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ VM $vm_id iniciada correctamente"
        return 0
    else
        log_error "Error al iniciar VM $vm_id"
        return 1
    fi
}

# Detener VM
stop_vm() {
    local vm_id="$1"
    
    log_info "Deteniendo VM $vm_id..."
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/stop" "" "POST")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ VM $vm_id detenida correctamente"
        return 0
    else
        log_error "Error al detener VM $vm_id"
        return 1
    fi
}

# Eliminar VM
delete_vm() {
    local vm_id="$1"
    
    log_warn "Eliminando VM $vm_id..."
    
    # Primero detener si está corriendo
    stop_vm "$vm_id" 2>/dev/null
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id" "" "DELETE")
    
    if echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        log_info "✅ VM $vm_id eliminada correctamente"
        return 0
    else
        log_error "Error al eliminar VM $vm_id"
        return 1
    fi
}

# Obtener estado de VM
get_vm_status() {
    local vm_id="$1"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" "" "GET")
    
    local status
    status=$(echo "$response" | jq -r '.data.status // "unknown"')
    
    echo "$status"
}

# Listar todas las VMs
list_vms() {
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "" "GET")
    
    echo "$response" | jq -r '.data[] | "\(.vmid) | \(.name) | \(.status)"'
}

# ==============================================================================
# Funciones de GitHub API
# ==============================================================================

# Listar runners de un repositorio
list_repo_runners() {
    local repo="$1"
    
    local url="https://api.github.com/repos/$repo/actions/runners"
    
    local response
    response=$(curl -s -X GET "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    echo "$response" | jq -r '.runners[] | "\(.id) | \(.name) | \(.status)"'
}

# Listar runners de una organización
list_org_runners() {
    local org="$1"
    
    local url="https://api.github.com/orgs/$org/actions/runners"
    
    local response
    response=$(curl -s -X GET "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    echo "$response" | jq -r '.runners[] | "\(.id) | \(.name) | \(.status)"'
}

# Eliminar runner por ID
remove_runner_by_id() {
    local repo="$1"
    local org="$2"
    local runner_id="$3"
    
    local url
    if [[ -n "$repo" ]]; then
        url="https://api.github.com/repos/$repo/actions/runners/$runner_id"
    elif [[ -n "$org" ]]; then
        url="https://api.github.com/orgs/$org/actions/runners/$runner_id"
    else
        log_error "Debes especificar repo u org"
        return 1
    fi
    
    local response
    response=$(curl -s -X DELETE "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    if [[ $? -eq 0 ]]; then
        log_info "✅ Runner $runner_id eliminado de GitHub"
        return 0
    else
        log_error "Error al eliminar runner de GitHub"
        return 1
    fi
}

# ==============================================================================
# Funciones de validación
# ==============================================================================

# Validar formato de repositorio
validate_repo_format() {
    local repo="$1"
    
    if [[ ! "$repo" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "Formato de repositorio inválido: $repo"
        log_error "Formato esperado: USUARIO/REPO"
        return 1
    fi
    
    return 0
}

# ==============================================================================
# Funciones de utilidad general
# ==============================================================================

# Formatear timestamp
format_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Generar nombre aleatorio para runner
generate_runner_name() {
    local prefix="${1:-runner}"
    local suffix
    suffix=$(openssl rand -hex 4 2>/dev/null || echo $RANDOM)
    echo "${prefix}-${suffix}"
}

# Mostrar barra de progreso simple
show_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r["
    printf '%0.s█' $(seq 1 $filled 2>/dev/null)
    printf '%0.s░' $(seq 1 $empty 2>/dev/null)
    printf "] %d%%" "$percentage"
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}
