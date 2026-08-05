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
upload_configs() {
  local temp_dir="/tmp/cmdb_vm_staging"
  local tar_file="/tmp/vm_configs.tar.gz"
  rm -rf "$temp_dir" "$tar_file"

  mkdir -p "$temp_dir/vm"

  if command -v virsh >/dev/null 2>&1; then
    for vm in $(virsh list --all --name 2>/dev/null | grep -v '^$'); do
      virsh dumpxml "$vm" > "$temp_dir/vm/$vm.xml" 2>/dev/null || true
    done
  fi

  local paths=(
    "/etc/netplan"
  )

  for p in "${paths[@]}"; do
    if [ -d "$p" ]; then
      local target_dir="$temp_dir$p"
      mkdir -p "$target_dir"
      rsync -a "$p/" "$target_dir/" 2>/dev/null || true
    fi
  done

  echo "[+] Mengompres arsip XML VM..."
  tar -czf "$tar_file" -C "$temp_dir" .
  rm -rf "$temp_dir"

    echo "[+] Mengirimkan arsip konfigurasi VM ke server CMDB..."
  local http_response
  http_response=$(curl -s -w "\n%{http_code}" -X POST "$CMDB_UPLOAD_URL" \
    -H "X-API-Key: $API_KEY" \
    -F "config_archive=@${tar_file}")

  local http_body=$(echo "$http_response" | sed '$d')
  local http_status=$(echo "$http_response" | tail -n1)

  rm -f "$tar_file"

  if [ "$http_status" -eq 200 ]; then
    echo "[SUCCESS] Berkas konfigurasi VM berhasil terkirim."
  else
    echo "[ERROR] Gagal mengirim konfigurasi VM (HTTP $http_status): $http_body"
    return 1
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

  local data_os data_updates data_hw data_net data_vms
  data_os=$(get_os_info)
  data_updates=$(get_os_updates)
  data_hw=$(get_hardware_info)
  data_net=$(get_network_info)
  data_vms=$(get_vms_info)

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
  curl -s -X POST "$CMDB_TELEMETRY_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -d "$final_payload"

  # 5. upload configs
  upload_configs  
}

main "$@"
