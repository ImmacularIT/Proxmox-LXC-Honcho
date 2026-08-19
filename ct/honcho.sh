#!/usr/bin/env bash
# Copyright (c) 2026 ImmacularIT
# License: MIT
# Proxmox-host launcher for the native Honcho Debian 13 LXC adaptation.
set -Eeuo pipefail

APP="Honcho"
PROJECT_OWNER="ImmacularIT"
PROJECT_REPO="Proxmox-LXC-Honcho"
PROJECT_REF="${HONCHO_PROJECT_REF:-development}"
PROJECT_URL="https://github.com/${PROJECT_OWNER}/${PROJECT_REPO}"
PROJECT_INSTALL_URL="https://raw.githubusercontent.com/${PROJECT_OWNER}/${PROJECT_REPO}/${PROJECT_REF}/install/honcho-install.sh"
UPSTREAM_PROJECT_URL="https://github.com/plastic-labs/honcho"
BACKTITLE="ImmacularIT - ${APP}"

DEFAULT_DISK=20
DEFAULT_CPU=2
DEFAULT_RAM=4096
DEFAULT_HOSTNAME="honcho"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TAGS="honcho;ai-memory;immacularit"

CTID=""
HN=""
ROOT_STORAGE=""
TEMPLATE_STORAGE="${HONCHO_TEMPLATE_STORAGE:-}"
BRG="$DEFAULT_BRIDGE"
NET="dhcp"
GATE=""
VLAN=""
CPU="$DEFAULT_CPU"
RAM="$DEFAULT_RAM"
DISK="$DEFAULT_DISK"
ONBOOT=1
INSTALL_LOG=""
LLM_MODE=""
LLM_API_KEY=""
LLM_BASE_URL=""
LLM_MODEL=""

info() { printf '\n  ⏳ %s: ' "${1%:}"; }
ok() { printf '\n  ✔️  %s\n' "$1"; }
warn() { printf '\n  ⚠️  %s\n' "$1" >&2; }
fatal() { printf '\n  ✖️  %s\n' "$1" >&2; exit 1; }

cleanup_temp=()
cleanup() {
  local f
  for f in "${cleanup_temp[@]:-}"; do
    [[ -n "$f" ]] && rm -f -- "$f"
  done
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command is missing on the Proxmox host: $1"
}

for cmd in pveversion pvesh pct pvesm pveam curl whiptail awk grep sed sort ip dpkg; do
  require_command "$cmd"
done

[[ "$(id -u)" -eq 0 ]] || fatal "Run this launcher directly as root on the Proxmox VE host"
PVE_RAW="$(pveversion)"
PVE_VERSION="$(printf '%s' "$PVE_RAW" | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
[[ "$PVE_VERSION" == 9.* ]] || fatal "This project currently targets Proxmox VE 9.x; found ${PVE_RAW}"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || fatal "The current runtime test gate supports AMD64 only"

show_welcome() {
  whiptail --backtitle "$BACKTITLE" --title "WELCOME" --ok-button "Continue" \
    --msgbox "\nThis ImmacularIT installer creates an unprivileged Debian 13 LXC and installs Honcho natively.\n\nThe final container uses PostgreSQL + pgvector, Redis, Python, and systemd. Docker, Podman, Kubernetes, and other nested application runtimes are not installed.\n\nThe installer will ask how Honcho should reach its LLM provider, then show the complete container configuration before creation.\n\nThis development branch has not yet completed the real-Proxmox runtime matrix." \
    21 78
}

valid_container_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  ! pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | grep -Eq '"vmid"[[:space:]]*:[[:space:]]*'"$id"'([,}])'
}

valid_hostname() {
  local name="$1" label
  [[ ${#name} -ge 1 && ${#name} -le 253 ]] || return 1
  [[ "$name" =~ ^[a-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$name"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" != -* && "$label" != *- ]] || return 1
  done
}

valid_ipv4() {
  local ip="$1" a b c d n
  IFS='.' read -r a b c d <<<"$ip"
  [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
}

valid_cidr() {
  local value="$1" ip prefix
  [[ "$value" == */* ]] || return 1
  ip="${value%/*}"
  prefix="${value#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 ))
}

ip_to_int() {
  local ip="$1" a b c d
  IFS='.' read -r a b c d <<<"$ip"
  printf '%u' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

gateway_in_subnet() {
  local cidr="$1" gw="$2" ip prefix ipn gwn mask
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$gw" || return 1
  ipn="$(ip_to_int "$ip")"
  gwn="$(ip_to_int "$gw")"
  if (( prefix == 0 )); then return 0; fi
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (ipn & mask) == (gwn & mask) ))
}

valid_vlan() {
  local vlan="$1"
  [[ -z "$vlan" ]] && return 0
  [[ "$vlan" =~ ^[0-9]+$ ]] && (( vlan >= 1 && vlan <= 4094 ))
}

select_storage() {
  local selected default_storage
  local -a stores=() menu=()
  mapfile -t stores < <(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
  [[ ${#stores[@]} -gt 0 ]] || fatal "No active Proxmox storage supports LXC root disks"
  default_storage="${stores[0]}"
  for selected in "${stores[@]}"; do menu+=("$selected" "Active container storage"); done
  selected=$(whiptail --backtitle "$BACKTITLE" --title "STORAGE" --ok-button "Next" --cancel-button "Exit Script" \
    --menu "\nSelect storage for the LXC root disk:" 18 72 10 "${menu[@]}" --default-item "$default_storage" 3>&1 1>&2 2>&3) || exit 0
  printf '%s' "$selected"
}

resolve_template_storage() {
  local latest_template="${1:-}" requested="${TEMPLATE_STORAGE:-}" storage
  local -a stores=()
  mapfile -t stores < <(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
  [[ ${#stores[@]} -gt 0 ]] || fatal "No active Proxmox storage supports container templates"
  if [[ -n "$requested" ]]; then
    for storage in "${stores[@]}"; do [[ "$storage" == "$requested" ]] && { printf '%s' "$storage"; return 0; }; done
    fatal "Requested template storage is not active or does not support vztmpl: ${requested}"
  fi
  if [[ -n "$latest_template" ]]; then
    for storage in "${stores[@]}"; do
      if pveam list "$storage" 2>/dev/null | awk -v wanted="vztmpl/${latest_template}" 'length($1)>=length(wanted) && substr($1,length($1)-length(wanted)+1)==wanted {found=1} END {exit !found}'; then
        printf '%s' "$storage"; return 0
      fi
    done
  fi
  for storage in "${stores[@]}"; do
    if pveam list "$storage" 2>/dev/null | awk '$1 ~ /debian-13-standard_.*_amd64\.tar\.zst$/ {found=1} END {exit !found}'; then
      printf '%s' "$storage"; return 0
    fi
  done
  for storage in "${stores[@]}"; do [[ "$storage" == "local" ]] && { printf '%s' "$storage"; return 0; }; done
  printf '%s' "${stores[0]}"
}

select_bridge() {
  local path bridge selected
  local -a bridges=() menu=()
  for path in /sys/class/net/*/bridge; do
    [[ -d "$path" ]] || continue
    bridge="${path%/bridge}"; bridge="${bridge##*/}"; bridges+=("$bridge")
  done
  [[ ${#bridges[@]} -gt 0 ]] || fatal "No Proxmox network bridge was found"
  for bridge in "${bridges[@]}"; do menu+=("$bridge" "Available bridge"); done
  selected=$(whiptail --backtitle "$BACKTITLE" --title "NETWORK BRIDGE" --ok-button "Next" --cancel-button "Exit Script" \
    --menu "\nSelect the bridge for this container:" 18 72 10 "${menu[@]}" --default-item "$DEFAULT_BRIDGE" 3>&1 1>&2 2>&3) || exit 0
  printf '%s' "$selected"
}

prompt_identity() {
  local suggested id name
  suggested="$(pvesh get /cluster/nextid 2>/dev/null)"
  while true; do
    id=$(whiptail --backtitle "$BACKTITLE" --title "CONTAINER ID" --inputbox "\nContainer ID" 10 62 "$suggested" 3>&1 1>&2 2>&3) || exit 0
    valid_container_id "$id" && { CTID="$id"; break; }
    whiptail --backtitle "$BACKTITLE" --title "INVALID CONTAINER ID" --msgbox "Container ID must be numeric and unused across the cluster." 9 62
  done
  while true; do
    name=$(whiptail --backtitle "$BACKTITLE" --title "CONTAINER NAME" --inputbox "\nContainer name" 10 66 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3) || exit 0
    name="${name,,}"; name="${name// /}"
    valid_hostname "$name" && { HN="$name"; break; }
    whiptail --backtitle "$BACKTITLE" --title "INVALID CONTAINER NAME" --msgbox "Use lowercase letters, numbers, dots and hyphens only." 9 66
  done
}

prompt_network() {
  local method static_ip gateway vlan
  BRG="$(select_bridge)"
  method=$(whiptail --backtitle "$BACKTITLE" --title "IPv4" --menu "\nChoose IPv4 configuration:" 14 68 2 \
    "dhcp" "Automatic address from DHCP" "static" "Static IPv4 address" --default-item "dhcp" 3>&1 1>&2 2>&3) || exit 0
  if [[ "$method" == "static" ]]; then
    while true; do
      static_ip=$(whiptail --backtitle "$BACKTITLE" --title "STATIC IPv4" --inputbox "\nIPv4 address in CIDR form" 10 68 "" 3>&1 1>&2 2>&3) || exit 0
      valid_cidr "$static_ip" && break
    done
    while true; do
      gateway=$(whiptail --backtitle "$BACKTITLE" --title "IPv4 GATEWAY" --inputbox "\nGateway for ${static_ip}" 10 62 "" 3>&1 1>&2 2>&3) || exit 0
      gateway_in_subnet "$static_ip" "$gateway" && break
    done
    NET="$static_ip"; GATE="$gateway"
  fi
  while true; do
    vlan=$(whiptail --backtitle "$BACKTITLE" --title "VLAN" --inputbox "\nOptional VLAN tag (1-4094), blank for none" 10 64 "" 3>&1 1>&2 2>&3) || exit 0
    valid_vlan "$vlan" && { VLAN="$vlan"; break; }
  done
}

prompt_llm() {
  local choice key base model
  choice=$(whiptail --backtitle "$BACKTITLE" --title "LLM PROVIDER" --menu \
    "\nHoncho requires an LLM provider. Choose the initial configuration:" 16 76 2 \
    "openai" "OpenAI direct (uses Honcho upstream default models)" \
    "compatible" "OpenAI-compatible endpoint (Ollama, vLLM, LiteLLM, etc.)" \
    --default-item "openai" 3>&1 1>&2 2>&3) || exit 0
  case "$choice" in
    openai)
      key=$(whiptail --backtitle "$BACKTITLE" --title "OPENAI API KEY" --passwordbox "\nEnter the OpenAI API key used by Honcho." 11 72 3>&1 1>&2 2>&3) || exit 0
      [[ -n "$key" ]] || fatal "An API key is required"
      LLM_MODE="openai"; LLM_API_KEY="$key"
      ;;
    compatible)
      base=$(whiptail --backtitle "$BACKTITLE" --title "COMPATIBLE ENDPOINT" --inputbox \
        "\nEnter the OpenAI-compatible base URL. Example: http://192.168.1.10:11434/v1" 12 78 "" 3>&1 1>&2 2>&3) || exit 0
      [[ "$base" == http://* || "$base" == https://* ]] || fatal "Base URL must begin with http:// or https://"
      model=$(whiptail --backtitle "$BACKTITLE" --title "MODEL" --inputbox \
        "\nEnter one tool-capable model name to use for all Honcho reasoning tiers initially." 12 78 "" 3>&1 1>&2 2>&3) || exit 0
      [[ -n "$model" ]] || fatal "A model name is required"
      key=$(whiptail --backtitle "$BACKTITLE" --title "API KEY" --passwordbox \
        "\nEnter the endpoint API key. For local servers that ignore authentication, use a placeholder such as ollama." 12 78 3>&1 1>&2 2>&3) || exit 0
      [[ -n "$key" ]] || fatal "An API key or placeholder is required"
      LLM_MODE="compatible"; LLM_API_KEY="$key"; LLM_BASE_URL="$base"; LLM_MODEL="$model"
      ;;
  esac
}

prompt_advanced_resources() {
  local value
  while true; do value=$(whiptail --backtitle "$BACKTITLE" --title "CPU CORES" --inputbox "\nCPU cores" 9 54 "$CPU" 3>&1 1>&2 2>&3) || exit 0; [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 128 )) && { CPU="$value"; break; }; done
  while true; do value=$(whiptail --backtitle "$BACKTITLE" --title "RAM" --inputbox "\nRAM in MiB" 9 54 "$RAM" 3>&1 1>&2 2>&3) || exit 0; [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 2048 )) && { RAM="$value"; break; }; done
  while true; do value=$(whiptail --backtitle "$BACKTITLE" --title "DISK" --inputbox "\nRoot disk size in GiB" 9 54 "$DISK" 3>&1 1>&2 2>&3) || exit 0; [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 12 )) && { DISK="$value"; break; }; done
}

confirm_configuration() {
  local llm_summary configuration
  llm_summary="$LLM_MODE"
  [[ "$LLM_MODE" == "compatible" ]] && llm_summary="compatible (${LLM_BASE_URL}, model ${LLM_MODEL})"
  configuration=$(cat <<EOF_CONFIGURATION
Install method: ${method^}
Container ID: ${CTID}
Hostname: ${HN}
Container type: Unprivileged Debian 13
Storage: ${ROOT_STORAGE}
Disk: ${DISK} GiB
CPU: ${CPU} cores
RAM: ${RAM} MiB
Bridge: ${BRG}
IPv4: ${NET}
Gateway: ${GATE:-DHCP/none}
VLAN: ${VLAN:-none}
LLM mode: ${llm_summary}

Create this container and begin the native installation?
EOF_CONFIGURATION
)
  whiptail --backtitle "$BACKTITLE" --title "REVIEW CONFIGURATION" --yes-button "Install" --no-button "Cancel" --yesno "$configuration" 23 82
}

find_or_download_template() {
  local available="$1" existing existing_name newest_name
  existing=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '$1 ~ /debian-13-standard_.*_amd64\.tar\.zst$/ {print $1}' | sort -V | tail -n1)
  if [[ -n "$existing" ]]; then
    existing_name="${existing##*/}"
    newest_name=$(printf '%s\n%s\n' "$existing_name" "$available" | sort -V | tail -n1)
    if [[ "$existing_name" == "$available" || "$newest_name" == "$existing_name" ]]; then printf '%s' "$existing"; return 0; fi
  fi
  pveam download "$TEMPLATE_STORAGE" "$available" >&2 || fatal "Failed to download Debian template"
  printf '%s:vztmpl/%s' "$TEMPLATE_STORAGE" "$available"
}

set_project_description() {
  local project_description
  project_description=$(cat <<EOF_DESCRIPTION
<div align='center'>
  <h2>Honcho Native LXC</h2>
  <p>Unofficial native Debian 13 Proxmox LXC adaptation of Honcho. PostgreSQL, pgvector, Redis, Python, and systemd run directly in the container; no nested Docker/Podman runtime is used.</p>
  <p><a href='${UPSTREAM_PROJECT_URL}' target='_blank'>Official Honcho upstream</a> &nbsp;|&nbsp; <a href='${PROJECT_URL}' target='_blank'>ImmacularIT adaptation</a> &nbsp;|&nbsp; <a href='${PROJECT_URL}/issues' target='_blank'>Issues</a></p>
</div>
EOF_DESCRIPTION
)
  pct set "$CTID" --description "$project_description" >/dev/null
}

handle_install_failure() {
  local rc="$1" choice="keep"
  printf '\n  ✖️  Installation failed in container %s (exit code %s)\n' "$CTID" "$rc" >&2
  [[ -n "$INSTALL_LOG" ]] && printf '  📋 Host-side installation log: %s\n' "$INSTALL_LOG" >&2
  if [[ -t 0 ]]; then
    choice=$(whiptail --backtitle "$BACKTITLE" --title "INSTALLATION FAILED" --menu "\nKeep the container for debugging or destroy it?" 14 72 2 \
      "keep" "Keep container ${CTID} for debugging" "destroy" "Stop and permanently destroy container ${CTID}" --default-item "keep" 3>&1 1>&2 2>&3) || choice="keep"
  fi
  if [[ "$choice" == "destroy" ]]; then pct stop "$CTID" >/dev/null 2>&1 || true; pct destroy "$CTID" --purge 1; else warn "Container ${CTID} kept for debugging"; fi
  exit "$rc"
}

show_welcome
method_choice=$(whiptail --backtitle "$BACKTITLE" --title "INSTALL OPTIONS" --menu "\nChoose an option:" 14 62 2 \
  "Default Install" "" "Advanced Install" "" --default-item "Default Install" 3>&1 1>&2 2>&3) || exit 0
case "$method_choice" in "Default Install") method="default" ;; "Advanced Install") method="advanced" ;; *) fatal "Unknown install method" ;; esac

prompt_identity
ROOT_STORAGE="$(select_storage)"
prompt_network
prompt_llm
[[ "$method" == "advanced" ]] && prompt_advanced_resources
confirm_configuration || exit 0

clear || true
printf '  ⚙️  Using %s Install on node %s\n' "${method^}" "$(hostname)"
printf '  🆔  Container ID: %s\n' "$CTID"
printf '  🏠  Hostname: %s\n' "$HN"
printf '  📦  Container Type: Unprivileged Debian 13 (nesting=1, keyctl disabled)\n'
printf '  💾  Disk: %s GiB on %s\n' "$DISK" "$ROOT_STORAGE"
printf '  🧠  CPU/RAM: %s cores / %s MiB\n' "$CPU" "$RAM"
printf '  🌐  IPv4: %s via %s\n' "$NET" "$BRG"
printf '  🤖  LLM mode: %s\n' "$LLM_MODE"

info "Refreshing official Proxmox appliance catalog"
pveam update || fatal "Failed to refresh the Proxmox appliance catalog"
LATEST_TEMPLATE=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' | sort -V | tail -n1)
[[ -n "$LATEST_TEMPLATE" ]] || fatal "No Debian 13 AMD64 standard template is available"
TEMPLATE_STORAGE="$(resolve_template_storage "$LATEST_TEMPLATE")"
TEMPLATE="$(find_or_download_template "$LATEST_TEMPLATE")"
ok "Debian template ready: ${TEMPLATE##*/}"

net0="name=eth0,bridge=${BRG},ip=${NET},ip6=auto,type=veth"
[[ -n "$GATE" ]] && net0+=",gw=${GATE}"
[[ -n "$VLAN" ]] && net0+=",tag=${VLAN}"
create_args=("$CTID" "$TEMPLATE" --hostname "$HN" --cores "$CPU" --memory "$RAM" --swap 512 \
  --rootfs "${ROOT_STORAGE}:${DISK}" --unprivileged 1 --features nesting=1 --ostype debian --net0 "$net0" \
  --onboot "$ONBOOT" --tags "$DEFAULT_TAGS" --start 0)

info "Creating Debian 13 unprivileged LXC ${CTID}"
pct create "${create_args[@]}"
ok "LXC container ${CTID} created"
set_project_description

info "Starting LXC container ${CTID}"
pct start "$CTID"
for _ in {1..60}; do pct exec "$CTID" -- true >/dev/null 2>&1 && break; sleep 1; done
pct exec "$CTID" -- true >/dev/null 2>&1 || handle_install_failure 117

IP=""
for _ in {1..60}; do
  IP="$(pct exec "$CTID" -- sh -c "hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | head -n1" 2>/dev/null || true)"
  [[ -n "$IP" ]] && break
  sleep 1
done
[[ -n "$IP" ]] || handle_install_failure 118
ok "Network connected: ${IP}"

installer_tmp="$(mktemp)"
config_tmp="$(mktemp)"
cleanup_temp+=("$installer_tmp" "$config_tmp")
info "Downloading the ImmacularIT native installer"
curl -fsSL --retry 3 --retry-delay 2 "$PROJECT_INSTALL_URL" -o "$installer_tmp"
[[ -s "$installer_tmp" ]] || fatal "Downloaded an empty installer"
{
  printf 'HONCHO_LLM_MODE=%q\n' "$LLM_MODE"
  printf 'HONCHO_LLM_API_KEY=%q\n' "$LLM_API_KEY"
  printf 'HONCHO_LLM_BASE_URL=%q\n' "$LLM_BASE_URL"
  printf 'HONCHO_LLM_MODEL=%q\n' "$LLM_MODEL"
} >"$config_tmp"
chmod 0600 "$config_tmp"
pct push "$CTID" "$installer_tmp" /root/honcho-install.sh --perms 0755
pct push "$CTID" "$config_tmp" /root/honcho-installer.env --perms 0600
ok "Prepared installer and protected provider configuration"

INSTALL_LOG="/tmp/honcho-${CTID}-$(date +%Y%m%d-%H%M%S).log"
printf '\n  🚀 Installing Honcho natively in container %s:\n' "$CTID"
set +e
pct exec "$CTID" -- env HONCHO_PROJECT_REF="$PROJECT_REF" bash /root/honcho-install.sh 2>&1 | tee "$INSTALL_LOG"
rc=${PIPESTATUS[0]}
set -e
[[ "$rc" -eq 0 ]] || handle_install_failure "$rc"

ok "Completed successfully"
printf '\n  🌐 Honcho API: http://%s:8000\n' "$IP"
printf '  📚 API docs: http://%s:8000/docs\n' "$IP"
printf '  🩺 In-container health check: honcho-lxc-healthcheck\n'
printf '  🔒 Provider secrets are stored only in /etc/honcho/environment inside the LXC.\n'
printf '  ⚠️  Development status: real-Proxmox runtime matrix is not yet marked complete.\n'

if [[ -t 0 ]]; then
  whiptail --backtitle "$BACKTITLE" --title "INSTALLATION COMPLETE" --ok-button "Finish" \
    --msgbox "\nHoncho was installed natively in LXC ${CTID}.\n\nAPI: http://${IP}:8000\nDocs: http://${IP}:8000/docs\n\nRun honcho-lxc-healthcheck inside the container for the native service check.\n\nThis development build still requires the recorded real-Proxmox runtime validation before promotion to main." \
    19 78
fi
