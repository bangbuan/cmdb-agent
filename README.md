# CMDB Agent untuk Ubuntu Server

Script Bash ringan dan mandiri (*self-hosted*) untuk mengumpulkan data inventaris (inventory), metrik server, dan konfigurasi dari server Ubuntu. Data yang dikumpulkan akan dikonversi menjadi format JSON yang aman dan dikirimkan ke server CMDB terpusat melalui Webhook/API.

Selain mengumpulkan data telemetri, agen ini juga memiliki fitur pencadangan (backup) konfigurasi server ke dalam repositori Git secara otomatis dan aman (menyimpan riwayat perubahan tanpa menghapus konfigurasi yang ada).

## ✨ Fitur Utama

1. **Pengumpulan Data Sistem & Hardware:** OS, Versi, Status Update APT, CPU, RAM, dan Storage (`lsblk`).
2. **Informasi Jaringan:** Daftar antarmuka (interface), MAC Address, dan daftar alamat IPv4 (mengabaikan network loopback `127.0.0.0/8`).
3. **Deteksi Layanan:** Membaca versi Webserver (Nginx, Apache), PHP beserta modul aktif, dan Database (MySQL, PostgreSQL, Firebird).
4. **Keamanan:** Membaca *rules* firewall UFW (`ufw status numbered`).
5. **Manajemen Pengguna:** Mencatat user dan group *non-system* (UID/GID >= 1000) beserta direktori *home* dan penggunaan *disk*-nya.
6. **Git Config Backup:** Menyalin konfigurasi vital (seperti `/etc/nginx`, `/etc/php`, dsb) ke dalam repositori Git secara berkala untuk pelacakan versi (*versioning*). Menggunakan `rsync` yang aman agar tidak menghapus riwayat (*history*) modifikasi.
7. **Custom Payload (`more.json`):** Memungkinkan admin server menambahkan data statis kustom ke dalam payload JSON.
8. **Auto-Update:** Memeriksa pembaruan skrip secara otomatis dari repositori GitHub dan me-restart dirinya sendiri dengan versi terbaru sebelum dieksekusi.

## 📦 Prasyarat

Pastikan paket-paket berikut sudah terinstal di server Ubuntu Anda:
- `bash`
- `jq` (Untuk pemrosesan JSON secara aman)
- `git` (Untuk fitur backup config dan auto-update)
- `curl` (Untuk pengiriman data HTTP POST)
- `rsync` (Untuk sinkronisasi direktori konfigurasi)

Anda dapat menginstalnya dengan perintah:

```bash
sudo apt update && sudo apt install -y jq git curl rsync
```

## 🚀 Instalasi & Penggunaan

Sangat disarankan meletakkan repositori ini di direktori seperti `/opt/` agar mudah dikelola dan dieksekusi oleh Cron.

1. **Clone Repositori:**
   ```bash
   cd /opt
   sudo git clone [https://github.com/bangbuan/cmdb-agent.git](https://github.com/bangbuan/cmdb-agent.git)
   cd cmdb-agent
   ```

2. **Siapkan Konfigurasi:**
   Salin berkas *template* konfigurasi menjadi konfigurasi aktif. Berkas konfigurasi otomatis diabaikan oleh Git berkat `.gitignore`.
   ```bash
   sudo cp config.example config.cfg
   ```

3. **Ubah Izin Eksekusi:**
   ```bash
   sudo chmod +x cmdb-agent.sh
   ```

4. **Sesuaikan Konfigurasi:**
   Edit berkas `config.cfg` menggunakan editor teks (seperti `nano` atau `vim`) dan sesuaikan nilainya:
   - `CMDB_PREFIX_URL`
   - `CMDB_TELEMETRY_URL`
   - `CMDB_UPLOAD_URL`
   - `API_KEY`
   - `GIT_REPO_DIR` (Lokasi repositori lokal untuk backup konfigurasi)
   - `GIT_REMOTE_URL` (Opsional, remote repository untuk push backup config)

5. **Uji Coba Script:**
   Jalankan script secara manual untuk memastikan semuanya bekerja.
   ```bash
   sudo ./cmdb-agent.sh
   ```

## 🔄 Pembaruan Agen (--update)
Untuk memperbarui script agen ke versi terbaru dari GitHub tanpa menjalankan pengiriman telemetri, jalankan perintah berikut:

```bash
/root/.cmdb-agent/agent.sh --update
```

## ⚙️ Penambahan Data Kustom (`more.json`)

Jika Anda ingin menambahkan data tambahan yang bersifat statis ke server CMDB (misalnya nama *Person In Charge*, Environment, atau Lokasi Rack), buatlah berkas `more.json` di dalam folder yang sama dengan skrip ini.

**Contoh isi `more.json`:**

```json
{
  "environment": "Production",
  "pic": "Bapak Budi",
  "rack_location": "Server Room A, Rack 02"
}
```

*Catatan: Jika berkas JSON tidak valid, agen akan otomatis mengabaikannya dan mengirimkan payload dengan properti `"more": {}`.*

## 🔄 Otomatisasi (Cron Job)

Agar data dikirimkan secara berkala, tambahkan agen ini ke dalam Cron. Disarankan dijalankan sebagai `root` agar agen memiliki izin penuh untuk membaca seluruh konfigurasi, metrik storage, dan membaca profil pengguna sistem.

1. Buka konfigurasi crontab root:
   ```bash
   sudo crontab -e
   ```
2. Tambahkan jadwal pengeksekusian (contoh: setiap hari jam 02:00 pagi):
   ```cron
   0 21 * * * /root/.cmdb-agent/agent.sh --update >/dev/null 2>&1
   10 21 * * * /root/.cmdb-agent/agent.sh >/dev/null 2>&1
   ```

## 📂 Struktur Repositori

```text
cmdb-agent/
├── .gitignore        # Mengabaikan config.cfg dan more.json dari git commit
├── cmdb-agent.sh     # Script bash utama (Agent)
├── config.example    # Contoh file konfigurasi (template)
├── README.md         # Dokumentasi (file ini)
```

## 🛡️ Keamanan & Privasi
Skrip ini beroperasi secara *read-only* (kecuali untuk pembuatan repositori *backup* internal). Informasi yang dikirimkan bergantung murni pada parameter apa saja yang dikonfigurasikan di klien. Pastikan token `API_KEY` disimpan dengan aman dan server target menggunakan HTTPS (`https://`).
