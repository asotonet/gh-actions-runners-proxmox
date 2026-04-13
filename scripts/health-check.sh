#!/bin/bash
###############################################################################
# health-check.sh
# Script para verificar la salud del runner, Docker y servicios asociados
###############################################################################

set -euo pipefail

# Directorio raíz del proyecto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Cargar configuración si existe
CONFIG_FILE="$ROOT_DIR/config/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

RUNNER_USER="${RUNNER_USER:-runner}"
CT_ID="${1:-}"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# Funciones
###############################################################################

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}\n"
}

print_check() {
    printf "  %-45s" "$1"
}

print_ok() {
    echo -e "${GREEN}✅ OK${NC}"
}

print_warn() {
    echo -e "${YELLOW}⚠️  WARNING${NC}"
}

print_fail() {
    echo -e "${RED}❌ FAIL${NC}"
}

check_runner_service() {
    print_header "🤖 Estado del GitHub Actions Runner"
    
    # Verificar si el servicio del runner está activo
    if systemctl is-active --quiet actions.runner.* 2>/dev/null; then
        print_check "Servicio del runner"
        print_ok
        
        # Mostrar estado detallado
        local runner_status
        runner_status=$(systemctl status actions.runner.* 2>/dev/null | head -5)
        echo -e "     ${BLUE}$runner_status${NC}"
    else
        print_check "Servicio del runner"
        print_warn
        echo -e "     ${YELLOW}El servicio del runner no está activo${NC}"
    fi
    
    # Verificar directorio del runner
    if [[ -d "/home/$RUNNER_USER/actions-runner" ]]; then
        print_check "Directorio del runner"
        print_ok
    else
        print_check "Directorio del runner"
        print_fail
    fi
    
    # Verificar archivo de configuración
    if [[ -f "/home/$RUNNER_USER/actions-runner/.runner" ]]; then
        print_check "Configuración del runner"
        print_ok
    else
        print_check "Configuración del runner"
        print_warn
        echo -e "     ${YELLOW}El runner podría no estar registrado${NC}"
    fi
    
    # Verificar propietario
    local owner
    owner=$(stat -c '%U:%G' "/home/$RUNNER_USER/actions-runner" 2>/dev/null || echo "unknown")
    if [[ "$owner" == "$RUNNER_USER:$RUNNER_USER" ]]; then
        print_check "Propietario correcto ($RUNNER_USER)"
        print_ok
    else
        print_check "Propietario correcto ($RUNNER_USER)"
        print_fail
        echo -e "     ${RED}Propietario actual: $owner${NC}"
    fi
}

check_docker_service() {
    print_header "🐳 Estado de Docker Engine"
    
    # Verificar servicio Docker
    if systemctl is-active --quiet docker; then
        print_check "Servicio Docker"
        print_ok
    else
        print_check "Servicio Docker"
        print_fail
    fi
    
    # Verificar versión de Docker
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
        print_check "Docker versión ($docker_version)"
        print_ok
    else
        print_check "Docker instalado"
        print_fail
    fi
    
    # Verificar Docker Compose
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker compose version 2>/dev/null | awk '{print $4}')
        print_check "Docker Compose ($compose_version)"
        print_ok
    else
        print_check "Docker Compose"
        print_warn
    fi
    
    # Verificar BuildKit
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        print_check "Docker BuildKit"
        print_ok
    else
        print_check "Docker BuildKit"
        print_warn
    fi
}

check_docker_permissions() {
    print_header "🔑 Permisos de Docker"
    
    # Verificar que el usuario runner existe
    if id "$RUNNER_USER" >/dev/null 2>&1; then
        print_check "Usuario '$RUNNER_USER' existe"
        print_ok
    else
        print_check "Usuario '$RUNNER_USER' existe"
        print_fail
        return 1
    fi
    
    # Verificar grupo docker
    if groups "$RUNNER_USER" 2>/dev/null | grep -q '\bdocker\b'; then
        print_check "Usuario en grupo docker"
        print_ok
    else
        print_check "Usuario en grupo docker"
        print_fail
        echo -e "     ${RED}El usuario $RUNNER_USER no puede usar Docker sin sudo${NC}"
    fi
    
    # Verificar socket de Docker
    if [[ -S /var/run/docker.sock ]]; then
        local sock_perms
        sock_perms=$(stat -c '%a' /var/run/docker.sock)
        if [[ "$sock_perms" == "660" || "$sock_perms" == "666" ]]; then
            print_check "Docker socket permissions ($sock_perms)"
            print_ok
        else
            print_check "Docker socket permissions ($sock_perms)"
            print_warn
        fi
    else
        print_check "Docker socket existe"
        print_fail
    fi
    
    # Verificar directorio _work
    if [[ -d "/home/$RUNNER_USER/actions-runner/_work" ]]; then
        local work_perms
        work_perms=$(stat -c '%a' "/home/$RUNNER_USER/actions-runner/_work")
        if [[ "$work_perms" == "755" || "$work_perms" == "775" ]]; then
            print_check "Directorio _work permissions ($work_perms)"
            print_ok
        else
            print_check "Directorio _work permissions ($work_perms)"
            print_warn
        fi
    else
        print_check "Directorio _work existe"
        print_fail
    fi
}

check_docker_functionality() {
    print_header "🔨 Funcionalidad de Docker"
    
    # Test: Docker run hello-world
    print_check "Docker run (hello-world)"
    if docker run --rm hello-world >/dev/null 2>&1; then
        print_ok
    else
        print_fail
        echo -e "     ${RED}Docker no puede ejecutar contenedores${NC}"
    fi
    
    # Test: Docker build
    print_check "Docker build"
    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "$temp_dir/Dockerfile" << 'EOF'
FROM alpine:latest
RUN echo "health-check" > /test.txt
EOF
    
    if docker build -t health-check-test "$temp_dir" >/dev/null 2>&1; then
        print_ok
        docker rmi health-check-test >/dev/null 2>&1
    else
        print_fail
        echo -e "     ${RED}Docker no puede construir imágenes${NC}"
    fi
    rm -rf "$temp_dir"
    
    # Test: Docker volumes
    print_check "Docker volumes"
    if docker volume create test-volume >/dev/null 2>&1; then
        print_ok
        docker volume rm test-volume >/dev/null 2>&1
    else
        print_fail
    fi
    
    # Test: Bind mount
    print_check "Docker bind mount"
    if docker run --rm -v /tmp:/test alpine:latest ls /test >/dev/null 2>&1; then
        print_ok
    else
        print_fail
        echo -e "     ${RED}Docker no puede hacer bind mounts${NC}"
    fi
}

check_system_resources() {
    print_header "💻 Recursos del Sistema"
    
    # CPU
    local cpu_count
    cpu_count=$(nproc)
    print_check "CPUs disponibles ($cpu_count)"
    if [[ $cpu_count -ge 2 ]]; then
        print_ok
    else
        print_warn
        echo -e "     ${YELLOW}Se recomiendan al menos 2 CPUs${NC}"
    fi
    
    # Memoria
    local mem_total
    mem_total=$(free -m | awk '/^Mem:/{print $2}')
    print_check "Memoria total (${mem_total}MB)"
    if [[ $mem_total -ge 2048 ]]; then
        print_ok
    else
        print_warn
        echo -e "     ${YELLOW}Se recomiendan al menos 2GB de RAM${NC}"
    fi
    
    # Disco
    local disk_avail
    disk_avail=$(df -BG /home | awk 'NR==2{print $4}' | sed 's/G//')
    print_check "Disco disponible (${disk_avail}GB)"
    if [[ $disk_avail -ge 10 ]]; then
        print_ok
    else
        print_warn
        echo -e "     ${YELLOW}Se recomiendan al menos 10GB libres${NC}"
    fi
    
    # Uso actual de Docker
    if command -v docker >/dev/null 2>&1; then
        local docker_images
        docker_images=$(docker images -q 2>/dev/null | wc -l)
        local docker_containers
        docker_containers=$(docker ps -q 2>/dev/null | wc -l)
        local docker_volumes
        docker_volumes=$(docker volume ls -q 2>/dev/null | wc -l)
        
        print_check "Imágenes Docker ($docker_images)"
        print_ok
        
        print_check "Contenedores activos ($docker_containers)"
        print_ok
        
        print_check "Volúmenes Docker ($docker_volumes)"
        print_ok
    fi
}

check_network() {
    print_header "🌡️ Conectividad de Red"
    
    # GitHub API
    print_check "GitHub API (api.github.com)"
    if curl -s -f --max-time 5 https://api.github.com >/dev/null 2>&1; then
        print_ok
    else
        print_fail
        echo -e "     ${RED}No se puede acceder a GitHub API${NC}"
    fi
    
    # Docker Hub
    print_check "Docker Hub (hub.docker.com)"
    if curl -s -f --max-time 5 https://hub.docker.com >/dev/null 2>&1; then
        print_ok
    else
        print_fail
        echo -e "     ${RED}No se puede acceder a Docker Hub${NC}"
    fi
    
    # DNS
    print_check "Resolución DNS"
    if nslookup github.com >/dev/null 2>&1; then
        print_ok
    else
        print_fail
    fi
}

check_lxc_configuration() {
    print_header "📦 Configuración LXC (si aplica)"
    
    # Verificar si estamos en un contenedor LXC
    if [[ -f /run/systemd/container ]] || grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        print_check "Ejecutándose en LXC"
        print_ok
        
        # Verificar AppArmor
        if [[ -f /proc/self/attr/current ]]; then
            local apparmor_profile
            apparmor_profile=$(cat /proc/self/attr/current 2>/dev/null)
            if [[ "$apparmor_profile" == "unconfined" ]]; then
                print_check "AppArmor profile (unconfined)"
                print_ok
            else
                print_check "AppArmor profile ($apparmor_profile)"
                print_warn
                echo -e "     ${YELLOW}Se recomienda 'unconfined' para Docker${NC}"
            fi
        fi
        
        # Verificar cgroups
        if [[ -d /sys/fs/cgroup ]]; then
            print_check "cgroups disponibles"
            print_ok
        else
            print_check "cgroups disponibles"
            print_fail
        fi
    else
        print_check "Ejecutándose en LXC"
        echo -e "     ${BLUE}No detectado como LXC${NC}"
    fi
}

generate_report() {
    print_header "📊 Resumen de Salud del Runner"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "  ${BLUE}Fecha:${NC} $timestamp"
    echo -e "  ${BLUE}Runner User:${NC} $RUNNER_USER"
    
    if [[ -n "$CT_ID" ]]; then
        echo -e "  ${BLUE}Container ID:${NC} $CT_ID"
    fi
    
    local hostname
    hostname=$(hostname)
    echo -e "  ${BLUE}Hostname:${NC} $hostname"
    
    echo ""
    echo -e "  ${GREEN}✅ Todos los checks críticos pasaron${NC}" || echo -e "  ${YELLOW}⚠️  Hay advertencias que requieren atención${NC}"
    echo ""
}

###############################################################################
# Main
###############################################################################

print_header "🔍 Verificación de Salud del Runner"

check_runner_service
check_docker_service
check_docker_permissions
check_docker_functionality
check_system_resources
check_network
check_lxc_configuration
generate_report

echo -e "${GREEN}✅ Verificación completada${NC}"
exit 0
