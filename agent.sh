#!/usr/bin/env bash

# ==============================================================================
# CMDB Client Agent for Ubuntu Server
# ==============================================================================

set -euo pipefail

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
    "/etc/nginx"
    "/etc/apache2"
    "/etc/php"
    "/etc/mysql"
    "/etc/postgresql"
    "/etc/firebird"
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
# -----------------------------------------------------------------------------
get_system_uuid() {
    local uuid_path="/sys/class/dmi/id/product_uuid"
    if [ -f "$uuid_path" ]; then
        cat "$uuid_path" 2>/dev/null | tr -d '[:space:]' || echo "unknown"
    else
        echo "unknown"
    fi
}

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

# ------------------------------------------------------------------------------
# 3. NETWORK INTERFACES & IP ADDRESSES (IPv4 ONLY, EXCLUDING 127.0.0.0/8)
# ------------------------------------------------------------------------------
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
# 4. WEBSERVER, PHP, DATABASE & FIREWALL
# ------------------------------------------------------------------------------
get_webservers() {
  local nginx_ver="not_installed"
  local apache_ver="not_installed"

  if command -v nginx >/dev/null 2>&1; then
    nginx_ver=$(nginx -v 2>&1 | cut -d'/' -f2)
  fi

  if command -v apache2 >/dev/null 2>&1; then
    apache_ver=$(apache2 -v 2>&1 | awk -F'/' '{print $2}' | cut -d' ' -f1)
  fi

  jq -n --arg ng "$nginx_ver" --arg ap "$apache_ver" '{nginx: $ng, apache: $ap}'
}

get_php_info() {
  local result_json="[]"
  local php_versions
  
  # 1. Cari semua versi dasar PHP yang terinstal (misal: 7.2, 7.4, 8.2)
  # Mencari paket dengan nama phpX.Y-cli, phpX.Y-fpm, atau libapache2-mod-phpX.Y
  php_versions=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-(cli|fpm)$|^libapache2-mod-php[0-9]+\.[0-9]+$' | grep -oP '[0-9]+\.[0-9]+' | sort -u)
  
  for v in $php_versions; do
    local has_cli="false"
    local has_fpm="false"
    local has_apache="false"
    
    # 2. Cek ketersediaan masing-masing komponen SAPI untuk versi ini
    if dpkg-query -W -f='${Status}\n' "php${v}-cli" 2>/dev/null | grep -q "install ok installed"; then
      has_cli="true"
    fi
    if dpkg-query -W -f='${Status}\n' "php${v}-fpm" 2>/dev/null | grep -q "install ok installed"; then
      has_fpm="true"
    fi
    if dpkg-query -W -f='${Status}\n' "libapache2-mod-php${v}" 2>/dev/null | grep -q "install ok installed"; then
      has_apache="true"
    fi
    
    local exact_ver="unknown"
    local mods="[]"
    
    # 3. Jika CLI tersedia, panggil binary-nya untuk mendapatkan exact version dan modul yang diload
    if [ "$has_cli" = "true" ] && command -v "php${v}" >/dev/null 2>&1; then
      exact_ver=$("php${v}" -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
      # Ambil daftar modul aktif
      mods=$("php${v}" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
    else
      # Fallback: Jika CLI tidak terinstal tapi FPM/Apache ada, ambil versi dari info paket dpkg
      if [ "$has_fpm" = "true" ]; then
         exact_ver=$(dpkg-query -W -f='${Version}\n' "php${v}-fpm" 2>/dev/null | cut -d'-' -f1 | sed 's/^[0-9]://' || echo "unknown")
      elif [ "$has_apache" = "true" ]; then
         exact_ver=$(dpkg-query -W -f='${Version}\n' "libapache2-mod-php${v}" 2>/dev/null | cut -d'-' -f1 | sed 's/^[0-9]://' || echo "unknown")
      fi
    fi
    
    # 4. Susun JSON per versi PHP
    local item_json
    item_json=$(jq -n \
      --arg base_ver "$v" \
      --arg exact "$exact_ver" \
      --argjson cli "$has_cli" \
      --argjson fpm "$has_fpm" \
      --argjson apache "$has_apache" \
      --argjson m "$mods" \
      '{
        base_version: $base_ver,
        exact_version: $exact,
        components: {
          cli: $cli,
          fpm: $fpm,
          apache2_mod: $apache
        },
        active_modules: $m
      }')
      
    # Gabungkan ke array utama
    result_json=$(echo "$result_json" | jq --argjson item "$item_json" '. + [$item]')
  done

  # Kembalikan JSON dengan format yang rapi
  jq -n --argjson versions "$result_json" '{installed_versions: $versions}'
}

get_databases() {
  local mysql_engine="not_installed"
  local mysql_ver="not_installed"
  
  # 1. Cek MySQL / MariaDB Server
  # Cek via dpkg (lebih akurat untuk server Ubuntu)
  if dpkg-query -W -f='${Status}\n' mariadb-server 2>/dev/null | grep -q "install ok installed"; then
    mysql_engine="MariaDB"
    mysql_ver=$(dpkg-query -W -f='${Version}\n' mariadb-server | cut -d'-' -f1 | sed 's/^[0-9]://' | head -n 1)
  elif dpkg-query -W -f='${Status}\n' mysql-server 2>/dev/null | grep -q "install ok installed"; then
    mysql_engine="MySQL"
    mysql_ver=$(dpkg-query -W -f='${Version}\n' mysql-server | cut -d'-' -f1 | sed 's/^[0-9]://' | head -n 1)
  elif [ -x /usr/sbin/mysqld ]; then
    # Fallback: jika diinstal manual (bukan via meta-package), cek binary langsung
    if /usr/sbin/mysqld -V 2>/dev/null | grep -qi "mariadb"; then
      mysql_engine="MariaDB"
    else
      mysql_engine="MySQL"
    fi
    mysql_ver=$(/usr/sbin/mysqld -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  fi

  # 2. Cek PostgreSQL Server
  local pgsql_ver="not_installed"
  local pg_pkg
  # Cari paket postgresql-[angka] yang benar-benar terinstal (misal: postgresql-14)
  pg_pkg=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | grep -E '^postgresql-[0-9]+ .*install ok installed' | awk '{print $1}' | sort -V | tail -n 1)
  
  if [ -n "$pg_pkg" ]; then
    pgsql_ver=$(dpkg-query -W -f='${Version}\n' "$pg_pkg" | cut -d'-' -f1 | sed 's/^[0-9]://')
  else
    # Fallback: cari binary postgres server langsung
    local pg_bin
    pg_bin=$(find /usr/lib/postgresql -maxdepth 3 -name postgres -type f -executable 2>/dev/null | sort -V | tail -n 1 || true)
    if [ -n "$pg_bin" ] && [ -x "$pg_bin" ]; then
       pgsql_ver=$("$pg_bin" -V 2>/dev/null | awk '{print $3}')
    fi
  fi

  # 3. Cek Firebird Server
  local firebird_ver="not_installed"
  local fb_pkg
  # Cari paket firebird-[versi]-server (misal: firebird3.0-server)
  fb_pkg=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | grep -E '^firebird[0-9\.]+-server .*install ok installed' | awk '{print $1}' | sort -V | tail -n 1)
  
  if [ -n "$fb_pkg" ]; then
    firebird_ver=$(dpkg-query -W -f='${Version}\n' "$fb_pkg" | cut -d'-' -f1 | sed 's/^[0-9]://')
  elif command -v firebird >/dev/null 2>&1; then
    # Fallback ke binary execution
    firebird_ver=$(firebird -z 2>&1 | grep -m1 -oE 'V[0-9]+\.[0-9]+\.[0-9]+' | sed 's/V//' || echo "installed")
  fi

  # Generate format JSON akhir
  jq -n \
    --arg my_eng "$mysql_engine" \
    --arg my_ver "$mysql_ver" \
    --arg pg_ver "$pgsql_ver" \
    --arg fb_ver "$firebird_ver" \
    '{
      mysql_mariadb: { engine: $my_eng, version: $my_ver },
      postgresql: { version: $pg_ver },
      firebird: { version: $fb_ver }
    }'
}

get_ufw_rules() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw status numbered | tr -d '\r' | jq -R -s 'split("\n") | map(select(length > 0))'
  else
    jq -n '["UFW inactive or not installed"]'
  fi
}

# ------------------------------------------------------------------------------
# 5. USERS & GROUPS NON-SYSTEM (UID/GID >= 1000)
# ------------------------------------------------------------------------------
get_non_system_users() {
  local users_data="[]"

  while IFS=: read -r username _ uid gid _ homedir _; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ]; then
      local group_name
      group_name=$(getent group "$gid" | cut -d: -f1 || echo "unknown")

      # 1. Hitung disk usage home directory (dengan batas waktu)
      local home_disk_usage="0"
      if [ -d "$homedir" ]; then
        home_disk_usage=$(timeout 60s du -sb "$homedir" 2>/dev/null | awk '{print $1}' || echo "0")
      fi

      # 2. Cek direktori /public_html/$username
      local public_html_path="/public_html/$username"
      local public_html_exists="false"
      local public_html_owner_match="false"
      local public_html_disk_usage="0"

      if [ -d "$public_html_path" ]; then
        public_html_exists="true"
        
        local current_owner
        current_owner=$(stat -c '%U' "$public_html_path" 2>/dev/null || echo "")
        
        if [ "$current_owner" = "$username" ]; then
          public_html_owner_match="true"
          public_html_disk_usage=$(timeout 60s du -sb "$public_html_path" 2>/dev/null | awk '{print $1}' || echo "0")
        fi
      fi

      # 3. Ambil daftar Cronjob user tersebut (crontab -l)
      # Menggunakan su/sudo atau crontab -u jika dijalankan sebagai root
      local user_cron=""
      if command -v crontab >/dev/null 2>&1; then
        user_cron=$(crontab -l -u "$username" 2>/dev/null || echo "")
      fi

      # 4. Bangun objek JSON user menggunakan jq --arg agar aman dari karakter khusus
      local user_json
      user_json=$(jq -n \
        --arg uname "$username" \
        --argjson uid "$uid" \
        --arg group "$group_name" \
        --arg home "$homedir" \
        --argjson home_disk "${home_disk_usage:-0}" \
        --arg ph_path "$public_html_path" \
        --argjson ph_exists "$public_html_exists" \
        --argjson ph_owner "$public_html_owner_match" \
        --argjson ph_disk "${public_html_disk_usage:-0}" \
        --arg cron "$user_cron" \
        '{
          username: $uname,
          uid: $uid,
          group: $group,
          home: $home,
          disk_usage_bytes: $home_disk,
          public_html: {
            path: $ph_path,
            exists: $ph_exists,
            owner_matched: $ph_owner,
            disk_usage_bytes: $ph_disk
          },
          crontab: $cron
        }')

      # Gabungkan ke dalam array utama menggunakan jq
      users_data=$(echo "$users_data" | jq --argjson item "$user_json" '. + [$item]')
    fi
  done < /etc/passwd

  echo "$users_data" | jq '.'
}

get_non_system_groups() {
  local groups_json="[]"

  while IFS=: read -r group_name _ gid members; do
    if [ "$gid" -ge 1000 ] && [ "$gid" -ne 65534 ]; then
      local members_arr
      members_arr=$(echo "$members" | tr ',' '\n' | jq -R -s 'split("\n") | map(select(length > 0))')

      local group_obj
      group_obj=$(jq -n \
        --arg g "$group_name" \
        --arg gid "$gid" \
        --argjson m "$members_arr" \
        '{group_name: $g, gid: ($gid|tonumber), members: $m}')

      groups_json=$(echo "$groups_json" | jq --argjson item "$group_obj" '. + [$item]')
    fi
  done < /etc/group

  echo "$groups_json"
}

# ------------------------------------------------------------------------------
# 6. BACA MORE.JSON (CUSTOM PAYLOAD)
# ------------------------------------------------------------------------------
get_more_data() {
  local more_file="$SCRIPT_DIR/more.json"
  
  if [ -f "$more_file" ] && jq -e . "$more_file" >/dev/null 2>&1; then
    cat "$more_file"
  else
    echo "{}"
  fi
}

# # ------------------------------------------------------------------------------
# # 7. BACKUP KONFIGURASI KE GIT REPO (VERSI AMAN TANPA --delete)
# # ------------------------------------------------------------------------------
# sync_git_configs() {
#   if [ ! -d "$GIT_REPO_DIR/.git" ]; then
#     mkdir -p "$GIT_REPO_DIR"
#     git init "$GIT_REPO_DIR"
#     if [ -n "$GIT_REMOTE_URL" ]; then
#       git -C "$GIT_REPO_DIR" remote add origin "$GIT_REMOTE_URL" || true
#     fi
#   fi

#   local paths=(
#     "/etc/nginx"
#     "/etc/apache2"
#     "/etc/php"
#     "/etc/mysql"
#     "/etc/postgresql"
#     "/etc/firebird"
#   )

#   for p in "${paths[@]}"; do
#     if [ -d "$p" ]; then
#       local target_dir="$GIT_REPO_DIR/$(basename "$p")"
#       mkdir -p "$target_dir"
#       # Menggunakan rsync aman tanpa parameter --delete
#       rsync -a "$p/" "$target_dir/" 2>/dev/null || true
#     fi
#   done

#   cd "$GIT_REPO_DIR"
#   git config user.name "CMDB Agent"
#   git config user.email "cmdb-agent@$HOSTNAME"
#   git add .

#   if ! git diff-index --quiet HEAD -- 2>/dev/null; then
#     git commit -m "Auto-backup config from $HOSTNAME on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
#     if [ -n "$GIT_REMOTE_URL" ]; then
#       git push origin main 2>/dev/null || true
#     fi
#   fi
# }






# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------
main() {
  # Cek apakah argumen pertama adalah --update
  if [ "${1:-}" = "--update" ]; then
    auto_update
    exit 0
  fi

  upload_configs


  local vuuid
  vuuid=$(cat /sys/class/dmi/id/product_uuid)

  # Kumpulkan semua metrics
  local system_uuid data_os data_updates data_hw data_net data_web data_php data_db data_ufw data_users data_groups data_more
  system_uuid=$(get_system_uuid)
  data_os=$(get_os_info)
  data_updates=$(get_os_updates)
  data_hw=$(get_hardware_info)
  data_net=$(get_network_info)
  data_web=$(get_webservers)
  data_php=$(get_php_info)
  data_db=$(get_databases)
  data_ufw=$(get_ufw_rules)
  data_users=$(get_non_system_users)
  data_groups=$(get_non_system_groups)
  data_more=$(get_more_data)

  # 3. Gabungkan seluruh data menjadi SATU JSON tunggal
  local final_payload
  final_payload=$(jq -n \
    --arg uuid "$system_uuid" \
    --arg host "$HOSTNAME" \
    --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson os "$data_os" \
    --argjson updates "$data_updates" \
    --argjson hw "$data_hw" \
    --argjson net "$data_net" \
    --argjson web "$data_web" \
    --argjson php "$data_php" \
    --argjson db "$data_db" \
    --argjson ufw "$data_ufw" \
    --argjson users "$data_users" \
    --argjson groups "$data_groups" \
    --argjson more "$data_more" \
    '{
      uuid: $uuid,
      hostname: $host,
      reported_at: $timestamp,
      os: $os,
      updates: $updates,
      hardware: $hw,
      network: $net,
      services: {
        webservers: $web,
        php: $php,
        databases: $db
      },
      security: {
        ufw_rules: $ufw
      },
      user_management: {
        users: $users,
        groups: $groups
      },
      more: $more
    }')

  # echo $final_payload
  # exit 1
  # 4. Kirimkan JSON ke Server CMDB via HTTP POST
  curl -s -X POST "$CMDB_TELEMETRY_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -d "$final_payload"
}

main "$@"
