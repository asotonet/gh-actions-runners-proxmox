#!/bin/bash
###############################################################################
# setup-runner.sh
# Automatizacion completa via API de Proxmox para crear VM con runner
#
# Flujo:
#   1. Clona VM desde un template base (Ubuntu + cloud-init + qemu-guest-agent)
#   2. Configura cloud-init (usuario, password, DNS)
#   3. Inicia la VM
#   4. Espera a que qemu-guest-agent responda
#   5. Via QEMU agent exec: instala Docker + GitHub Actions runner
#   6. Runner registrado y listo en GitHub
#
# TODO es automatico via API. Sin SSH ni scripts manuales.
#
# REQUISITO: Tener un template base creado previamente.
#   Crearlo una sola vez con: scripts/create-base-template.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: No se encontro config/env"
    exit 1
fi

source "$CONFIG_FILE"
source "$SCRIPT_DIR/utils.sh"

LOG_FILE="$ROOT_DIR/logs/setup-runner-$(date +%Y-%m-%d).log"
mkdir -p "$ROOT_DIR/logs"

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_PASS="RunnerSetup2024!"

###############################################################################

usage() {
    cat <<EOF
Uso: $0 --repo USUARIO/REPO [OPCIONES]

Opciones:
  --repo REPO       Repositorio (requerido)
  --org ORG         Organizacion (en lugar de --repo)
  --labels LABELS   Labels (default: self-hosted,linux,docker)
  --vm-id ID        ID de VM especifico (auto si no se da)
  --user USUARIO    Usuario del runner (default: runner)
  --help            Ayuda
EOF
    exit 0
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

###############################################################################
# Token de GitHub
###############################################################################

get_github_token() {
    local repo="$1" org="$2"
    local url=""
    [[ -n "$repo" ]] && url="https://api.github.com/repos/$repo/actions/runners/registration-token"
    [[ -n "$org" ]] && url="https://api.github.com/orgs/$org/actions/runners/registration-token"
    [[ -z "$url" ]] && { log "Error: --repo o --org requerido"; return 1; }

    log "Solicitando token de GitHub..."
    local resp
    resp=$(curl -s -X POST "$url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28")

    local token expires_at
    if command -v jq &>/dev/null; then
        token=$(echo "$resp" | jq -r '.token // empty')
        expires_at=$(echo "$resp" | jq -r '.expires_at // empty')
    else
        token=$(echo "$resp" | grep -o '"token": *"[^"]*"' | sed 's/.*"token": *"//;s/"$//')
        expires_at=$(echo "$resp" | grep -o '"expires_at": *"[^"]*"' | sed 's/.*"expires_at": *"//;s/"$//')
    fi
    [[ -z "$token" ]] && { log "Error al obtener token: $resp"; return 1; }
    log "Token obtenido (expira: $expires_at)"
    echo "$token"
}

###############################################################################
# Script de setup que se ejecuta DENTRO de la VM via QEMU agent
###############################################################################

generate_setup_script() {
    local runner_name="$1" github_url="$2" token="$3" labels="$4"

    cat <<'SETUPEOF'
#!/bin/bash
set -e
exec > >(tee /var/log/runner-setup.log) 2>&1
SETUPEOF

    # Variables que se sustituyen antes de enviar
    cat <<EOF
RUNNER_USER='${RUNNER_USER}'
RUNNER_NAME='${runner_name}'
GITHUB_URL='${github_url}'
RUNNER_TOKEN='${token}'
LABELS='${labels}'
EOF

    cat <<'SETUPEOF'
RUNNER_VERSION='${RUNNER_VERSION:-latest}'
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"

echo "=== [1/4] Paquetes esenciales ==="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release git wget jq make build-essential unzip tar gzip 2>/dev/null || true

echo "=== [2/4] Docker Engine ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true

echo "=== [3/4] Configurar Docker ==="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DEOF'
{"storage-driver":"overlay2","data-root":"/var/lib/docker","log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"features":{"buildkit":true}}
DEOF
systemctl daemon-reload && systemctl enable docker && systemctl restart docker

echo "=== [4/4] GitHub Actions Runner ==="
# Obtener version si es latest
[[ "$RUNNER_VERSION" == "latest" ]] && RUNNER_VERSION=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | grep -o '"tag_name":"[^"]*"' | sed 's/.*"tag_name":"//;s/"$//' | sed 's/^v//')
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

mkdir -p "$RUNNER_DIR/_work"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
chmod 755 "$RUNNER_DIR/_work"
usermod -aG docker "${RUNNER_USER}" 2>/dev/null || true

# Descargar e instalar runner como el usuario runner
su - "${RUNNER_USER}" -c "cd $RUNNER_DIR && curl -sL '$RUNNER_URL' -o runner.tar.gz && tar xzf runner.tar.gz && rm runner.tar.gz"
su - "${RUNNER_USER}" -c "cd $RUNNER_DIR && ./config.sh --unattended --url '$GITHUB_URL' --token '$RUNNER_TOKEN' --name '$RUNNER_NAME' --labels '$LABELS' --work '_work'"
cd "$RUNNER_DIR" && ./svc.sh install "${RUNNER_USER}"
cd "$RUNNER_DIR" && ./svc.sh start

chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
chmod -R 750 "$RUNNER_DIR"

echo "=== Runner configurado exitosamente ==="
touch /var/run/runner-setup-complete
SETUPEOF
}

###############################################################################
# Crear VM desde template
###############################################################################

create_vm() {
    local vm_id="$1" vm_name="$2" runner_name="$3" repo="$4" org="$5" labels="$6" token="$7"

    local memory="${VM_MEMORY:-4096}"
    local cores="${VM_CPUS:-4}"
    local disk="${VM_DISK:-30}"
    local template_id="${VM_TEMPLATE:-9000}"

    local github_url
    [[ -n "$repo" ]] && github_url="https://github.com/$repo" || github_url="https://github.com/$org"

    # =============================================
    # Clonar desde template (full clone)
    # =============================================
    log "Clonando template $template_id -> VM $vm_id..."

    local params="vmid=${vm_id}"
    params+="&name=${vm_name}"
    params+="&full=1"
    params+="&storage=${VM_STORAGE}"

    local resp
    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$template_id/clone" "$params" "POST")

    if echo "$resp" | grep -qi "error\|failed"; then
        log "Error al clonar template: $resp"
        log ""
        log "¿Existe el template $template_id?"
        log "Crealo con: ./scripts/create-base-template.sh --template-id $template_id"
        return 1
    fi

    log "VM clonada correctamente"

    # =============================================
    # Reconfigurar VM (recursos + cloud-init)
    # =============================================
    log "Configurando recursos y cloud-init..."

    local reconfig="memory=${memory}"
    reconfig+="&cores=${cores}"
    reconfig+="&sockets=1"
    reconfig+="&ciuser=${RUNNER_USER}"
    reconfig+="&cipassword=${RUNNER_PASS}"
    reconfig+="&nameserver=8.8.8.8"

    resp=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/config" "$reconfig" "PUT")

    # Regenerar cloud-init ISO
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/cloudinit" "" "POST" >/dev/null 2>&1

    # =============================================
    # Iniciar VM
    # =============================================
    log "Iniciando VM..."
    proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/status/start" "" "POST" >/dev/null 2>&1

    # =============================================
    # Esperar qemu-guest-agent
    # =============================================
    log "Esperando a que la VM inicie..."
    local max_wait=300 elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local ping
        ping=$(proxmox_api_request "/nodes/$PROXMOX_NODE/qemu/$vm_id/agent/ping" "" "GET" 2>/dev/null)
        if echo "$ping" | grep -qi '"data"'; then
            log "VM lista y responsive"
            break
        fi
        [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]] && log "   Esperando... (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    # =============================================
    # Ejecutar setup via QEMU agent exec
    # =============================================
    log "Ejecutando setup del runner..."

    local setup_script
    setup_script=$(generate_setup_script "$runner_name" "$github_url" "$token" "$labels")

    local ticket csrf
    ticket=$(get_proxmox_ticket 2>/dev/null)
    csrf=$(get_proxmox_csrf 2>/dev/null)

    if [[ -n "$ticket" && -n "$csrf" ]]; then
        local agent_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes/${PROXMOX_NODE}/qemu/${vm_id}/agent/exec"

        # Test
        local test_resp
        test_resp=$(curl -s -k -X POST "$agent_url" \
            --data-urlencode "command=echo" \
            --data-urlencode "args[0]=ready" \
            -H "Authorization: PVEAuthCookie=$ticket" \
            -H "CSRFPreventionToken: $csrf" \
            -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)

        if echo "$test_resp" | grep -qi '"data"'; then
            log "QEMU agent disponible - ejecutando setup completo..."

            # Escribir script en /tmp dentro de la VM
            local encoded
            encoded=$(echo "$setup_script" | base64 -w 0 2>/dev/null || echo "$setup_script" | base64 | tr -d '\n')

            # Paso 1: escribir
            curl -s -k -X POST "$agent_url" \
                --data-urlencode "command=bash" \
                --data-urlencode "args[0]=-c" \
                --data-urlencode "args[1]=echo '$encoded' | base64 -d > /tmp/setup-runner.sh && chmod +x /tmp/setup-runner.sh" \
                -H "Authorization: PVEAuthCookie=$ticket" \
                -H "CSRFPreventionToken: $csrf" \
                -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

            sleep 2

            # Paso 2: ejecutar (background para que no bloquee)
            curl -s -k -X POST "$agent_url" \
                --data-urlencode "command=bash" \
                --data-urlencode "args[0]=/tmp/setup-runner.sh" \
                -H "Authorization: PVEAuthCookie=$ticket" \
                -H "CSRFPreventionToken: $csrf" \
                -H "Content-Type: application/x-www-form-urlencoded" >/dev/null 2>&1

            log "Setup enviado. Instalando Docker y runner (5-10 min)..."

            # Esperar a que termine
            local setup_wait=600 setup_elapsed=0
            while [[ $setup_elapsed -lt $setup_wait ]]; do
                local check
                check=$(curl -s -k -X POST "$agent_url" \
                    --data-urlencode "command=bash" \
                    --data-urlencode "args[0]=-c" \
                    --data-urlencode "args[1]=test -f /var/run/runner-setup-complete && echo DONE || echo WORKING" \
                    -H "Authorization: PVEAuthCookie=$ticket" \
                    -H "CSRFPreventionToken: $csrf" \
                    -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)

                if echo "$check" | grep -q "DONE"; then
                    log "Setup del runner completado"
                    break
                fi
                [[ $((setup_elapsed % 60)) -eq 0 && $setup_elapsed -gt 0 ]] && log "   Configurando... (${setup_elapsed}s)"
                sleep 10
                setup_elapsed=$((setup_elapsed + 10))
            done
        else
            log "QEMU agent no responde. Verifica que qemu-guest-agent este instalado en el template."
        fi
    fi

    log "VM QEMU creada: $vm_id"
    echo "$vm_id"
}

###############################################################################
# Argumentos
###############################################################################

REPO="" ORG="" LABELS="self-hosted,linux,docker" VM_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --org) ORG="$2"; shift 2 ;;
        --labels) LABELS="$2"; shift 2 ;;
        --vm-id) VM_ID="$2"; shift 2 ;;
        --user) RUNNER_USER="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Opcion: $1"; usage ;;
    esac
done

[[ -z "$REPO" && -z "$ORG" ]] && { echo "Error: --repo o --org"; usage; }

###############################################################################
# Main
###############################################################################

main() {
    log "================================================"
    log "  GitHub Actions Runner - Setup Automatico"
    log "================================================"

    # Validar
    for var in PROXMOX_HOST PROXMOX_PORT PROXMOX_USER PROXMOX_PASSWORD PROXMOX_NODE GITHUB_TOKEN VM_STORAGE; do
        [[ -z "${!var:-}" ]] && { echo "Error: $var no definida"; exit 1; }
    done

    # VM ID
    [[ -z "$VM_ID" ]] && {
        VM_ID=$(generate_vm_id)
        [[ $? -ne 0 ]] && { log "Error generando VM ID"; exit 1; }
        log "VM ID: $VM_ID"
    }

    local repo_or_org
    [[ -n "$REPO" ]] && repo_or_org="repos/$REPO" || repo_or_org="orgs/$ORG"

    # Token
    local token
    token=$(get_github_token "$REPO" "$ORG")
    [[ -z "$token" ]] && exit 1

    local runner_name="runner-${VM_ID}"
    log "Runner: $runner_name"

    create_vm "$VM_ID" "runner-${runner_name}" "$runner_name" "$repo_or_org" "$ORG" "$LABELS" "$token"

    log "================================================"
    log "  Runner configurado"
    log "  VM: $VM_ID | CPU: ${VM_CPUS:-4} | RAM: ${VM_MEMORY:-4096}MB | Disco: ${VM_DISK:-30}GB"
    log "  URL: https://github.com/${repo_or_org}/settings/actions/runners"
    log "================================================"
}

main "$@"
