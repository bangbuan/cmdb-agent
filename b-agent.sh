#!/usr/bin/env bash
# ==============================================================================
# CMDB Agent untuk Server Baremetal (b-agent.sh)
# ==============================================================================

set -Eeuo pipefail

# Direktori kerja agen
SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
CONFIG_FILE="$SCRIPT_DIR/config.cfg"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: File konfigurasi '$CONFIG_FILE' tidak ditemukan!" >&2
  echo "Silakan salin config.example menjadi config.cfg dan sesuaikan nilainya." >&2
  exit 1
fi

source "$CONFIG_FILE"

if [ -z "${CMDB_SERVER_URL:-}" ] || [ -z "${API_KEY:-}" ] || [ -z "${GIT_REPO_DIR:-}" ]; then
  echo "Error: Variabel CMDB_SERVER_URL, API_KEY, atau GIT_REPO_DIR wajib diisi di dalam config.cfg!" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 0. AUTO UPDATE SCRIPT DARI GITHUB (Hanya via parameter --update)
# ------------------------------------------------------------------------------
auto_update() {
  cd "$SCRIPT_DIR" || return

  if [ -d ".git" ]; then
    echo "Mengecek pembaruan dari repository..."
    git fetch origin >/dev/null 2>&1
    
    local HEADHASH UPSTREAMHASH
    HEADHASH=$(git rev-parse HEAD)
    UPSTREAMHASH=$(git rev-parse @{u} 2>/dev/null || echo "$HEADHASH")
    
    if [ "$HEADHASH" != "$UPSTREAMHASH" ]; then
      if git pull origin main >/dev/null 2>&1; then
        echo "Agent berhasil diperbarui ke versi terbaru."
      else
        echo "Gagal melakukan pembaruan (git pull error)."
      fi
    else
      echo "Agent sudah menggunakan versi terbaru."
    fi
  else
    echo "Direktori ini bukan repositori git, update dibatalkan."
  fi
}

# ------------------------------------------------------------------------------
# 1. GIT CONFIG & VM CONFIG BACKUP
# ------------------------------------------------------------------------------
sync_git_configs() {
  mkdir -p "$GIT_REPO_DIR"
  
  if [ ! -d "$GIT_REPO_DIR/.git" ]; then
    git -C "$GIT_REPO_DIR" init >/dev/null 2>&1
  fi

  # Backup konfigurasi libvirt XML VM ke direktori git configs
  if command -v virsh >/dev/null 2>&1; then
    local vm_backup_dir="$GIT_REPO_DIR/libvirt-vms"
    mkdir -p "$vm_backup_dir"
    
    # Dump XML semua VM aktif/non-aktif
    for vm in $(virsh list --all --name 2>/dev/null | grep -v '^$'); do
      virsh dumpxml "$vm" > "$vm_backup_dir/$vm.xml" 2>/dev/null || true
    done
  fi

  # Lakukan commit otomatis ke git lokal
  git -C "$GIT_REPO_DIR" add . >/dev/null 2>&1
  if ! git -C "$GIT_REPO_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
    git -C "$GIT_REPO_DIR" commit -m "Auto-backup baremetal configs: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" >/dev/null 2>&1
    
    # Push ke remote jika URL diset di config.cfg
    if [ -n "${GIT_REMOTE_URL:-}" ]; then
      git -C "$GIT_REPO_DIR" push origin main >/dev/null 2>&1 || true
    fi
  fi
}

# ------------------------------------------------------------------------------
# 2. PENGUMPULAN DATA SISTEM (OS, Updates, Hardware, Network)
# ------------------------------------------------------------------------------
get_os_info() {
  local os_name="Unknown" os_version="Unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_name="${NAME:-Unknown}"
    os_version="${VERSION_ID:-Unknown}"
  fi
  jq -n --arg name "$os_name" --arg ver "$os_version" '{name: $name, version: $ver}'
}

get_os_updates() {
  local updates_count=0
  if command -v apt-get >/dev/null 2>&1; then
    updates_count=$(apt-get -s upgrade 2>/dev/null | grep -i ^inst | wc -l || echo 0)
  fi
  jq -n --argjson count "$updates_count" '{pending_updates: $count}'
}

get_hardware_info() {
  local cpu_model cpu_cores
  cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//' || echo "Unknown")
  cpu_cores=$(nproc 2>/dev/null || echo 1)

  local ram_total ram_free ram_available
  ram_total=$(free -m | awk '/Mem:/ {print $2}' || echo 0)
  ram_free=$(free -m | awk '/Mem:/ {print $4}' || echo 0)
  ram_available=$(free -m | awk '/Mem:/ {print $7}' || echo 0)

  local storage_json
  # Mengecualikan loop devices (-e 7)
  storage_json=$(lsblk -e 7 -J -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || echo '{"blockdevices": []}')

  jq -n \
    --arg cpu_m "$cpu_model" \
    --arg cpu_c "$cpu_cores" \
    --arg ram_t "$ram_total" \
    --arg ram_f "$ram_free" \
    --arg ram_a "$ram_available" \
    --argjson storage "$storage_json" \
    '{
      cpu: {model: $cpu_m, cores: ($cpu_c|tonumber)},
      ram_mb: {total: ($ram_t|tonumber), free: ($ram_f|tonumber), available: ($ram_a|tonumber)},
      storage: $storage.blockdevices
    }'
}

get_network_info() {
  local net_json="[]"
  if command -v ip >/dev/null 2>&1; then
    net_json=$(ip -j addr show 2>/dev/null | jq '[.[] | select(.ifname != "lo") | {
      interface: .ifname,
      mac: (.addr_info[] | select(.family == "lladdr") | .local // empty),
      ipv4: [.addr_info[] | select(.family == "inet") | .local]
    }]' || echo "[]")
  fi
  echo "$net_json"
}

# ------------------------------------------------------------------------------
# 3. PENGUMPULAN DATA VIRTUAL MACHINE (KVM/QEMU via virsh)
# ------------------------------------------------------------------------------
get_vms_info() {
  local vms_array="[]"

  if ! command -v virsh >/dev/null 2>&1; then
    echo "[]"
    return
  fi

  local vm_names
  vm_names=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

  for vm in $vm_names; do
    local uuid state title desc
    uuid=$(virsh domuuid "$vm" 2>/dev/null || echo "")
    state=$(virsh domstate "$vm" 2>/dev/null | head -n 1 | tr -d '[:space:]' || echo "unknown")
    title=$(virsh desc "$vm" --title 2>/dev/null || echo "")
    desc=$(virsh desc "$vm" 2>/dev/null || echo "")

    local vcpus memory_kb
    vcpus=$(virsh vcpucount "$vm" --current 2>/dev/null || echo 0)
    memory_kb=$(virsh dominfo "$vm" 2>/dev/null | awk '/Max memory/ {print $3}' || echo 0)
    local memory_mb=$((memory_kb / 1024))

    local guest_os="unknown"
    if [ "$state" = "running" ]; then
      guest_os=$(virsh qemu-agent-command "$vm" '{"execute":"guest-info"}' 2>/dev/null | jq -r '.return.version // "unknown"' || echo "unknown")
    fi

    local vm_storage="[]"
    vm_storage=$(virsh domblklist "$vm" --details 2>/dev/null | awk 'NR>2 {print $1, $2, $3, $4}' | while read -r type dev source target; do
      [ -z "$target" ] && continue
      printf '{"type": "%s", "device": "%s", "source": "%s", "target": "%s"},' "$type" "$dev" "$source" "$target"
    done)
    vm_storage="[${vm_storage%,}]"

    local vm_net="[]"
    local xml_content
    xml_content=$(virsh dumpxml "$vm" 2>/dev/null || echo "")
    
    if [ -n "$xml_content" ]; then
      vm_net=$(python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    xml_str = sys.stdin.read()
    root = ET.fromstring(xml_str)
    nets = []
    for interface in root.findall(".//devices/interface"):
        net_type = interface.get("type", "unknown")
        source = interface.find("source")
        source_val = source.get("bridge") or source.get("dev") or source.get("network") if source is not None else "unknown"
        mac = interface.find("mac")
        mac_val = mac.get("address") if mac is not None else "unknown"
        target = interface.find("target")
        target_val = target.get("dev") if target is not None else "unknown"
        nets.append({"type": net_type, "source": source_val, "mac": mac_val, "target": target_val})
    import json
    print(json.dumps(nets))
except Exception:
    print("[]")
' <<< "$xml_content" 2>/dev/null || echo "[]")
    fi

    local vm_json
    vm_json=$(jq -n \
      --arg name "$vm" \
      --arg uuid "$uuid" \
      --arg title "$title" \
      --arg desc "$desc" \
      --arg state "$state" \
      --argjson vcpus "$vcpus" \
      --argjson ram_mb "$memory_mb" \
      --arg guest_os "$guest_os" \
      --argjson storage "$vm_storage" \
      --argjson network "$vm_net" \
      '{
        name: $name,
        uuid: $uuid,
        title: $title,
        description: $desc,
        status: $state,
        specs: {
          vcpus: $vcpus,
          ram_mb: $ram_mb
        },
        guest_os: $guest_os,
        storage: $storage,
        network: $network
      }')

    vms_array=$(echo "$vms_array" | jq --argjson item "$vm_json" '. + [$item]')
  done

  echo "$vms_array"
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "--update" ]; then
    auto_update
    exit 0
  fi

  # 1. Sinkronisasi konfigurasi ke Git
  sync_git_configs

  # 2. Kumpulkan metrics
  local data_os data_updates data_hw data_net data_vms
  data_os=$(get_os_info)
  data_updates=$(get_os_updates)
  data_hw=$(get_hardware_info)
  data_net=$(get_network_info)
  data_vms=$(get_vms_info)

  # 3. Rakit Payload JSON Tunggal
  local final_payload
  final_payload=$(jq -n \
    --arg host "$(hostname)" \
    --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson os "$data_os" \
    --argjson updates "$data_updates" \
    --argjson hw "$data_hw" \
    --argjson net "$data_net" \
    --argjson vms "$data_vms" \
    '{
      hostname: $host,
      reported_at: $timestamp,
      node_type: "baremetal",
      os: $os,
      updates: $updates,
      hardware: $hw,
      network: $net,
      virtualization: {
        total_vms: ($vms | length),
        vms: $vms
      }
    }')

  # 4. Kirimkan Payload ke Server CMDB via HTTP POST
  curl -s -X POST "$CMDB_SERVER_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -d "$final_payload"
}

main "$@"