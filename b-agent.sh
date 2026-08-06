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
# 1. UPLOAD CONFIGS
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
  local os_desc
  os_desc=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')
  jq -n --arg name "$os_desc" '{name: $name}'
}

get_os_updates() {
  local pending_updates=0
  local security_updates=0

  if [ -f /usr/lib/update-notifier/apt-check ]; then
    local apt_check_out
    apt_check_out=$(/usr/lib/update-notifier/apt-check 2>&1 || true)
    pending_updates=$(echo "$apt_check_out" | cut -d';' -f1)
    security_updates=$(echo "$apt_check_out" | cut -d';' -f2)
  fi

  jq -n \
    --arg pending "$pending_updates" \
    --arg security "$security_updates" \
    '{pending_updates: ($pending|tonumber), security_updates: ($security|tonumber)}'
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
    net_json=$(ip -j addr show 2>/dev/null | jq '[
      .[]
      | select(.ifname | test("^(lo|vnet)") | not)
      | {
          interface: .ifname,
          mac: (.address // ([.addr_info[]? | select(.family == "lladdr") | .local] | first) // "unknown"),
          ipv4: [.addr_info[]? | select(.family == "inet") | .local]
        }
    ]' || echo "[]")
  fi
  echo "$net_json"
}



# ------------------------------------------------------------------------------
# 3. PENGUMPULAN DATA VIRTUAL MACHINE (KVM/QEMU via virsh)
# ------------------------------------------------------------------------------
get_vms_info() {
  if ! command -v virsh >/dev/null 2>&1; then
    echo "[]"
    return
  fi

  local vm_list_raw
  vm_list_raw=$(virsh list --all 2>/dev/null | tail -n +3 || true)

  if [ -z "$vm_list_raw" ]; then
    echo "[]"
    return
  fi

  # Dapatkan direktori tempat b-agent.sh berada
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local parser_vm="$script_dir/parse_vm.py"
  local parser_storage="$script_dir/parse_storage.py"

  if [ ! -f "$parser_vm" ] || [ ! -f "$parser_storage" ]; then
    echo "[]"
    return
  fi

  local vms_array="[]"

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local vm state
    vm=$(echo "$line" | awk '{print $2}')
    state=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)

    [ -z "$vm" ] && continue
    [ -z "$state" ] && state="unknown"

    local xml_content
    xml_content=$(virsh dumpxml "$vm" 2>/dev/null || echo "")

    # 1. Parsing XML menggunakan parse_vm.py
    local vm_json="{}"
    if [ -n "$xml_content" ]; then
      vm_json=$(python3 "$parser_vm" <<< "$xml_content" 2>/dev/null || echo "{}")
    fi

    # 2. Pengayaan storage menggunakan parse_storage.py
    local storage_with_info="[]"
    storage_with_info=$(python3 "$parser_storage" "$vm_json" "$vm" "$state" 2>/dev/null || echo "[]")

    # 3. Gabungkan atribut akhir VM menggunakan jq
    local final_vm_json
    final_vm_json=$(jq -n \
      --arg name "$vm" \
      --arg state "$state" \
      --argjson base "$vm_json" \
      --argjson storage "$storage_with_info" \
      '{
        name: $name,
        uuid: ($base.uuid // ""),
        title: ($base.title // ""),
        description: ($base.description // ""),
        status: $state,
        specs: {
          vcpus: ($base.vcpus // 0),
          ram_mb: ($base.ram_mb // 0)
        },
        guest_os: "unknown",
        storage: $storage,
        network: ($base.network // [])
      }')

    vms_array=$(echo "$vms_array" | jq --argjson item "$final_vm_json" '. + [$item]')

  done <<< "$vm_list_raw"

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
