#!/bin/bash
###############################################################################
# setup-runner.sh
# Script para configurar un GitHub Actions runner en un contenedor LXC de Proxmox
# Crea un usuario dedicado con permisos de sudo y grupo docker
# Incluye instalación automática de Docker Engine con permisos de kernel
# Usa cloud-init + SSH para configuración automática completa
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
  --name NOMBRE          Nombre del runner (se usará runner-CT_ID)
  --repo REPOSITORIO     Repositorio en formato USUARIO/REPO (requerido)
  --org ORGANIZACION     Organización en lugar de repositorio
  --labels LABELS        Labels personalizados (separados por comas)
  --ct-id ID             ID específico para el contenedor LXC (opcional)
  --user USUARIO         Nombre del usuario dedicado (default: runner)
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
        "PROXMOX_NODE" "GITHUB_TOKEN" "LXC_TEMPLATE" "LXC_STORAGE"
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
    
    log "🔑 Solicitando nuevo token de registro para runner '$runner_name'..."
    log "   URL: $url"
    
    local response
    response=$(curl -s -X POST "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")
    
    log "   Response: ${response:0:100}"
    
    local token
    local expires_at
    
    if command -v jq >/dev/null 2>&1; then
        token=$(echo "$response" | jq -r '.token // empty')
        expires_at=$(echo "$response" | jq -r '.expires_at // empty')
    else
        # Fallback: manejar espacios después de :
        token=$(echo "$response" | grep -o '"token": *"[^"]*"' | head -1 | sed 's/.*"token": *"//;s/"$//')
        expires_at=$(echo "$response" | grep -o '"expires_at": *"[^"]*"' | head -1 | sed 's/.*"expires_at": *"//;s/"$//')
    fi

    if [[ -z "$token" ]]; then
        log "❌ Error al obtener el token de registro de GitHub"
        log "Response: $response"
        return 1
    fi
    
    log "✅ Token de registro generado (expira: $expires_at)"
    echo "$token"
}

# Generar o usar clave SSH para acceder al contenedor
setup_ssh_access() {
    local ssh_key_file="${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    local ssh_pub_key="${ssh_key_file}.pub"

    # Generar clave si no existe
    if [[ ! -f "$ssh_key_file" ]]; then
        log "🔑 Generando clave SSH..." >&2
        ssh-keygen -t ed25519 -f "$ssh_key_file" -N "" -q 2>/dev/null
        log "✅ Clave SSH generada: $ssh_key_file" >&2
    fi

    # Mostrar clave pública
    if [[ -f "$ssh_pub_key" ]]; then
        local pub_key_content
        pub_key_content=$(cat "$ssh_pub_key")
        log "📋 Clave SSH pública:" >&2
        log "   $pub_key_content" >&2
    fi

    # Solo devolver la ruta del archivo (stdout)
    echo "$ssh_key_file"
}

create_lxc_with_cloudinit() {
    local ct_id="$1"
    local ct_name="$2"
    local runner_name="$3"
    local repo="$4"
    local org="$5"
    local labels="$6"
    local token="$7"
    local ssh_pub_key="$8"

    log "🔧 Creando contenedor LXC $ct_id ($ct_name) con cloud-init..."

    # Configuración del contenedor
    local memory="${LXC_MEMORY:-4096}"
    local cpus="${LXC_CPUS:-2}"
    local disk="${LXC_DISK:-30}"
    local unprivileged="${LXC_UNPRIVILEGED:-1}"
    local nesting="${LXC_NESTING:-1}"
    local keyctl="${LXC_KEYCTL:-1}"
    
    # IMPORTANTE: ostemplate con formato STORAGE:vztmpl/ARCHIVO
    local ostemplate_param
    if echo "$LXC_TEMPLATE" | grep -q ":"; then
        ostemplate_param="$LXC_TEMPLATE"
    else
        ostemplate_param="local:vztmpl/${LXC_TEMPLATE}"
    fi
    
    local features_encoded="nesting%3D${nesting}%2Ckeyctl%3D${keyctl}"
    local net0_encoded="name%3Deth0%2Cbridge%3Dvmbr0%2Cip%3Ddhcp"
    
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

    # Crear script de inicialización
    local init_script='#!/bin/bash
set -e

# Variables (reemplazadas por el script principal)
RUNNER_USER='"'"'${RUNNER_USER}'"'"'
RUNNER_NAME='"'"'${runner_name}'"'"'
GITHUB_URL='"'"'${github_url}'"'"'
RUNNER_TOKEN='"'"'${token}'"'"'
LABELS='"'"'${labels}'"'"'
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
DOWNLOAD_URL='"'"'${download_url}'"'"'

# Crear log
exec > >(tee /var/log/runner-setup.log) 2>&1
echo "=== Iniciando configuración del runner ==="

# 1. Paquetes esenciales
echo "[1/6] Instalando paquetes esenciales..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release git wget jq make build-essential pkg-config libssl-dev python3 python3-pip openssh-client rsync unzip zip tar gzip 2>/dev/null

# 2. Docker
echo "[2/6] Instalando Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null

# 3. Configurar Docker
echo "[3/6] Configurando Docker..."
mkdir -p /etc/systemd/system/docker.service.d /etc/docker /var/lib/docker /tmp/docker-builds

cat > /etc/systemd/system/docker.service.d/override.conf << '"'"'DEOF'"'"'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock --exec-opt native.cgroupdriver=cgroupfs
DEOF

cat > /etc/docker/daemon.json << '"'"'DEOF'"'"'
{
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
DEOF

chmod 710 /var/lib/docker && chown root:docker /var/lib/docker
chmod 1777 /tmp/docker-builds
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

# 4. Crear usuario
echo "[4/6] Creando usuario runner..."
useradd -m -s /bin/bash -G sudo "$RUNNER_USER" || true
usermod -aG docker "$RUNNER_USER"
echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${RUNNER_USER}
chmod 440 /etc/sudoers.d/${RUNNER_USER}

mkdir -p /home/${RUNNER_USER}/docker-volumes /home/${RUNNER_USER}/.docker
chown ${RUNNER_USER}:${RUNNER_USER} /home/${RUNNER_USER}/docker-volumes
chmod 755 /home/${RUNNER_USER}/docker-volumes
chown -R ${RUNNER_USER}:${RUNNER_USER} /home/${RUNNER_USER}/.docker
chmod 700 /home/${RUNNER_USER}/.docker

docker buildx create --use --name builder --driver docker-container 2>/dev/null || true

# 5. Instalar runner
echo "[5/6] Instalando GitHub Actions runner..."
mkdir -p "$RUNNER_DIR" "$RUNNER_DIR/_work"
chown ${RUNNER_USER}:${RUNNER_USER} "$RUNNER_DIR" "$RUNNER_DIR/_work"
chmod 755 "$RUNNER_DIR/_work"

su - "$RUNNER_USER" -c "cd $RUNNER_DIR && curl -sL '"'"'$DOWNLOAD_URL'"'"' -o actions-runner.tar.gz && tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz"
su - "$RUNNER_USER" -c "cd $RUNNER_DIR && ./config.sh --unattended --url '"'"'$GITHUB_URL'"'"' --token '"'"'$RUNNER_TOKEN'"'"' --name '"'"'$RUNNER_NAME'"'"' --labels '"'"'$LABELS'"'"' --work '"'"'_work'"'"'"

cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER"
cd "$RUNNER_DIR" && ./svc.sh start
cd "$RUNNER_DIR" && ./svc.sh status

chown -R ${RUNNER_USER}:${RUNNER_USER} "$RUNNER_DIR"
chmod -R 750 "$RUNNER_DIR"
chmod 755 "$RUNNER_DIR/_work"

# 6. Verificar
echo "[6/6] Verificando..."
docker run --rm hello-world 2>&1 | head -3 || true
docker --version
echo "=== Configuración completada ==="
'

    # Guardar script para referencia
    echo "$init_script" > "$ROOT_DIR/logs/init-runner-${ct_id}.sh"
    chmod +x "$ROOT_DIR/logs/init-runner-${ct_id}.sh"
    log "💾 Script guardado: logs/init-runner-${ct_id}.sh"

    # Crear contenedor con cloud-init
    local create_params="vmid=${ct_id}"
    create_params+="&hostname=${ct_name}"
    create_params+="&storage=${LXC_STORAGE}"
    create_params+="&ostemplate=${ostemplate_param}"
    create_params+="&memory=${memory}"
    create_params+="&cores=${cpus}"
    create_params+="&rootfs=${LXC_STORAGE}%3A${disk}"
    create_params+="&unprivileged=${unprivileged}"
    create_params+="&features=${features_encoded}"
    create_params+="&net0=${net0_encoded}"
    # Cloud-init: usuario root con contraseña
    create_params+="&ciuser=root"
    create_params+="&cipassword=RunnerSetup2024!"
    create_params+="&sshkeys=$(echo "$ssh_pub_key" | sed 's/+/%2B/g; s/=/%3D/g; s/\//%2F/g')"
    create_params+="&onboot=1"
    create_params+="&start=1"

    local response
    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc" "$create_params" "POST")

    if echo "$response" | grep -qi "error\|failed"; then
        log "❌ Error al crear el contenedor LXC"
        log "Response: $response"
        return 1
    fi

    # Configurar AppArmor para Docker
    log "🔒 Configurando AppArmor y capacidades para Docker..."
    local config_params="hookscript=&"
    config_params+="features=nesting=1,keyctl=1&"
    config_params+="lxc.apparmor.profile=unconfined&"
    config_params+="lxc.cap.drop=&"
    config_params+="lxc.cgroup2.devices.allow=a"

    response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/config" "$config_params" "PUT")

    if echo "$response" | grep -qi '"data"'; then
        log "✅ lxc.apparmor.profile: unconfined - Aplicado"
        log "✅ lxc.cap.drop: - Aplicado"
        log "✅ lxc.cgroup2.devices.allow: a - Aplicado"
    fi

    log "✅ Contenedor LXC creado: $ct_id"
    log "🔄 Reiniciando para aplicar cloud-init..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/stop" "" "POST" >/dev/null 2>&1
    sleep 5
    proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/status/start" "" "POST" >/dev/null 2>&1
    sleep 15

    # Esperar SSH
    log "⏳ Esperando acceso SSH..."
    local container_ip
    container_ip=$(wait_for_container_ip "$ct_id")
    
    if [[ -n "$container_ip" ]]; then
        log "📡 IP del contenedor: $container_ip"
        wait_for_ssh "$container_ip" 120
        
        # Copiar y ejecutar script vía SSH
        log "🚀 Ejecutando script de configuración..."
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
            "$ROOT_DIR/logs/init-runner-${ct_id}.sh" \
            "root@${container_ip}:/opt/setup-runner.sh" 2>/dev/null || true
        
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
            "root@${container_ip}" \
            "bash /opt/setup-runner.sh" 2>&1 | while read -r line; do
            log "   📤 $line"
        done
    else
        log "⚠️  No se pudo obtener IP del contenedor"
        log "💡 Ejecuta manualmente:"
        log "   pct exec $ct_id -- bash /opt/setup-runner.sh"
    fi

    echo "$ct_id"
}

wait_for_container_ip() {
    local ct_id="$1"
    local max_wait=60
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        local response
        response=$(proxmox_api_request "/nodes/$PROXMOX_NODE/lxc/$ct_id/interfaces" "" "GET")
        
        local ip
        ip=$(echo "$response" | grep -o '"ip":"[0-9.]*"' | head -1 | cut -d: -f2 | tr -d '"')
        
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
            echo "$ip"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    return 1
}

wait_for_ssh() {
    local host="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    
    local key_file="${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    
    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -i "$key_file" \
            "root@${host}" "echo SSH_OK" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    
    return 1
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
    
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(generate_lxc_id)
        if [[ $? -ne 0 ]]; then
            log "❌ Error al generar ID de contenedor"
            exit 1
        fi
        log "📝 CT ID generado: $CT_ID"
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
    
    # Setup SSH
    local ssh_key_file
    ssh_key_file=$(setup_ssh_access)
    
    local runner_name_with_id="runner-${CT_ID}"
    log "📝 Nombre del runner: $runner_name_with_id"
    
    # Crear contenedor con cloud-init
    local ssh_pub_key
    ssh_pub_key=$(cat "${ssh_key_file}.pub")
    
    create_lxc_with_cloudinit "$CT_ID" "runner-${runner_name_with_id}" "$runner_name_with_id" "$repo_or_org" "$ORG" "$LABELS" "$token" "$ssh_pub_key"
    
    log "================================================"
    log "✅ Runner '$runner_name_with_id' configurado"
    log "📊 CT ID: $CT_ID"
    log "🏠 Directorio: /home/$RUNNER_USER/actions-runner"
    log "🐳 Docker: Instalado y configurado"
    log "🔗 URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

main "$@"
