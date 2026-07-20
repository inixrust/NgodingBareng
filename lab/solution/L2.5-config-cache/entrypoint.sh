#!/bin/sh
# =============================================================================
# L2.5 — SOLUSI: cache dibangun di RUNTIME
#
# Di sinilah `config:cache` seharusnya berada. Saat skrip ini berjalan,
# environment container sudah tersedia, sehingga yang ter-cache adalah nilai
# milik lingkungan tempat aplikasi benar-benar berjalan.
# =============================================================================
set -eu

cd /var/www/html

mkdir -p bootstrap/cache storage/framework/cache/data \
         storage/framework/sessions storage/framework/views storage/logs

if [ "${APP_ENV:-production}" = "local" ]; then
    # Di lokal kode di-bind-mount; cache justru membuat perubahan tidak terlihat.
    php artisan optimize:clear >/dev/null 2>&1 || true
else
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
fi

exec "$@"
