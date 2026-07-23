#!/bin/sh
# Entrypoint container PHP. Berlaku untuk peran php-fpm, queue worker,
# scheduler, dan job migrasi -- perannya ditentukan oleh CMD.
#
# Prinsip yang dipegang:
#   1. IDEMPOTEN. Boleh dijalankan berapa kali pun, di berapa Pod pun.
#   2. TIDAK MENULIS APA PUN DI LUAR direktori yang memang writable.
#   3. GAGAL CEPAT. Salah konfigurasi harus terlihat di log, bukan menjadi
#      500 misterius beberapa menit kemudian.
set -eu

log() { echo "[entrypoint] $*" >&2; }

# --------------------------------------------------------------------------
# 1. Validasi variabel wajib
# --------------------------------------------------------------------------
# APP_KEY yang kosong membuat seluruh enkripsi, cookie, dan sesi Laravel
# gagal dengan pesan yang membingungkan. Lebih baik container menolak start.
: "${APP_KEY:?APP_KEY belum diset - buat dengan 'php artisan key:generate --show'}"
: "${DB_HOST:?DB_HOST belum diset}"

# --------------------------------------------------------------------------
# 2. Siapkan direktori yang harus writable
# --------------------------------------------------------------------------
# Di Kubernetes, path berikut ditimpa emptyDir/PVC yang awalnya KOSONG.
# Struktur direktorinya harus dibuat ulang setiap Pod start, kalau tidak
# Laravel gagal dengan "Please provide a valid cache path".
mkdir -p \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/app/public \
    bootstrap/cache

# --------------------------------------------------------------------------
# 3. Tunggu dependensi siap
# --------------------------------------------------------------------------
# initContainer di manifest sudah menangani ini, tetapi pengecekan di sini
# membuat image tetap benar saat dijalankan lewat Docker Compose.
tunggu() {
    host="$1"; port="$2"; nama="$3"; batas="${4:-60}"
    i=0
    while ! nc -z "$host" "$port" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge "$batas" ] && { log "GAGAL: $nama ($host:$port) tidak siap"; exit 1; }
        [ $((i % 5)) -eq 1 ] && log "menunggu $nama di $host:$port ..."
        sleep 1
    done
    log "$nama siap"
}

if command -v nc >/dev/null 2>&1; then
    tunggu "$DB_HOST" "${DB_PORT:-3306}" "database"
    [ -n "${REDIS_HOST:-}" ] && tunggu "$REDIS_HOST" "${REDIS_PORT:-6379}" "redis"
fi

# --------------------------------------------------------------------------
# 4. Bangun cache konfigurasi
# --------------------------------------------------------------------------
# DIJALANKAN SAAT RUNTIME, BUKAN SAAT BUILD.
#
# config:cache membekukan hasil env() ke dalam satu berkas PHP. Bila
# dijalankan waktu build, nilai yang membeku adalah nilai saat build --
# password dan host dari mesin CI, bukan dari klaster. Itu sebabnya langkah
# ini ada di sini, setelah ConfigMap dan Secret ter-inject.
#
# Efek sampingnya juga penting: setelah config:cache, fungsi env() di luar
# berkas config/ mengembalikan null. Kode aplikasi harus memakai config().
if [ "${SKIP_OPTIMIZE:-false}" != "true" ]; then
    log "membangun cache konfigurasi, route, view, dan event"
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
fi

# --------------------------------------------------------------------------
# 5. Migrasi (opsional, default MATI)
# --------------------------------------------------------------------------
# Default-nya migrasi TIDAK dijalankan di sini, melainkan oleh Job terpisah
# (kubernetes/base/job-migrate.yaml). Alasannya: dengan 3 replika php-fpm,
# tiga Pod akan menjalankan migrasi bersamaan saat rollout.
#
# Bila tetap ingin dijalankan dari Pod aplikasi, --isolated memakai lock di
# cache store untuk memastikan hanya satu Pod yang mengerjakannya.
# Ini AMAN di sini karena CACHE_STORE=redis. Bila cache store-nya 'database',
# --isolated justru mengunci diri sendiri: tabel cache-nya baru dibuat oleh
# migrasi yang sedang menunggu lock.
if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    log "menjalankan migrasi (isolated)"
    php artisan migrate --force --isolated
fi

log "siap; menjalankan: $*"
exec "$@"
