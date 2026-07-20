#!/bin/sh
# -----------------------------------------------------------------------------
# Entrypoint container aplikasi (php-fpm, queue worker, scheduler, artisan).
#
# Tugasnya:
#   1. Pastikan direktori writable ada (volume bisa menimpa isi image).
#   2. Tunggu MySQL siap.
#   3. Jalankan migrasi — hanya bila RUN_MIGRATIONS=true (satu service saja!).
#   4. Bangun cache config/route/view/event di produksi.
#
# Semua langkah idempoten supaya container aman di-restart.
# -----------------------------------------------------------------------------
set -eu

APP_ENV="${APP_ENV:-production}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-false}"
WAIT_FOR_DB="${WAIT_FOR_DB:-true}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"

log() { echo "[entrypoint] $*"; }

cd /var/www/html

# --- 1. Direktori writable ---------------------------------------------------
# Named volume yang di-mount ke storage/ datang dalam keadaan kosong pada
# pembuatan pertama, jadi struktur framework harus dibuat ulang tiap boot.
mkdir -p \
    storage/app/public \
    storage/app/private \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

# chown hanya mungkin (dan hanya perlu) saat berjalan sebagai root — kasus
# Docker Compose. Di Kubernetes seluruh proses sudah non-root sejak awal dan
# kepemilikan volume diurus oleh fsGroup.
if [ "$(id -u)" = "0" ]; then
    chown -R www-data:www-data storage bootstrap/cache
fi

# chmod tetap dijalankan di kedua kasus: file-nya milik kita sendiri.
# Web server berjalan sebagai user BERBEDA dan melayani /storage/* langsung dari
# volume, jadi ia butuh hak telusur sampai app/public lalu hak baca di dalamnya.
# Volume yang baru dibuat tidak membawa permission dari image, jadi ini harus
# diterapkan ulang setiap boot.
chmod -R u=rwX,g=rX,o= storage bootstrap/cache 2>/dev/null || true
chmod o+x storage storage/app 2>/dev/null || true
chmod -R o+rX storage/app/public 2>/dev/null || true

# --- Guard: APP_KEY ----------------------------------------------------------
if [ -z "${APP_KEY:-}" ]; then
    log "FATAL: APP_KEY belum di-set. Jalankan 'docker compose run --rm artisan key:generate --show'"
    log "       lalu simpan hasilnya ke file .env."
    exit 1
fi

# --- 2. Tunggu database ------------------------------------------------------
if [ "${WAIT_FOR_DB}" = "true" ] && [ "${DB_CONNECTION:-mysql}" = "mysql" ]; then
    log "Menunggu database ${DB_HOST:-mysql}:${DB_PORT:-3306} ..."
    waited=0
    until php -r '
        $h = getenv("DB_HOST") ?: "mysql";
        $p = (int) (getenv("DB_PORT") ?: 3306);
        exit(@fsockopen($h, $p, $e, $s, 2) ? 0 : 1);
    '; do
        waited=$((waited + 2))
        if [ "${waited}" -ge "${DB_WAIT_TIMEOUT}" ]; then
            log "FATAL: database tidak merespons setelah ${DB_WAIT_TIMEOUT}s."
            exit 1
        fi
        sleep 2
    done
    log "Database siap."
fi

# --- 3. Cache & migrasi ------------------------------------------------------
if [ "${APP_ENV}" = "local" ]; then
    # Cek autoload.php, bukan sekadar direktori vendor/: kalau vendor dipasang
    # sebagai named volume, direktorinya ADA tapi isinya kosong pada boot pertama.
    # Harus dijalankan SEBELUM perintah artisan apa pun, karena artisan sendiri
    # butuh vendor/autoload.php.
    #
    # app, queue, dan scheduler boot bersamaan dan berbagi volume vendor yang
    # sama. Tanpa lock, ketiganya menjalankan composer install serentak ke
    # direktori yang sama dan hasilnya vendor/ yang rusak sebagian. flock
    # memastikan hanya satu yang memasang; sisanya menunggu lalu melewati
    # (karena pengecekan diulang di dalam lock).
    if [ ! -f vendor/autoload.php ]; then
        log "Dependency PHP belum terpasang — menunggu giliran memasang."
        (
            flock 9
            if [ ! -f vendor/autoload.php ]; then
                log "Menjalankan composer install."
                composer install --no-interaction --prefer-dist
            else
                log "Sudah dipasang oleh container lain."
            fi
        ) 9>storage/.composer-install.lock
    fi

    # Di lokal kode di-bind-mount, jadi cache justru bikin perubahan tidak terlihat.
    log "APP_ENV=local — membersihkan cache."
    php artisan optimize:clear || true
else
    log "Membangun cache produksi."
    # config:cache harus di runtime, bukan build time, supaya environment
    # variable milik container (bukan milik builder) yang ikut ter-cache.
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
fi

# Symlink public/storage hanya relevan bila public/ writable. Di Kubernetes
# rootfs container read-only dan web server melayani /storage/* langsung dari
# volume, jadi symlink-nya memang tidak dibutuhkan — jangan ributkan kalau gagal.
if [ -w public ]; then
    php artisan storage:link --quiet >/dev/null 2>&1 || true
fi

if [ "${RUN_MIGRATIONS}" = "true" ]; then
    log "Menjalankan migrasi database."
    # Catatan: JANGAN pakai --isolated saat CACHE_STORE=database. Lock-nya disimpan
    # di tabel cache_locks, yang justru baru dibuat oleh migrasi itu sendiri —
    # sehingga database kosong selalu gagal. Aktifkan hanya bila cache store
    # berada di luar database (Redis/Memcached) DAN ada lebih dari satu replika.
    if [ "${MIGRATE_ISOLATED:-false}" = "true" ]; then
        php artisan migrate --force --isolated
    else
        php artisan migrate --force
    fi
fi

log "Siap. Menjalankan: $*"
exec "$@"
