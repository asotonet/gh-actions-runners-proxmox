#!/bin/bash
###############################################################################
# create-base-template.sh
# Crea un template base de Ubuntu con cloud-init + qemu-guest-agent
#
# Esto se ejecuta UNA SOLA VEZ. Despues, setup-runner.sh usa este template
# para crear runners automaticamente.
#
# Requisitos:
#   - ISO de Ubuntu Server 22.04 descargada en Proxmox
#   - Acceso a la API de Proxmox con credenciales en config.env
#
# Uso:
#   ./scripts/create-base-template.sh --template-id 9000
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/config.env"
[[ ! -f "$CONFIG_FILE" ]] && { echo "Error: config.env no encontrado"; exit 1; }

source "$CONFIG_FILE"
source "$SCRIPT_DIR/utils.sh"

TEMPLATE_ID="${VM_TEMPLATE:-9000}"
VM_ISO="${VM_ISO:-ubuntu-22.04.5-live-server-amd64.iso}"
VM_ISO_STORAGE="${VM_ISO_STORAGE:-local}"

###############################################################################

usage() {
    cat <<EOF
Uso: $0 [OPCIONES]

Crea un template base de Ubuntu Server para clonar runners.

Opciones:
  --template-id ID     ID del template (default: 9000)
  --help               Ayuda
EOF
    exit 0
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template-id) TEMPLATE_ID="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Opcion: $1"; usage ;;
    esac
done

main() {
    log "================================================"
    log "  Creando template base de Ubuntu"
    log "================================================"
    log ""
    log "Este proceso:"
    log "  1. Crea una VM temporal con la ISO de Ubuntu"
    log "  2. La inicia para instalacion MANUAL"
    log "  3. Te indica los pasos de instalacion"
    log "  4. Convierte la VM en template"
    log ""
    log "Solo necesitas hacer esto UNA VEZ."
    log ""

    # =============================================
    # Crear VM temporal
    # =============================================
    log "Creando VM temporal $TEMPLATE_ID..."

    local params="vmid=${TEMPLATE_ID}"
    params+="&name=ubuntu-base-template"
    params+="&memory=2048"
    params+="&cores=2"
    params+="&sockets=1"
    params+="&ostype=l26"
    params+="&machine=q35"
    params+="&cpu=host"
    params+="&agent=1"
    params+="&scsihw=virtio-scsi-pci"
    params+="&scsi0=${VM_STORAGE:-local-lvm}:16"
    params+="&ide2=${VM_ISO_STORAGE}:iso/${VM_ISO},media=cdrom"
    params+="&boot=order=ide2"
    params+="&net0=virtio,bridge=vmbr0"

    local resp
    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$params" "POST")

    if echo "$resp" | grep -qi "error\|failed"; then
        log "Error al crear VM: $resp"
        exit 1
    fi

    log "VM $TEMPLATE_ID creada"
    log ""
    log "================================================"
    log "  PASOS DE INSTALACION"
    log "================================================"
    log ""
    log "1. Abre la consola de la VM $TEMPLATE_ID en Proxmox"
    log "2. Inicia la VM y sigue el instalador de Ubuntu:"
    log ""
    log "   - Idioma: English (o tu preferencia)"
    log "   - Keyboard: Spanish o tu layout"
    log "   - Network: DHCP (default)"
    log "   - Proxy: (dejar vacio)"
    log "   - Mirror: (default)"
    log "   - Storage: Guided - use entire disk"
    log "   - Profile setup:"
    log "     * Nombre: runner"
    log "     * Servidor: runner"
    log "     * Usuario: runner"
    log "     * Password: RunnerSetup2024!"
    log "   - SSH: YES (instalar openssh-server)"
    log "   - Featured Server Snakes: NONE"
    log ""
    log "3. Cuando termine la instalacion, REINICIA la VM"
    log ""
    log "4. Despues del reboot, ejecuta en la consola de la VM:"
    log ""
    log "   sudo apt update"
    log "   sudo apt install -y cloud-init qemu-guest-agent"
    log "   sudo systemctl enable qemu-guest-agent"
    log "   sudo systemctl enable cloud-init"
    log "   sudo touch /etc/cloud/cloud-init.disabled"
    log "   sudo rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg"
    log "   sudo cloud-init clean"
    log "   sudo rm -f /etc/ssh/ssh_host_*"
    log "   sudo rm -f /var/lib/cloud/instance*"
    log "   sudo rm -f /var/lib/cloud/instances/*"
    log "   sudo history -c"
    log "   sudo shutdown now"
    log ""
    log "5. Cuando la VM este apagada, ejecuta:"
    log ""
    log "   ./scripts/create-base-template.sh --finalize $TEMPLATE_ID"
    log ""
    log "================================================"
    log ""
    log "Iniciando VM para instalacion..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$TEMPLATE_ID/status/start" "" "POST" >/dev/null 2>&1
    log "VM iniciada. Abre la consola en Proxmox para continuar."
}

finalize_template() {
    local tid="$1"
    log "Convirtiendo VM $tid a template..."

    # Verificar que este apagada
    local status
    status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/current" "" "GET")
    if echo "$status" | grep -q '"running"'; then
        log "Apagando VM..."
        proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/stop" "" "POST" >/dev/null 2>&1
        sleep 5
    fi

    # Convertir a template
    local resp
    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/template" "" "POST")

    if echo "$resp" | grep -qi '"data"'; then
        log "Template $tid creado exitosamente!"
        log ""
        log "Ahora puedes crear runners con:"
        log "  ./scripts/setup-runner.sh --repo tu-usuario/tu-repo --vm-id 102"
    else
        log "Error: $resp"
    fi
}

###############################################################################

if [[ "${1:-}" == "--finalize" ]]; then
    finalize_template "${2:?Necesitas especificar el template ID}"
else
    main "$@"
fi
