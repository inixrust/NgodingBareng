# syntax=docker/dockerfile:1.7
#
# Dockerfile produksi untuk Laravel (PHP-FPM) dan Nginx.
# Satu berkas, beberapa stage, dua image hasil akhir:
#
#   --target php    -> image PHP-FPM  (menjalankan kode Laravel)
#   --target nginx  -> image Nginx    (melayani berkas statis + proxy FastCGI)
#
# Keduanya dibangun dari commit yang sama sehingga berkas statis di Nginx
# selalu sinkron dengan kode di PHP-FPM.
#
# Build context = akar repositori (kode Laravel ada di ./src).

ARG PHP_VERSION=8.4
ARG NODE_VERSION=22
ARG NGINX_VERSION=1.27
ARG APP_UID=10001
ARG APP_GID=10001


# ============================================================== STAGE 1: base
# Fondasi bersama untuk stage vendor dan php. Berisi runtime PHP + ekstensi,
# tanpa satu baris pun kode aplikasi. Layer ini nyaris tidak pernah berubah,
# sehingga cache-nya bertahan lama.
FROM php:${PHP_VERSION}-fpm-alpine AS base

ARG APP_UID
ARG APP_GID

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    COMPOSER_MEMORY_LIMIT=-1

# fcgi  -> menyediakan cgi-fcgi, dipakai probe kesehatan PHP-FPM
# tzdata-> zona waktu benar di log dan scheduler
# Paket runtime lain (icu, libzip, ...) dipasang otomatis oleh
# install-php-extensions sebagai dependensi ekstensi.
RUN apk add --no-cache fcgi tzdata

# install-php-extensions menangani dependensi build (autoconf, gcc, header)
# lalu membuangnya lagi. Hasilnya jauh lebih ramping daripada memasang
# build-base secara manual, dan versinya di-pin agar build reproducible.
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        opcache \
        pcntl \
        pdo_mysql \
        redis \
        zip \
        @composer-2

# Pengguna non-root. UID/GID ditetapkan eksplisit (bukan diserahkan ke
# distro) supaya kepemilikan berkas di PersistentVolume tetap konsisten
# antar-node dan antar-rebuild.
RUN addgroup -g ${APP_GID} app \
 && adduser  -u ${APP_UID} -G app -h /var/www/html -s /sbin/nologin -D app

WORKDIR /var/www/html


# ============================================================ STAGE 2: vendor
# Dependensi PHP. Dipisah agar `composer install` hanya diulang ketika
# composer.json/composer.lock berubah -- bukan setiap kali kode berubah.
FROM base AS vendor

# Salin HANYA manifest dependensi lebih dulu. Inilah inti optimasi cache:
# selama kedua berkas ini sama, seluruh unduhan paket dipakai ulang.
COPY src/composer.json src/composer.lock ./

# --no-dev            : phpunit, faker, dan kawan-kawan tidak ikut ke produksi
# --no-scripts        : script Laravel butuh kode lengkap, dijalankan nanti
# --no-autoloader     : autoloader dibuat setelah seluruh kode ada
# --prefer-dist       : unduh arsip, bukan clone git (lebih kecil, lebih cepat)
RUN --mount=type=cache,target=/tmp/composer-cache \
    COMPOSER_CACHE_DIR=/tmp/composer-cache \
    composer install \
        --no-dev \
        --no-scripts \
        --no-autoloader \
        --prefer-dist \
        --no-progress

# Baru sekarang kode aplikasi masuk.
COPY src/ ./

# Autoloader terklasifikasi penuh: peta kelas statis, tanpa pencarian
# filesystem saat runtime. Menghemat puluhan stat() per request.
RUN composer dump-autoload --no-dev --optimize --classmap-authoritative \
 && composer run-script post-autoload-dump


# ============================================================ STAGE 3: assets
# Build aset frontend (Vite). Node hanya hidup di stage ini dan tidak pernah
# ikut ke image akhir.
FROM node:${NODE_VERSION}-alpine AS assets

WORKDIR /app

COPY src/package.json src/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY src/ ./
# Beberapa plugin Vite (mis. laravel-vite-plugin) membaca berkas di vendor/.
COPY --from=vendor /var/www/html/vendor ./vendor
RUN npm run build


# =============================================================== STAGE 4: php
# Image produksi PHP-FPM. Tidak ada Composer, tidak ada Node, tidak ada
# devDependencies, tidak ada source aset -- hanya yang dibutuhkan saat runtime.
FROM base AS php

ARG APP_UID
ARG APP_GID

COPY docker/php/php.ini        /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/opcache.ini    /usr/local/etc/php/conf.d/zz-opcache.ini
COPY docker/php/www.conf       /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker/php/fpm-healthcheck /usr/local/bin/fpm-healthcheck
COPY docker/php/entrypoint.sh  /usr/local/bin/entrypoint

RUN chmod +x /usr/local/bin/fpm-healthcheck /usr/local/bin/entrypoint

COPY --from=vendor --chown=${APP_UID}:${APP_GID} /var/www/html ./
COPY --from=assets --chown=${APP_UID}:${APP_GID} /app/public/build ./public/build

# Direktori yang WAJIB bisa ditulis Laravel. Di Kubernetes ketiganya ditimpa
# oleh emptyDir/PVC, tetapi izinnya tetap disiapkan di sini agar image ini
# juga benar saat dijalankan lewat Docker Compose.
RUN mkdir -p storage/framework/{cache/data,sessions,views} storage/logs bootstrap/cache \
 && chown -R ${APP_UID}:${APP_GID} storage bootstrap/cache \
 && chmod -R u+rwX storage bootstrap/cache

# Symlink public/storage -> storage/app/public.
#
# Ini yang biasanya dikerjakan `php artisan storage:link`. Dibuat SAAT BUILD,
# bukan saat runtime, karena public/ berada di root filesystem yang read-only
# di Kubernetes -- artisan tidak akan bisa membuatnya di sana.
#
# Symlink-nya relatif supaya tetap benar di image Nginx, yang punya public/
# tetapi tidak punya kode aplikasi.
RUN ln -sfn ../storage/app/public public/storage

# Kunci utama keamanan: proses tidak pernah berjalan sebagai root.
USER ${APP_UID}:${APP_GID}

EXPOSE 9000

# Healthcheck ini dipakai Docker Compose. Di Kubernetes, probe pada manifest
# yang berlaku (lihat kubernetes/base/deployment-laravel.yaml).
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
    CMD /usr/local/bin/fpm-healthcheck || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["php-fpm", "--nodaemonize"]


# ============================================================= STAGE 5: nginx
# Image Nginx yang sudah membawa isi public/. Karena berkas statis ada di
# dalam image, Nginx tidak perlu berbagi volume dengan PHP-FPM -- syarat
# utama agar keduanya bisa menjadi Deployment terpisah dan diskalakan sendiri.
#
# nginx-unprivileged: varian resmi yang berjalan sebagai UID 101 dan
# mendengarkan di port 8080 (>1024), sehingga tidak butuh capability
# NET_BIND_SERVICE sama sekali.
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine AS nginx

# Image dasarnya sudah menetapkan USER 101. Kembali ke root sebentar supaya
# instruksi RUN di bawah boleh menulis, lalu turun lagi sebelum stage selesai.
USER root

COPY docker/nginx/nginx.conf   /etc/nginx/nginx.conf
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

# Hanya public/ yang disalin. Kode aplikasi (app/, config/, .env) TIDAK
# pernah masuk ke image Nginx -- mengurangi permukaan serang bila Nginx
# suatu saat bisa ditembus.
COPY --from=vendor /var/www/html/public /var/www/html/public
COPY --from=assets /app/public/build    /var/www/html/public/build

# Symlink public/storage dibuat ulang di sini. COPY tidak selalu
# mempertahankan symlink relatif apa adanya, dan Nginx membutuhkannya untuk
# melayani /storage/... dari PVC yang dipasang di /var/www/html/storage/app/public.
RUN ln -sfn ../storage/app/public /var/www/html/public/storage

USER 101
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1


# =============================================================== STAGE 6: dev
# Hanya untuk Docker Compose. Berisi Xdebug dan tetap membawa Composer,
# karena kode di-bind-mount dari host saat pengembangan.
FROM base AS dev

ARG APP_UID
ARG APP_GID

COPY docker/php/php.ini       /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/www.conf      /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker/php/fpm-healthcheck /usr/local/bin/fpm-healthcheck
COPY docker/php/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/fpm-healthcheck /usr/local/bin/entrypoint

# OPcache sengaja TIDAK di-cache-kan agar perubahan kode langsung terlihat.
RUN install-php-extensions xdebug \
 && echo "opcache.enable=0" > /usr/local/etc/php/conf.d/zz-opcache-off.ini

USER ${APP_UID}:${APP_GID}
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["php-fpm", "--nodaemonize"]
