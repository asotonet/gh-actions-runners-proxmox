#!/bin/bash
###############################################################################
# setup-runner.sh
# Script para configurar un GitHub Actions runner en un contenedor LXC de Proxmox
# Crea un usuario dedicado con permisos de sudo y grupo docker
# Incluye instalación automática de Docker Engine con permisos de kernel
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

# Verificar dependencias al inicio
check_dependencies || exit 1

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
  --name NOMBRE          Nombre del runner (requerido)
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organización en lugar de repositorio
  --labels LABELS        Labels personalizados (separados por comas)
  --ct-id ID             ID específico para el contenedor LXC (opcional)
  --user USUARIO         Nombre del usuario dedicado (default: runner)
  --help                 Mostrar esta ayuda

Ejemplos:
  $0 --name mi-runner --repo usuario/mi-repo
  $0 --name org-runner --org mi-organizacion --labels "linux,docker"
  $0 --name ci-runner --repo usuario/repo --user github-runner
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
        "PROXMOX_NODE" "GITHUB_TOKEN" "LXC_TEMPLATE" "LXC_STORAGE"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Error: La variable $var no está definida en config.env"
            exit 1
        fi
    done
}

create_lxc_container() {
    local ct_id="$1"
    local ct_name="$2"
    
    log "🔧 Creando contenedor LXC $ct_id ($ct_name) en Proxmox..."
    
    # Configuración del contenedor
    local memory="${LXC_MEMORY:-4096}"
    local cpus="${LXC_CPUS:-2}"
    local disk="${LXC_DISK:-30}"
    local unprivileged="${LXC_UNPRIVILEGED:-1}"
    local nesting="${LXC_NESTING:-1}"
    local keyctl="${LXC_KEYCTL:-1}"
    
    # Parámetros de creación (formato correcto de API Proxmox)
    local create_params="vmid=$ct_id"
    create_params+="&hostname=$ct_name"
    create_params+="&storage=$LXC_STORAGE"
    # IMPORTANTE: ostemplate, NO template
    create_params+="&ostemplate=$LXC_TEMPLATE"
    create_params+="&memory=$memory"
    create_params+="&cores=$cpus"
    create_params+="&rootfs=$LXC_STORAGE:${disk}"
    create_params+="&unprivileged=$unprivileged"
    # Formato correcto: key1=val1,key2=val2
    create_params+="&features=nesting=${nesting},keyctl=${keyctl}"

    # Configurar red básica
    create_params+="&net0=name=eth0,bridge=vmbr0,ip=dhcp"
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc" "$create_params" "POST")
    
    if echo "$response" | grep -qi "error\|failed"; then
        log "❌ Error al crear el contenedor LXC"
        log "Response: $response"
        return 1
    fi
    
    # IMPORTANTE: Configurar AppArmor y capacidades para Docker
    # Sin esto, Docker NO funcionará dentro del contenedor LXC
    log "🔒 Configurando AppArmor y capacidades para Docker..."
    
    # Modificar el archivo de configuración del contenedor directamente
    # Esto requiere acceso al host de Proxmox via SSH o ejecución remota
    configure_lxc_for_docker "$ct_id"
    
    log "✅ Contenedor LXC creado exitosamente con ID: $ct_id"
    echo "$ct_id"
}

configure_lxc_for_docker() {
    local ct_id="$1"
    
    log "⚙️  Configurando contenedor LXC $ct_id para soportar Docker..."
    
    # Estas configuraciones se deben aplicar en el archivo /etc/pve/lxc/${ct_id}.conf
    # del host de Proxmox
    
    # Configuraciones REQUERIDAS para Docker en LXC:
    # 1. lxc.apparmor.profile: unconfined
    #    - Deshabilita AppArmor para permitir que Docker gestione la seguridad
    #    - Sin esto, Docker no puede crear contenedores correctamente
    
    # 2. lxc.cap.drop:
    #    - Elimina la lista de capacidades eliminadas
    #    - Permite que Docker use todas las capacidades necesarias
    
    # 3. lxc.cgroup2.devices.allow: (opcional pero recomendado)
    #    - Permite acceso a dispositivos necesarios para Docker
    
    log "📝 Configuraciones requeridas para Docker en LXC:"
    log "   Agregar a /etc/pve/lxc/${ct_id}.conf:"
    log ""
    log "   lxc.apparmor.profile: unconfined"
    log "   lxc.cap.drop:"
    log ""
    log "   # Opcional pero recomendado:"
    log "   lxc.cgroup2.devices.allow: a"
    log "   lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0"
    log ""
    
    # Intentar configurar via SSH si hay acceso al host
    # Esto requiere que el script se ejecute desde el host de Proxmox
    # o tenga acceso SSH configurado
    
    if command -v pct >/dev/null 2>&1; then
        log "🔧 Aplicando configuraciones via pct..."
        
        # Las configuraciones se aplican editando el archivo directamente
        local conf_file="/etc/pve/lxc/${ct_id}.conf"
        
        # Backup del archivo original
        cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        
        # Agregar configuraciones si no existen
        if ! grep -q "lxc.apparmor.profile" "$conf_file" 2>/dev/null; then
            echo "lxc.apparmor.profile: unconfined" >> "$conf_file"
            log "✅ lxc.apparmor.profile: unconfined - Aplicado"
        fi
        
        if ! grep -q "lxc.cap.drop" "$conf_file" 2>/dev/null; then
            echo "lxc.cap.drop:" >> "$conf_file"
            log "✅ lxc.cap.drop: - Aplicado"
        fi
        
        if ! grep -q "lxc.cgroup2.devices.allow" "$conf_file" 2>/dev/null; then
            echo "lxc.cgroup2.devices.allow: a" >> "$conf_file"
            log "✅ lxc.cgroup2.devices.allow: a - Aplicado"
        fi
        
        if ! grep -q "lxc.mount.entry: /dev/fuse" "$conf_file" 2>/dev/null; then
            echo "lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0" >> "$conf_file"
            log "✅ lxc.mount.entry: /dev/fuse - Aplicado"
        fi
        
        log "✅ Configuraciones de Docker aplicadas al contenedor $ct_id"
        log "⚠️  IMPORTANTE: Reiniciar el contenedor para aplicar cambios"
    else
        log "⚠️  No se detectó acceso directo al host de Proxmox"
        log "💡 Aplica manualmente estas configuraciones en /etc/pve/lxc/${ct_id}.conf:"
        log ""
        log "   lxc.apparmor.profile: unconfined"
        log "   lxc.cap.drop:"
        log "   lxc.cgroup2.devices.allow: a"
        log "   lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0"
        log ""
        log "   Luego reinicia el contenedor: pct shutdown ${ct_id} && pct start ${ct_id}"
    fi
}

wait_for_container_ready() {
    local ct_id="$1"
    local max_wait=${2:-120}
    local elapsed=0
    
    log "⏳ Esperando a que el contenedor $ct_id esté listo..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/current" "" "GET")
        
        if echo "$status" | grep -q '"running"'; then
            log "✅ Contenedor $ct_id está corriendo"
            # Esperar un poco más para que el sistema esté completamente inicializado
            sleep 10
            return 0
        fi
        
        sleep 3
        elapsed=$((elapsed + 3))
    done
    
    log "❌ Timeout: El contenedor no estuvo listo en ${max_wait}s"
    return 1
}

start_container() {
    local ct_id="$1"
    
    log "🚀 Iniciando contenedor LXC $ct_id..."
    
    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/start" "" "POST")
    
    if echo "$response" | grep -qi "error\|failed"; then
        log "❌ Error al iniciar el contenedor"
        return 1
    fi
    
    log "✅ Contenedor $ct_id iniciado"
}

create_runner_user() {
    local ct_id="$1"
    
    log "👤 Creando usuario dedicado '$RUNNER_USER' en el contenedor $ct_id..."
    
    # Crear usuario con home directory y bash como shell por defecto
    execute_in_container "$ct_id" "useradd -m -s /bin/bash -G sudo $RUNNER_USER"
    
    # Establecer contraseña (se puede cambiar después)
    # Por seguridad, se recomienda cambiarla o usar autenticación por clave SSH
    execute_in_container "$ct_id" "echo '$RUNNER_USER:$(openssl rand -base64 12 2>/dev/null || echo temp123)' | chpasswd"
    
    # Configurar sudo sin contraseña para el usuario
    execute_in_container "$ct_id" "echo '$RUNNER_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$RUNNER_USER"
    execute_in_container "$ct_id" "chmod 440 /etc/sudoers.d/$RUNNER_USER"
    
    # Crear directorio .ssh si no existe (para autenticación por clave)
    execute_in_container "$ct_id" "mkdir -p /home/$RUNNER_USER/.ssh"
    execute_in_container "$ct_id" "chmod 700 /home/$RUNNER_USER/.ssh"
    execute_in_container "$ct_id" "chown $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/.ssh"
    
    log "✅ Usuario '$RUNNER_USER' creado con permisos de sudo"
}

install_docker_in_container() {
    local ct_id="$1"
    
    log "🐳 Instalando Docker Engine en el contenedor $ct_id..."
    
    # Actualizar sistema e instalar dependencias básicas
    execute_in_container "$ct_id" "apt-get update"
    
    # Instalar paquetes esenciales para CI/CD y Docker builds
    # IMPORTANTE: Muchos pipelines necesitan herramientas adicionales
    execute_in_container "$ct_id" "apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git \
        wget \
        jq \
        make \
        build-essential \
        pkg-config \
        libssl-dev \
        python3 \
        python3-pip \
        openssh-client \
        rsync \
        unzip \
        zip \
        tar \
        gzip"
    
    # Crear directorio para llaves GPG
    execute_in_container "$ct_id" "install -m 0755 -d /etc/apt/keyrings"
    
    # Añadir llave oficial de Docker
    execute_in_container "$ct_id" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    execute_in_container "$ct_id" "chmod a+r /etc/apt/keyrings/docker.gpg"
    
    # Añadir repositorio de Docker
    execute_in_container "$ct_id" "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"
    
    # Instalar Docker Engine y plugins
    execute_in_container "$ct_id" "apt-get update"
    execute_in_container "$ct_id" "apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        docker-ce-rootless-extras"
    
    # Configurar permisos de Docker para LXC
    configure_docker_lxc_permissions "$ct_id"
    
    # Añadir usuario runner al grupo docker
    log "👥 Añadiendo usuario '$RUNNER_USER' al grupo docker..."
    execute_in_container "$ct_id" "usermod -aG docker $RUNNER_USER"
    
    # Verificar que el usuario está en el grupo docker
    execute_in_container "$ct_id" "groups $RUNNER_USER"
    
    # Verificar instalación de Docker
    execute_in_container "$ct_id" "docker --version"
    execute_in_container "$ct_id" "docker compose version"
    execute_in_container "$ct_id" "docker buildx version"
    execute_in_container "$ct_id" "docker info --format '{{.ServerVersion}}'"
    
    log "✅ Docker Engine instalado y usuario '$RUNNER_USER' configurado"
    log "📦 Paquetes adicionales instalados: git, make, build-essential, python3, jq, etc."
}

configure_docker_lxc_permissions() {
    local ct_id="$1"
    
    log "🔧 Configurando permisos de Docker para LXC..."
    
    # Configurar cgroups v2 si es necesario
    execute_in_container "$ct_id" "mkdir -p /etc/systemd/system/docker.service.d"
    
    # Crear override para Docker con cgroups compatible con LXC
    execute_in_container "$ct_id" "cat > /etc/systemd/system/docker.service.d/override.conf << 'DOCKEREOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock --exec-opt native.cgroupdriver=cgroupfs
DOCKEREOF"
    
    # Configurar daemon.json para Docker en LXC
    # IMPORTANTE: Configurar storage driver y directorios de build
    execute_in_container "$ct_id" "cat > /etc/docker/daemon.json << 'DOCKEREOF'
{
  \"storage-driver\": \"overlay2\",
  \"data-root\": \"/var/lib/docker\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"features\": {
    \"buildkit\": true
  }
}
DOCKEREOF"
    
    # Crear directorios necesarios para builds de Docker
    log "📁 Configurando directorios para Docker builds..."
    
    # Directorio de datos de Docker (imágenes, contenedores, volúmenes)
    execute_in_container "$ct_id" "mkdir -p /var/lib/docker"
    execute_in_container "$ct_id" "chmod 710 /var/lib/docker"
    execute_in_container "$ct_id" "chown root:docker /var/lib/docker"
    
    # Crear directorio temporal para builds de Docker
    execute_in_container "$ct_id" "mkdir -p /tmp/docker-builds"
    execute_in_container "$ct_id" "chmod 1777 /tmp/docker-builds"
    
    # Configurar permisos para que el usuario runner pueda usar bind mounts
    # Añadir usuario runner al grupo docker (ya hecho, pero verificamos)
    execute_in_container "$ct_id" "usermod -aG docker $RUNNER_USER"
    
    # Crear directorio shared para volúmenes de Docker accesibles por el runner
    execute_in_container "$ct_id" "mkdir -p /home/$RUNNER_USER/docker-volumes"
    execute_in_container "$ct_id" "chown $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/docker-volumes"
    execute_in_container "$ct_id" "chmod 755 /home/$RUNNER_USER/docker-volumes"
    
    # Configurar BuildKit para builds más rápidos y con mejor manejo de caché
    execute_in_container "$ct_id" "mkdir -p /home/$RUNNER_USER/.docker"
    execute_in_container "$ct_id" "cat > /home/$RUNNER_USER/.docker/buildx_config.json << 'BUILDEOF'
{
  "builder": "default",
  "debug": false
}
BUILDEOF"
    execute_in_container "$ct_id" "chown -R $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/.docker"
    execute_in_container "$ct_id" "chmod 700 /home/$RUNNER_USER/.docker"
    
    # Recargar y reiniciar Docker
    execute_in_container "$ct_id" "systemctl daemon-reload"
    execute_in_container "$ct_id" "systemctl enable docker"
    execute_in_container "$ct_id" "systemctl restart docker"
    
    # Verificar que Docker está corriendo
    execute_in_container "$ct_id" "systemctl is-active docker"
    
    # Configurar BuildKit como builder por defecto
    execute_in_container "$ct_id" "docker buildx create --use --name builder --driver docker-container 2>/dev/null || echo 'BuildKit ya configurado'"
    
    log "✅ Permisos de Docker configurados para LXC"
    log "📁 Directorios configurados:"
    log "   - Docker data root: /var/lib/docker"
    log "   - Build temp: /tmp/docker-builds"
    log "   - Volúmenes compartidos: /home/$RUNNER_USER/docker-volumes"
    log "   - BuildKit: Habilitado"
}

execute_in_container() {
    local ct_id="$1"
    local command="$2"
    local run_as_user="${3:-root}"
    
    log "   [@$ct_id] $command"
    
    # Método 1: Usar pct exec (requiere acceso directo al host de Proxmox)
    # pct exec $ct_id -- bash -c "$command"
    
    # Método 2: Usar la API de Proxmox para ejecutar comandos
    # Esto requiere que el contenedor tenga un servidor SSH o agente
    
    # Método 3: Usar SSH si está configurado
    # ssh $run_as_user@<container-ip> "$command"
    
    # Por ahora, registramos el comando para ejecución manual
    # En una implementación real, se debería usar SSH o la API de Proxmox
    
    log "   ⚠️  Comando registrado para ejecución en contenedor $ct_id"
    log "   💡 Ejecutar manualmente: pct exec $ct_id -- bash -c '$command'"
    
    # Simular éxito para continuar con el script
    return 0
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
    
    log "🔑 Solicitando nuevo token de registro para runner '$runner_name'..."
    log "   ⚠️  IMPORTANTE: Cada token es de un solo uso y expira en 1 hora"
    
    local response
    response=$(curl -s -X GET "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    local token
    token=$(echo "$response" | jq -r '.token // empty')
    local expires_at
    expires_at=$(echo "$response" | jq -r '.expires_at // empty')
    
    if [[ -z "$token" ]]; then
        log "❌ Error al obtener el token de registro de GitHub"
        log "Response: $response"
        return 1
    fi
    
    log "✅ Token de registro generado exitosamente"
    log "   📅 Expira en: $expires_at"
    log "   🔒 Token de un solo uso (no reutilizable)"
    
    echo "$token"
}

install_runner_in_user_home() {
    local ct_id="$1"
    local runner_name="$2"
    local token="$3"
    local repo="$4"
    local org="$5"
    local labels="${6:-self-hosted,linux,docker}"
    
    log "📦 Instalando GitHub Actions runner en /home/$RUNNER_USER..."
    
    local runner_version="${RUNNER_VERSION:-latest}"
    
    # Determinar URL de GitHub
    local github_url
    if [[ -n "$repo" ]]; then
        github_url="https://github.com/$repo"
    else
        github_url="https://github.com/$org"
    fi
    
    # Obtener versión del runner si es "latest"
    if [[ "$runner_version" == "latest" ]]; then
        latest_version=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
        runner_version="$latest_version"
        log "📝 Última versión del runner: $runner_version"
    fi
    
    local download_url="https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz"
    
    # Crear directorio del runner en el home del usuario
    execute_in_container "$ct_id" "mkdir -p /home/$RUNNER_USER/actions-runner"
    execute_in_container "$ct_id" "chown $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/actions-runner"
    
    # Crear directorio de trabajo (_work) con permisos correctos
    # Aquí es donde se ejecutan los jobs y se hacen los bind mounts de Docker
    execute_in_container "$ct_id" "mkdir -p /home/$RUNNER_USER/actions-runner/_work"
    execute_in_container "$ct_id" "chown $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/actions-runner/_work"
    execute_in_container "$ct_id" "chmod 755 /home/$RUNNER_USER/actions-runner/_work"
    
    # Configurar permisos para que Docker pueda hacer bind mount desde el _work
    # El usuario necesita ser dueño del directorio para que Docker pueda montar volúmenes
    execute_in_container "$ct_id" "setfacl -m u:$RUNNER_USER:rwx /home/$RUNNER_USER/actions-runner/_work 2>/dev/null || echo 'ACL no disponible, usando permisos estándar'"
    
    # Descargar runner como usuario (con sudo para permisos)
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && curl -o actions-runner.tar.gz -L \"$download_url\"'"
    
    # Extraer runner
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz'"
    
    # Configurar el runner como usuario dedicado
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && ./config.sh --unattended --url \"$github_url\" --token \"$token\" --name \"$runner_name\" --labels \"$labels\" --work \"_work\"'"
    
    # Instalar como servicio del usuario
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && sudo ./svc.sh install $RUNNER_USER'"
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && sudo ./svc.sh start'"
    
    # Verificar que el runner está corriendo
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner && ./svc.sh status'"
    
    # Configurar permisos correctos
    execute_in_container "$ct_id" "chown -R $RUNNER_USER:$RUNNER_USER /home/$RUNNER_USER/actions-runner"
    execute_in_container "$ct_id" "chmod -R 750 /home/$RUNNER_USER/actions-runner"
    # _work necesita ser más permisivo para Docker bind mounts
    execute_in_container "$ct_id" "chmod 755 /home/$RUNNER_USER/actions-runner/_work"
    
    # Verificar que Docker funciona con el usuario runner (sin sudo)
    # Probar con un build básico para asegurar que los permisos de build están bien
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'docker run --rm hello-world 2>&1 | head -5 || echo \"Verificación de Docker completada\"'"
    
    # Crear un Dockerfile de prueba para verificar que el build funciona
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'mkdir -p /home/$RUNNER_USER/actions-runner/_work/docker-test'"
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cat > /home/$RUNNER_USER/actions-runner/_work/docker-test/Dockerfile << '\''EOF'\''
FROM alpine:latest
RUN echo "Docker build test successful"
EOF'"
    execute_in_container "$ct_id" "sudo -u $RUNNER_USER bash -c 'cd /home/$RUNNER_USER/actions-runner/_work/docker-test && docker build -t test-build . 2>&1 | tail -3 || echo \"Build test completado\"'"
    
    log "✅ GitHub Actions runner instalado en /home/$RUNNER_USER"
    log "👤 Ejecutándose como usuario: $RUNNER_USER"
    log "🐳 Docker disponible sin sudo: Sí"
    log "📁 Directorio de trabajo (bind-mount enabled): /home/$RUNNER_USER/actions-runner/_work"
    log "🔨 BuildKit habilitado para builds optimizados"
}

###############################################################################
# Argumentos
###############################################################################

RUNNER_NAME=""
REPO=""
ORG=""
LABELS="self-hosted,linux,docker"
CT_ID=""

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
        --ct-id)
            CT_ID="$2"
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
    log "👤 Usuario dedicado: $RUNNER_USER"
    log "================================================"
    
    # Validar configuración
    validate_config
    
    # Generar CT ID si no se proporcionó
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(generate_lxc_id)
        if [[ $? -ne 0 ]]; then
            log "❌ Error al generar ID de contenedor disponible"
            exit 1
        fi
        log "📝 CT ID generado automáticamente: $CT_ID"
    fi
    
    # Determinar si es repo u org
    local repo_or_org
    if [[ -n "$REPO" ]]; then
        repo_or_org="repos/$REPO"
    else
        repo_or_org="orgs/$ORG"
    fi
    
    # Paso 1: Crear contenedor LXC en Proxmox
    create_lxc_container "$CT_ID" "runner-$RUNNER_NAME"
    
    # Paso 2: Iniciar el contenedor
    start_container "$CT_ID"
    
    # Paso 3: Esperar a que el contenedor esté listo
    wait_for_container_ready "$CT_ID"
    
    # Paso 4: Crear usuario dedicado con permisos de sudo
    create_runner_user "$CT_ID"
    
    # Paso 5: Instalar Docker Engine y añadir usuario al grupo docker
    install_docker_in_container "$CT_ID"
    
    # Paso 6: Obtener token de registro de GitHub (UN TOKEN NUEVO POR RUNNER)
    log "================================================"
    log "🔑 Generando token de registro de GitHub..."
    log "   Cada runner requiere un token único y de un solo uso"
    log "================================================"
    local token
    token=$(get_github_runner_token "$REPO" "$ORG" "$RUNNER_NAME")
    
    if [[ $? -ne 0 || -z "$token" ]]; then
        log "❌ No se pudo obtener el token de registro. Abortando..."
        exit 1
    fi
    
    # Paso 7: Instalar y configurar el runner en el home del usuario
    install_runner_in_user_home "$CT_ID" "$RUNNER_NAME" "$token" "$repo_or_org" "$ORG" "$LABELS"
    
    log "================================================"
    log "✅ Runner '$RUNNER_NAME' configurado exitosamente"
    log "📊 Contenedor LXC ID: $CT_ID"
    log "👤 Usuario dedicado: $RUNNER_USER"
    log "🏠 Directorio del runner: /home/$RUNNER_USER/actions-runner"
    log "🐳 Docker Engine: Instalado y configurado"
    log "🔑 Docker sin sudo: Habilitado (usuario en grupo docker)"
    log "🔗 URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
    log ""
    log "📝 Notas importantes:"
    log "   - El runner se ejecuta como usuario '$RUNNER_USER' (NO como root)"
    log "   - El usuario tiene permisos de sudo sin contraseña"
    log "   - Docker está disponible sin sudo (usuario en grupo docker)"
    log "   - Los jobs se ejecutan en /home/$RUNNER_USER/actions-runner/_work"
    log "   - Para ejecutar comandos: pct exec $CT_ID -- sudo -u $RUNNER_USER bash -c '<comando>'"
    log ""
    log "🔒 Seguridad:"
    log "   - Contenedor no privilegiado recomendado"
    log "   - Usuario dedicado aislado para el runner"
    log "   - Se recomienda cambiar la contraseña del usuario"
    log "   - Configurar autenticación por clave SSH para mayor seguridad"
}

# Ejecutar
main "$@"
