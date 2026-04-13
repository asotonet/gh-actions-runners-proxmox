#!/bin/bash
###############################################################################
# backup-runner.sh
# Script para respaldar la configuración y datos del runner
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
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="runner-backup-$TIMESTAMP"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# Funciones
###############################################################################

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_ok() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1${NC}" >&2
}

usage() {
    cat <<EOF
Uso: $0 [OPCIONES]

Opciones:
  --output DIR           Directorio de salida para el backup (default: ./backups)
  --include-logs         Incluir logs del runner (puede ser grande)
  --include-docker       Incluir configuración de Docker
  --compress             Comprimir el backup (tar.gz)
  --retain-days DIAS     Eliminar backups antiguos (default: no eliminar)
  --help                 Mostrar esta ayuda

Ejemplos:
  $0 --compress
  $0 --include-logs --compress
  $0 --retain-days 30
EOF
    exit 0
}

backup_runner_config() {
    local dest="$1"
    
    log "📦 Respaldando configuración del runner..."
    
    # Verificar que el directorio del runner existe
    if [[ ! -d "/home/$RUNNER_USER/actions-runner" ]]; then
        log_error "No se encontró el directorio del runner: /home/$RUNNER_USER/actions-runner"
        return 1
    fi
    
    # Crear directorio de backup
    mkdir -p "$dest"
    
    # Respaldar configuración del runner (sin binarios)
    local runner_config="$dest/actions-runner-config"
    mkdir -p "$runner_config"
    
    # Archivos de configuración importantes
    local config_files=(".runner" ".credentials" ".credentials_rs1024")
    
    for file in "${config_files[@]}"; do
        if [[ -f "/home/$RUNNER_USER/actions-runner/$file" ]]; then
            cp "/home/$RUNNER_USER/actions-runner/$file" "$runner_config/"
            log "   ✅ $file"
        fi
    done
    
    # Respaldar configuración de servicios
    if [[ -d "/home/$RUNNER_USER/actions-runner/bin" ]]; then
        mkdir -p "$runner_config/bin"
        ls -la "/home/$RUNNER_USER/actions-runner/bin/" > "$runner_config/bin/services.txt" 2>/dev/null || true
    fi
    
    log_ok "Configuración del runner respaldada"
}

backup_docker_config() {
    local dest="$1"
    
    log "🐳 Respaldando configuración de Docker..."
    
    mkdir -p "$dest/docker-config"
    
    # Daemon.json
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json "$dest/docker-config/"
        log "   ✅ daemon.json"
    fi
    
    # Docker config.json (credenciales)
    if [[ -f "/home/$RUNNER_USER/.docker/config.json" ]]; then
        cp "/home/$RUNNER_USER/.docker/config.json" "$dest/docker-config/"
        log "   ✅ config.json"
    fi
    
    # BuildKit config
    if [[ -f "/home/$RUNNER_USER/.docker/buildx_config.json" ]]; then
        cp "/home/$RUNNER_USER/.docker/buildx_config.json" "$dest/docker-config/"
        log "   ✅ buildx_config.json"
    fi
    
    # Systemd overrides
    if [[ -d /etc/systemd/system/docker.service.d ]]; then
        mkdir -p "$dest/docker-config/systemd"
        cp -r /etc/systemd/system/docker.service.d/* "$dest/docker-config/systemd/" 2>/dev/null || true
        log "   ✅ systemd overrides"
    fi
    
    log_ok "Configuración de Docker respaldada"
}

backup_logs() {
    local dest="$1"
    
    log "📝 Respaldando logs..."
    
    mkdir -p "$dest/logs"
    
    # Logs del proyecto
    if [[ -d "$ROOT_DIR/logs" ]]; then
        cp -r "$ROOT_DIR/logs"/* "$dest/logs/" 2>/dev/null || true
        log "   ✅ Logs del proyecto"
    fi
    
    # Logs del runner
    if [[ -d "/home/$RUNNER_USER/actions-runner/_diag" ]]; then
        mkdir -p "$dest/logs/runner-diag"
        cp -r "/home/$RUNNER_USER/actions-runner/_diag"/* "$dest/logs/runner-diag/" 2>/dev/null || true
        log "   ✅ Logs de diagnóstico del runner"
    fi
    
    # Logs de Docker
    if [[ -f /var/log/docker.log ]]; then
        cp /var/log/docker.log "$dest/logs/" 2>/dev/null || true
        log "   ✅ Log de Docker"
    fi
    
    log_ok "Logs respaldados"
}

backup_lxc_config() {
    local dest="$1"
    local ct_id="${2:-}"
    
    if [[ -z "$ct_id" ]]; then
        log "📦 No se proporcionó CT ID, omitiendo backup de config LXC"
        return 0
    fi
    
    log "📦 Respaldando configuración LXC..."
    
    mkdir -p "$dest/lxc-config"
    
    # Archivo de configuración LXC (si tenemos acceso)
    local lxc_conf="/etc/pve/lxc/${ct_id}.conf"
    if [[ -f "$lxc_conf" ]]; then
        cp "$lxc_conf" "$dest/lxc-config/"
        log "   ✅ ${ct_id}.conf"
    fi
    
    # Backup de características y configuración
    cat > "$dest/lxc-config/README.txt" << EOF
Configuración LXC para Docker
==============================
CT ID: $ct_id
Fecha: $(date '+%Y-%m-%d %H:%M:%S')

Configuraciones aplicadas:
- lxc.apparmor.profile: unconfined
- lxc.cap.drop:
- lxc.cgroup2.devices.allow: a
- lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0

Para restaurar:
1. Copiar el archivo .conf a /etc/pve/lxc/
2. Reiniciar el contenedor: pct shutdown <id> && pct start <id>
EOF
    
    log_ok "Configuración LXC respaldada"
}

create_compressed_backup() {
    local backup_path="$1"
    local compress_path="${backup_path}.tar.gz"
    
    log "🗜️  Comprimiendo backup..."
    
    tar -czf "$compress_path" -C "$BACKUP_DIR" "$BACKUP_NAME" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        # Eliminar directorio sin comprimir
        rm -rf "$backup_path"
        
        local size
        size=$(du -h "$compress_path" | cut -f1)
        log_ok "Backup comprimido: $compress_path ($size)"
    else
        log_error "Error al comprimir el backup"
        return 1
    fi
}

cleanup_old_backups() {
    local retain_days="$1"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 0
    fi
    
    log "🗑️  Eliminando backups con más de $retain_days días..."
    
    local count
    count=$(find "$BACKUP_DIR" -name "runner-backup-*" -type f -mtime +$retain_days 2>/dev/null | wc -l)
    
    if [[ $count -gt 0 ]]; then
        find "$BACKUP_DIR" -name "runner-backup-*" -type f -mtime +$retain_days -delete
        log_ok "Eliminados $count backups antiguos"
    else
        log "   No hay backups antiguos para eliminar"
    fi
}

###############################################################################
# Argumentos
###############################################################################

INCLUDE_LOGS=false
INCLUDE_DOCKER=false
COMPRESS=false
RETAIN_DAYS=""
CT_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --include-logs)
            INCLUDE_LOGS=true
            shift
            ;;
        --include-docker)
            INCLUDE_DOCKER=true
            shift
            ;;
        --compress)
            COMPRESS=true
            shift
            ;;
        --retain-days)
            RETAIN_DAYS="$2"
            shift 2
            ;;
        --ct-id)
            CT_ID="$2"
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

###############################################################################
# Main
###############################################################################

main() {
    log "═══════════════════════════════════════════"
    log "  💾 Backup del GitHub Actions Runner"
    log "═══════════════════════════════════════════"
    log ""
    
    # Crear directorio de backup
    mkdir -p "$BACKUP_PATH"
    
    log "📁 Directorio de backup: $BACKUP_PATH"
    log ""
    
    # 1. Backup de configuración del runner
    backup_runner_config "$BACKUP_PATH"
    
    # 2. Backup de Docker (si se solicita)
    if [[ "$INCLUDE_DOCKER" == "true" ]]; then
        backup_docker_config "$BACKUP_PATH"
    fi
    
    # 3. Backup de LXC (si se proporciona CT ID)
    if [[ -n "$CT_ID" ]]; then
        backup_lxc_config "$BACKUP_PATH" "$CT_ID"
    fi
    
    # 4. Backup de logs (si se solicita)
    if [[ "$INCLUDE_LOGS" == "true" ]]; then
        backup_logs "$BACKUP_PATH"
    fi
    
    # 5. Generar archivo de metadatos
    cat > "$BACKUP_PATH/backup-info.txt" << EOF
Backup del GitHub Actions Runner
=================================
Fecha: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Runner User: $RUNNER_USER
Container ID: ${CT_ID:-N/A}
Incluye Docker: $INCLUDE_DOCKER
Incluye Logs: $INCLUDE_LOGS

Archivos respaldados:
$(find "$BACKUP_PATH" -type f | wc -l)

Tamaño total:
$(du -sh "$BACKUP_PATH" | cut -f1)

Para restaurar:
1. Descomprimir: tar -xzf $BACKUP_NAME.tar.gz
2. Copiar archivos a sus ubicaciones originales
3. Reiniciar servicios: systemctl restart actions.runner.*
EOF
    
    # 6. Comprimir si se solicita
    if [[ "$COMPRESS" == "true" ]]; then
        create_compressed_backup "$BACKUP_PATH"
    fi
    
    # 7. Limpiar backups antiguos si se solicita
    if [[ -n "$RETAIN_DAYS" ]]; then
        cleanup_old_backups "$RETAIN_DAYS"
    fi
    
    log ""
    log "═══════════════════════════════════════════"
    log_ok "Backup completado exitosamente"
    log "📁 Ubicación: $BACKUP_PATH"
    if [[ "$COMPRESS" == "true" ]]; then
        log "📁 Backup comprimido: ${BACKUP_PATH}.tar.gz"
    fi
    log "═══════════════════════════════════════════"
}

# Ejecutar
main "$@"
