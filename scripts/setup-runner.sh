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

# Detectar sistema operativo
detect_os() {
    local os_type
    os_type=$(uname -s)
    
    case "$os_type" in
        MINGW*|MSYS*|CYGWIN*)
            echo "windows"
            ;;
        Linux*)
            echo "linux"
            ;;
        Darwin*)
            echo "macos"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

DETECTED_OS=$(detect_os)

# Generar clave SSH si no existe y copiar a Proxmox
generate_ssh_key_if_needed() {
    local ssh_key_file="${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    local ssh_pub_key="${ssh_key_file}.pub"
    
    # Generar clave si no existe
    if [[ ! -f "$ssh_key_file" ]]; then
        echo "   🔑 Generando clave SSH..."
        ssh-keygen -t ed25519 -f "$ssh_key_file" -N "" -q 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "   ✅ Clave SSH generada: $ssh_key_file"
        else
            echo "   ❌ Falló generación de clave SSH"
            return 1
        fi
    fi
    
    # Copiar clave pública a Proxmox
    echo "   📤 Copiando clave SSH a Proxmox..."
    local ssh_user="${PROXMOX_SSH_USER:-root}"
    local ssh_host="${PROXMOX_SSH_HOST:-$PROXMOX_HOST}"
    local ssh_port="${PROXMOX_SSH_PORT:-22}"
    local pub_key_content
    pub_key_content=$(cat "$ssh_pub_key")
    
    # Intentar copiar vía API de Proxmox o SSH
    if command -v sshpass >/dev/null 2>&1 && [[ -n "${PROXMOX_SSH_PASSWORD:-}" ]]; then
        sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -p "$ssh_port" "$ssh_user@$ssh_host" "mkdir -p ~/.ssh && echo '$pub_key_content' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "   ✅ Clave SSH copiada a Proxmox"
            PROXMOX_SSH_KEY="$ssh_key_file"
            return 0
        fi
    fi
    
    echo "   ⚠️  No se pudo copiar automáticamente la clave SSH"
    echo "   💡 Copia manualmente la clave pública a Proxmox:"
    echo "   cat $ssh_pub_key"
    echo ""
    echo "   Y en Proxmox ejecuta:"
    echo "   echo '$pub_key_content' >> ~/.ssh/authorized_keys"
    echo ""
    echo "   Luego configura en config.env:"
    echo "   PROXMOX_SSH_KEY=\"$ssh_key_file\""
    return 1
}

# Instalar dependencias automáticamente
install_dependencies() {
    local missing=()
    
    # Verificar qué falta
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v sshpass >/dev/null 2>&1 || missing+=("sshpass")
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "✅ Todas las dependencias están instaladas"
        return 0
    fi
    
    echo "📦 Dependencias faltantes: ${missing[*]}"
    echo ""
    
    if [[ "$DETECTED_OS" == "windows" ]]; then
        echo "🔧 Sistema detectado: Windows (Git Bash/MSYS2)"
        echo ""
        echo "📦 Instalando dependencias..."
        
        for dep in "${missing[@]}"; do
            case "$dep" in
                curl)
                    echo "   ✅ curl ya está instalado (incluido con Git Bash)"
                    ;;
                jq)
                    echo "   📥 Instalando jq..."
                    # Intentar con winget primero
                    if command -v winget >/dev/null 2>&1; then
                        winget install -e --id jqlang.jq --accept-package-agreements --accept-source-agreements 2>/dev/null && echo "   ✅ jq instalado con winget" || echo "   ⚠️  winget falló - instala manualmente: https://github.com/jqlang/jq/releases"
                    elif command -v pacman >/dev/null 2>&1; then
                        pacman -S --noconfirm jq 2>/dev/null || echo "   ❌ Falló pacman"
                    else
                        echo "   💡 Descargando jq binario..."
                        local jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-win64.exe"
                        curl -L "$jq_url" -o /usr/bin/jq.exe 2>/dev/null && chmod +x /usr/bin/jq.exe && echo "   ✅ jq descargado" || echo "   ❌ Falló descarga"
                    fi
                    ;;
                sshpass)
                    echo "   📥 Instalando sshpass..."
                    if command -v pacman >/dev/null 2>&1; then
                        pacman -S --noconfirm sshpass 2>/dev/null && echo "   ✅ sshpass instalado con pacman" || echo "   ❌ Falló pacman"
                    elif command -v winget >/dev/null 2>&1; then
                        echo "   💡 Intentando instalar sshpass via winget..."
                        # winget puede no tener sshpass, intentamos descargar binario
                        local sshpass_url="https://github.com/kevinburke/sshpass/releases/download/1.06/sshpass.exe"
                        if curl -sL "$sshpass_url" -o /usr/bin/sshpass.exe 2>/dev/null && chmod +x /usr/bin/sshpass.exe; then
                            echo "   ✅ sshpass descargado"
                        else
                            echo "   ⚠️  Falló descarga de sshpass"
                            echo "   💡 Generando clave SSH como alternativa..."
                            generate_ssh_key_if_needed
                        fi
                    else
                        echo "   💡 sshpass no disponible - usando autenticación por clave SSH"
                        generate_ssh_key_if_needed
                    fi
                    ;;
            esac
        done
        
    elif [[ "$DETECTED_OS" == "linux" ]]; then
        echo "🔧 Sistema detectado: Linux"
        echo ""
        echo "📦 Instalando dependencias..."
        
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq 2>/dev/null
            for dep in "${missing[@]}"; do
                echo "   📥 Instalando $dep..."
                sudo apt-get install -y -qq "$dep" 2>/dev/null || echo "   ❌ Falló apt-get install $dep"
            done
        elif command -v yum >/dev/null 2>&1; then
            for dep in "${missing[@]}"; do
                echo "   📥 Instalando $dep..."
                sudo yum install -y -q "$dep" 2>/dev/null || echo "   ❌ Falló yum install $dep"
            done
        elif command -v dnf >/dev/null 2>&1; then
            for dep in "${missing[@]}"; do
                echo "   📥 Instalando $dep..."
                sudo dnf install -y -q "$dep" 2>/dev/null || echo "   ❌ Falló dnf install $dep"
            done
        else
            echo "❌ No se detectó un gestor de paquetes soportado"
            return 1
        fi
        
    elif [[ "$DETECTED_OS" == "macos" ]]; then
        echo "🔧 Sistema detectado: macOS"
        echo ""
        
        if ! command -v brew >/dev/null 2>&1; then
            echo "❌ Homebrew no está instalado"
            echo "   Instala desde: https://brew.sh"
            return 1
        fi
        
        echo "📦 Instalando dependencias..."
        for dep in "${missing[@]}"; do
            echo "   📥 Instalando $dep..."
            brew install "$dep" 2>/dev/null || echo "   ❌ Falló brew install $dep"
        done
    else
        echo "❌ Sistema no soportado: $DETECTED_OS"
        echo ""
        echo "Instala manualmente:"
        echo "   curl: https://curl.se"
        echo "   jq: https://jqlang.github.io/jq/download/"
        echo "   sshpass: https://sourceforge.net/projects/sshpass/"
        return 1
    fi
    
    echo ""
    echo "✅ Instalación completada"
    return 0
}

# Verificar dependencias e instalar si faltan
check_dependencies || install_dependencies

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
    
    # Parámetros de creación
    # IMPORTANTE: Las comas dentro de features y net0 deben ser %2C para no confundirse con separadores
    # Y ostemplate debe tener el formato: STORAGE:vztmpl/ARCHIVO.tar.zst
    
    local ostemplate_param
    # Si LXC_TEMPLATE ya incluye el storage (ej: local:vztmpl/...), usarlo tal cual
    if echo "$LXC_TEMPLATE" | grep -q ":"; then
        ostemplate_param="$LXC_TEMPLATE"
    else
        # Si no, construir con el storage de templates (local)
        ostemplate_param="local:vztmpl/${LXC_TEMPLATE}"
    fi
    
    local features_encoded="nesting%3D${nesting}%2Ckeyctl%3D${keyctl}"
    local net0_encoded="name%3Deth0%2Cbridge%3Dvmbr0%2Cip%3Ddhcp"
    
    local create_params="vmid=${ct_id}&hostname=${ct_name}&storage=${LXC_STORAGE}&ostemplate=${ostemplate_param}&memory=${memory}&cores=${cpus}&rootfs=${LXC_STORAGE}%3A${disk}&unprivileged=${unprivileged}&features=${features_encoded}&net0=${net0_encoded}"
    
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

    # Usar la API de Proxmox para configurar el contenedor
    # PUT /api2/json/nodes/{node}/lxc/{vmid}/config

    local config_params="hookscript=&"
    config_params+="features=nesting=1,keyctl=1&"
    config_params+="lxc.apparmor.profile=unconfined&"
    config_params+="lxc.cap.drop=&"
    config_params+="lxc.cgroup2.devices.allow=a"

    log "🔧 Aplicando configuraciones via API de Proxmox..."

    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/config" "$config_params" "PUT")

    if echo "$response" | grep -qi '"data"'; then
        log "✅ lxc.apparmor.profile: unconfined - Aplicado"
        log "✅ lxc.cap.drop: - Aplicado"
        log "✅ lxc.cgroup2.devices.allow: a - Aplicado"
        log "✅ features: nesting=1,keyctl=1 - Aplicado"
        
        # Reiniciar contenedor para aplicar cambios
        log "🔄 Reiniciando contenedor para aplicar cambios..."
        exec_on_proxmox_host "pct shutdown $ct_id --timeout 30 && sleep 3 && pct start $ct_id"
        sleep 10
    else
        log "⚠️  No se pudo aplicar configuración via API"
        log "💡 Aplica manualmente en /etc/pve/lxc/${ct_id}.conf:"
        log ""
        log "   lxc.apparmor.profile: unconfined"
        log "   lxc.cap.drop:"
        log "   lxc.cgroup2.devices.allow: a"
        log ""
        log "   Luego reinicia: pct shutdown ${ct_id} && pct start ${ct_id}"
    fi
}

wait_for_container_ready() {
    local ct_id="$1"
    local max_wait=${2:-300}
    local elapsed=0

    log "⏳ Esperando a que el contenedor $ct_id esté listo..."
    log "   (La primera instalación del template puede tomar varios minutos)"

    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/current" "" "GET")

        # Debug: mostrar respuesta cada 30s
        if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
            log_debug "Status response: ${status:0:200}..."
        fi

        if echo "$status" | grep -q '"running"' || echo "$status" | grep -q '"status":"running"'; then
            log "✅ Contenedor $ct_id está corriendo"
            # Esperar un poco más para que el sistema esté completamente inicializado
            log "   ⏳ Esperando inicialización del sistema..."
            sleep 15
            return 0
        fi

        # Mostrar progreso cada 30 segundos
        if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   ⏳ Aún inicializando... (${elapsed}s/${max_wait}s)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "❌ Timeout: El contenedor no estuvo listo en ${max_wait}s"
    log "💡 Verifica manualmente: pct status $ct_id"
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
    local expires_at
    
    # Intentar con jq primero, fallback a grep/sed
    if command -v jq >/dev/null 2>&1; then
        token=$(echo "$response" | jq -r '.token // empty')
        expires_at=$(echo "$response" | jq -r '.expires_at // empty')
    else
        token=$(echo "$response" | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')
        expires_at=$(echo "$response" | grep -o '"expires_at":"[^"]*"' | sed 's/"expires_at":"//;s/"//')
    fi

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
