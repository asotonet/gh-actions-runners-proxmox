#!/bin/bash
###############################################################################
# create-base-template.sh
# Crea automaticamente un template base de Ubuntu con cloud-init + qemu-guest-agent
#
# TODO es automatico via API de Proxmox. No requiere intervencion manual.
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
# Crear ISO de cloud-init con user-data + meta-data (usando Python puro)
###############################################################################

create_cloudinit_iso() {
    local tmp_dir="/tmp/ci-iso-$$"
    mkdir -p "$tmp_dir"

    # user-data para autoinstall de Ubuntu
    cat > "$tmp_dir/user-data" << 'AUTOEOF'
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
    - echo 'runner ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/runner
    - chmod 440 /target/etc/sudoers.d/runner
    - curtin in-target --target=/target -- systemctl enable qemu-guest-agent
    - curtin in-target --target=/target -- systemctl enable cloud-init
    - curtin in-target --target=/target -- systemctl enable ssh
    - curtin in-target --target=/target -- rm -f /etc/ssh/ssh_host_*
    - curtin in-target --target=/target -- rm -rf /var/lib/cloud/instance*
    - curtin in-target --target=/target -- rm -rf /var/lib/cloud/instances/*
    - curtin in-target --target=/target -- history -c
  error-commands:
    - sh -c 'cat /var/log/installer/syslog'
AUTOEOF

    cat > "$tmp_dir/meta-data" << EOF
instance-id: ubuntu-base-template
local-hostname: ubuntu-base
EOF

    # Crear ISO usando Python (sin dependencias externas)
    local iso_path="/tmp/ubuntu-autoinstall-ci.iso"
    python3 - "$tmp_dir" "$iso_path" << 'PYEOF'
import sys, struct, os

tmp_dir = sys.argv[1]
iso_path = sys.argv[2]
sector_size = 2048

user_data = open(os.path.join(tmp_dir, "user-data")).read()
meta_data = open(os.path.join(tmp_dir, "meta-data")).read()

def pad(data):
    r = len(data) % sector_size
    return data.encode() if isinstance(data, str) else data
    return (data if isinstance(data, bytes) else data.encode()) + (b'\x00' * ((sector_size - r) % sector_size))

def dr(name, extent, size, flags=0):
    nb = name.encode()
    d = struct.pack('<BIIBBBBBBBB', 0, extent, size, 0,0,0,0,0,0,0,0,0,0,0,0,0, flags, 0,0,0,0,0,0, len(nb)) + nb
    if len(d) % 2: d += b'\x00'
    d = struct.pack('<B', len(d)) + d[1:]
    return d

ud = pad(user_data)
md = pad(meta_data)
root_ext = 18
ud_ext = 19
md_ext = ud_ext + len(ud) // sector_size

root = dr('.', root_ext, 0, 2) + dr('..', root_ext, 0, 2) + dr('user-data', ud_ext, len(user_data)) + dr('meta-data', md_ext, len(meta_data))
root = root + b'\x00' * (sector_size - len(root))

pvd = b'\x01CD001\x01\x00' + b' ' * 32 + b'cidata' + b' ' * 26
pvd += struct.pack('<I', md_ext + 1) + b'\x00' * 32 + struct.pack('<HHH', 1, 1, sector_size)
pvd += struct.pack('<IIII', 0, 0, 0, 0)
pvd += root[:34] + b'\x00' * (sector_size - len(pvd))

iso = b'\x00' * 16 * sector_size + pvd + b'\x00' * sector_size + root + ud + md
with open(iso_path, 'wb') as f: f.write(iso)
print(f"ISO created: {len(iso)} bytes")
PYEOF

    rm -rf "$tmp_dir"
    [[ ! -f "$iso_path" ]] && { log "Error creando ISO"; return 1; }
    log "ISO creada: $iso_path"
    echo "$iso_path"
}

###############################################################################
# Subir ISO a Proxmox via API
###############################################################################

upload_iso() {
    local iso_path="$1"
    local iso_name="ubuntu-autoinstall-ci.iso"

    log "Subiendo ISO a Proxmox..."

    local ticket csrf
    ticket=$(get_proxmox_ticket)
    csrf=$(get_proxmox_csrf)

    local resp
    resp=$(curl -s -k -w "\n%{http_code}" -X POST \
        "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/storage/${VM_ISO_STORAGE}/upload" \
        -F "content=iso" \
        -F "filename=@${iso_path}" \
        -H "Authorization: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf" 2>/dev/null)

    local http_code
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [[ "$http_code" == "200" ]] || echo "$resp" | grep -qi '"data"'; then
        log "ISO subida"
        return 0
    else
        log "Error subiendo ISO (HTTP $http_code): ${resp:0:200}"
        return 1
    fi
}

###############################################################################
# Crear template
###############################################################################

create_template() {
    local tid="${1:-$TEMPLATE_ID}"

    log "================================================"
    log "  Creando template base automatico: $tid"
    log "================================================"

    # Verificar que no exista
    local check
    check=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/config" "" "GET" 2>/dev/null)
    if echo "$check" | grep -qi '"data"'; then
        log "Error: VM $tid ya existe. Eliminala: qm destroy $tid"
        exit 1
    fi

    # Crear y subir ISO
    local auto_iso
    auto_iso=$(create_cloudinit_iso)
    [[ -z "$auto_iso" ]] && exit 1

    upload_iso "$auto_iso"
    rm -f "$auto_iso"

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
    params+="&ide2=${VM_ISO_STORAGE}:iso/${VM_ISO},media=cdrom"
    params+="&ide3=${VM_ISO_STORAGE}:iso/ubuntu-autoinstall-ci.iso,media=cdrom"
    params+="&boot=order=ide2"
    params+="&net0=virtio,bridge=vmbr0"

    local resp
    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu" "$params" "POST")

    if echo "$resp" | grep -qi "error\|failed"; then
        log "Error al crear VM: $resp"
        exit 1
    fi

    log "VM creada"

    # =============================================
    # Iniciar instalacion automatica
    # =============================================
    log "Iniciando instalacion automatica de Ubuntu..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/start" "" "POST" >/dev/null 2>&1

    # Esperar a que termine la instalacion
    log "Ubuntu se esta instalando automaticamente (10-15 min)..."
    local max_wait=1800 elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/current" "" "GET" 2>/dev/null)

        if echo "$status" | grep -q '"running"'; then
            local agent_ping
            agent_ping=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/agent/ping" "" "GET" 2>/dev/null)
            if echo "$agent_ping" | grep -qi '"data"'; then
                log "Instalacion completada - VM responsive con agent"
                break
            fi
        fi

        [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]] && log "   Instalando... (${elapsed}s/${max_wait}s)"
        sleep 15
        elapsed=$((elapsed + 15))
    done

    [[ $elapsed -ge $max_wait ]] && log "Timeout - verifica desde consola de Proxmox"

    # =============================================
    # Preparar y convertir a template
    # =============================================
    log "Preparando template..."

    local ticket csrf
    ticket=$(get_proxmox_ticket)
    csrf=$(get_proxmox_csrf)
    local agent_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${tid}/agent/exec"

    # Limpiar
    curl -s -k -X POST "$agent_url" \
        --data-urlencode "command=bash" \
        --data-urlencode "args[0]=-c" \
        --data-urlencode "args[1]=rm -f /etc/ssh/ssh_host_* && rm -rf /var/lib/cloud/instance* /var/lib/cloud/instances/* && history -c" \
        -H "Authorization: PVEAuthCookie=$ticket" \
        -H "CSRFPreventionToken: $csrf" \
        -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

    sleep 2

    # Apagar
    log "Apagando VM..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/status/stop" "" "POST" >/dev/null 2>&1
    sleep 5

    # Convertir a template
    log "Convirtiendo a template..."
    local tpl_resp
    tpl_resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$tid/template" "" "POST")

    if echo "$tpl_resp" | grep -qi '"data"'; then
        log ""
        log "================================================"
        log "  TEMPLATE CREADO EXITOSAMENTE (ID: $tid)"
        log "================================================"
        log ""
        log "  Ahora crea runners con:"
        log "  ./scripts/setup-runner.sh --repo asotonet/isp_billing"
        log ""
        log "================================================"
    else
        log "Error convirtiendo a template: $tpl_resp"
    fi
}

###############################################################################

main() { create_template "${TEMPLATE_ID}"; }
main "$@"
