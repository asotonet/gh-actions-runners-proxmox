#!/bin/bash
###############################################################################
# create-base-template.sh
# Crea automaticamente un template base de Ubuntu con cloud-init + qemu-guest-agent
#
# TODO es automatico via API de Proxmox. No requiere intervencion manual.
#
# Usa Ubuntu Server autoinstall (subiquity) con user-data cloud-config.
# Los late-commands instalan cloud-init y qemu-guest-agent automaticamente.
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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

###############################################################################
# Crear ISO de autoinstall con user-data + meta-data
###############################################################################

create_autoinstall_iso() {
    local iso_dir
    iso_dir=$(mktemp -d /tmp/ubuntu-autoinstall-XXXXXX)

    # user-data para autoinstall
    cat > "$iso_dir/user-data" << 'AUTOEOF'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ubuntu-base
    username: runner
    password: "$6$rounds=4096$runner$xQHBVp8zKjLqFz3rJHqGj5YKp0xZQxZxZxZxZxZxZxZ"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
      match:
        size: largest
  packages:
    - qemu-guest-agent
    - cloud-init
    - openssh-server
  late-commands:
    # Habilitar servicios
    - echo 'runner ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/runner
    - chmod 440 /target/etc/sudoers.d/runner
    - curtin in-target --target=/target -- systemctl enable qemu-guest-agent
    - curtin in-target --target=/target -- systemctl enable cloud-init
    - curtin in-target --target=/target -- systemctl enable ssh
    # Limpiar para template
    - curtin in-target --target=/target -- rm -f /etc/ssh/ssh_host_*
    - curtin in-target --target=/target -- rm -rf /var/lib/cloud/instance*
    - curtin in-target --target=/target -- rm -rf /var/lib/cloud/instances/*
    - curtin in-target --target=/target -- history -c
  error-commands:
    - sh -c 'cat /var/log/installer/syslog'
AUTOEOF

    # meta-data (requerido por cloud-init)
    cat > "$iso_dir/meta-data" << EOF
instance-id: ubuntu-base-template
local-hostname: ubuntu-base
EOF

    # Crear ISO
    local iso_path="/tmp/ubuntu-autoinstall.iso"
    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$iso_path" -volid "cidata" -joliet -rock "$iso_dir/user-data" "$iso_dir/meta-data"
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$iso_path" -volid "cidata" -joliet -rock "$iso_dir/user-data" "$iso_dir/meta-data"
    else
        log "Error: genisoimage o mkisofs requerido para crear ISO"
        log "Instalalo: sudo apt install genisoimage"
        rm -rf "$iso_dir"
        return 1
    fi

    rm -rf "$iso_dir"
    log "ISO de autoinstall creada: $iso_path"
    echo "$iso_path"
}

###############################################################################
# Subir ISO a Proxmox
###############################################################################

upload_iso_to_proxmox() {
    local iso_path="$1"
    local iso_name="ubuntu-autoinstall-ci.iso"

    log "Subiendo ISO a Proxmox ($VM_ISO_STORAGE)..."

    local ticket csrf
    ticket=$(get_proxmox_ticket)
    csrf=$(get_proxmox_csrf)

    # Subir via API
    local upload_resp
    upload_resp=$(curl -s -k -X POST \
        "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/storage/${VM_ISO_STORAGE}/upload" \
        -F "filename=@${iso_path}" \
        -F "content=iso" \
        -H "Authorization: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf" 2>/dev/null)

    if echo "$upload_resp" | grep -qi '"data"'; then
        log "ISO subida correctamente"
        return 0
    else
        log "Error subiendo ISO: $upload_resp"
        log "Intentando copia directa via scp..."

        # Fallback: scp al directorio de templates
        if command -v sshpass &>/dev/null && [[ -n "${PROXMOX_SSH_PASSWORD:-}" ]]; then
            sshpass -p "$PROXMOX_SSH_PASSWORD" scp \
                -o StrictHostKeyChecking=no \
                "$iso_path" \
                "${PROXMOX_SSH_USER:-root}@${PROXMOX_SSH_HOST:-$PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_name" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log "ISO copiada via scp"
                return 0
            fi
        fi

        log "No se pudo subir ISO. Intenta manualmente:"
        log "  scp $iso_path root@${PROXMOX_HOST:-$PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_name"
        return 1
    fi
}

###############################################################################
# Crear VM y autoinstalar
###############################################################################

create_template() {
    local tid="${1:-$TEMPLATE_ID}"

    log "================================================"
    log "  Creando template base automatico"
    log "  Template ID: $tid"
    log "================================================"

    # Verificar que no exista ya
    local check
    check=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/config" "" "GET" 2>/dev/null)
    if echo "$check" | grep -qi '"data"'; then
        log "Error: VM $tid ya existe. Eliminala primero: qm destroy $tid"
        exit 1
    fi

    # Crear ISO de autoinstall
    local auto_iso
    auto_iso=$(create_autoinstall_iso)
    [[ -z "$auto_iso" ]] && exit 1

    # Subir ISO a Proxmox
    upload_iso_to_proxmox "$auto_iso"
    local iso_filename="ubuntu-autoinstall-ci.iso"

    # =============================================
    # Crear VM
    # =============================================
    log "Creando VM $tid..."

    local params="vmid=${tid}"
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
    # ISO de Ubuntu
    params+="&ide2=${VM_ISO_STORAGE}:iso/${VM_ISO},media=cdrom"
    # ISO de autoinstall
    params+="&ide3=${VM_ISO_STORAGE}:iso/${iso_filename},media=cdrom"
    params+="&boot=order=ide2"
    params+="&net0=virtio,bridge=vmbr0"

    local resp
    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$params" "POST")

    if echo "$resp" | grep -qi "error\|failed"; then
        log "Error al crear VM: $resp"
        rm -f "$auto_iso"
        exit 1
    fi

    rm -f "$auto_iso"
    log "VM creada"

    # =============================================
    # Iniciar VM (autoinstall begins)
    # =============================================
    log "Iniciando instalacion automatica de Ubuntu..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/start" "" "POST" >/dev/null 2>&1

    # Esperar a que la instalacion termine
    log "Ubuntu se esta instalando automaticamente (10-15 min)..."
    local max_wait=1800 elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/current" "" "GET" 2>/dev/null)

        if echo "$status" | grep -q '"running"'; then
            # Verificar si qemu-guest-agent responde (indica instalacion completa)
            local agent_ping
            agent_ping=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/agent/ping" "" "GET" 2>/dev/null)

            if echo "$agent_ping" | grep -qi '"data"'; then
                log "Instalacion completada - VM responsive"
                break
            fi
        fi

        if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
            log "   Instalando... (${elapsed}s/${max_wait}s)"
        fi

        sleep 15
        elapsed=$((elapsed + 15))
    done

    if [[ $elapsed -ge $max_wait ]]; then
        log "Timeout. Verifica la instalacion desde la consola de Proxmox."
    fi

    # =============================================
    # Preparar para template
    # =============================================
    log "Preparando template..."

    # Limpiar la VM via agent
    local ticket csrf
    ticket=$(get_proxmox_ticket)
    csrf=$(get_proxmox_csrf)

    local agent_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${tid}/agent/exec"

    # Limpiar cloud-init state y SSH keys
    curl -s -k -X POST "$agent_url" \
        --data-urlencode "command=bash" \
        --data-urlencode "args[0]=-c" \
        --data-urlencode "args[1]=rm -f /etc/ssh/ssh_host_* && rm -rf /var/lib/cloud/instance* /var/lib/cloud/instances/* && rm -f /var/run/runner-setup-complete && history -c" \
        -H "Authorization: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf" \
        -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

    sleep 2

    # Apagar VM
    log "Apagando VM..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/stop" "" "POST" >/dev/null 2>&1
    sleep 5

    # Convertir a template
    log "Convirtiendo a template..."
    local template_resp
    template_resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/template" "" "POST")

    if echo "$template_resp" | grep -qi '"data"'; then
        log ""
        log "================================================"
        log "  TEMPLATE CREADO EXITOSAMENTE"
        log "================================================"
        log ""
        log "  Template ID: $tid"
        log ""
        log "  Ahora puedes crear runners con:"
        log "  ./scripts/setup-runner.sh --repo asotonet/isp_billing"
        log ""
        log "================================================"
    else
        log "Error convirtiendo a template: $template_resp"
    fi
}

###############################################################################

main() {
    create_template "${TEMPLATE_ID}"
}

main "$@"
