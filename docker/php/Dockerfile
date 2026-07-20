# syntax=docker/dockerfile:1.7
#
# Multi-stage build untuk Laravel 13.
# Target yang tersedia:
#   --target base   : runtime PHP-FPM telanjang (dipakai stage lain)
#   --target dev    : untuk ngoding lokal (bind mount + composer + xdebug)
#   --target app    : image produksi PHP-FPM (default)
#   --target web    : image nginx produksi yang sudah berisi public/ + asset build

ARG PHP_VERSION=8.4
ARG NODE_VERSION=22
ARG NGINX_VERSION=1.29

# =============================================================================
# Stage: base — runtime PHP-FPM minimal
# =============================================================================
FROM php:${PHP_VERSION}-fpm-alpine AS base

# fcgi dipakai untuk healthcheck php-fpm lewat cgi-fcgi
RUN apk add --no-cache fcgi tzdata \
    && rm -rf /var/cache/apk/*

# install-php-extensions menangani semua build-deps dan membersihkannya sendiri
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        opcache \
        pcntl \
        pdo_mysql \
        posix \
        redis \
        zip

WORKDIR /var/www/html

COPY docker/php/conf.d/ /usr/local/etc/php/conf.d/
COPY docker/php/php-fpm.d/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/php/bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/fpm-ping

# php-fpm master tetap root agar bisa bind & drop privilege ke www-data (uid 82),
# worker-nya berjalan sebagai www-data — lihat php-fpm.d/www.conf
EXPOSE 9000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD ["fpm-ping"]

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]

# =============================================================================
# Stage: vendor — install dependency PHP produksi
# =============================================================================
FROM base AS vendor

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1

WORKDIR /app

# Layer terpisah supaya cache composer tidak batal tiap kali kode berubah
COPY src/composer.json src/composer.lock ./
RUN --mount=type=cache,target=/tmp/composer-cache \
    COMPOSER_CACHE_DIR=/tmp/composer-cache \
    composer install \
        --no-dev \
        --no-scripts \
        --no-autoloader \
        --prefer-dist \
        --no-progress

COPY src/ ./
RUN composer dump-autoload --no-dev --optimize --classmap-authoritative \
    && composer run-script post-autoload-dump --no-dev

# =============================================================================
# Stage: assets — build asset frontend (Vite)
# =============================================================================
FROM node:${NODE_VERSION}-alpine AS assets

WORKDIR /app

COPY src/package*.json src/.npmrc ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY src/vite.config.js ./
COPY src/resources ./resources
COPY src/public ./public
RUN npm run build

# =============================================================================
# Stage: app — image produksi PHP-FPM
# =============================================================================
FROM base AS app

ENV APP_ENV=production \
    APP_DEBUG=false

# Kode aplikasi (tanpa vendor/node_modules — lihat .dockerignore)
COPY --chown=www-data:www-data src/ /var/www/html/
COPY --from=vendor --chown=www-data:www-data /app/vendor /var/www/html/vendor
COPY --from=assets --chown=www-data:www-data /app/public/build /var/www/html/public/build

# Catatan: Horizon >= 5.4x TIDAK lagi mem-publish aset ke public/. Dashboard-nya
# menyajikan CSS/JS lewat route-nya sendiri, jadi tidak ada `horizon:publish`
# yang perlu dijalankan di sini.

# Hanya dua direktori ini yang perlu writable; sisanya read-only
RUN set -eux; \
    mkdir -p \
        storage/app/public \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/testing \
        storage/framework/views \
        storage/logs \
        bootstrap/cache; \
    chown -R www-data:www-data storage bootstrap/cache; \
    chmod -R u=rwX,g=rX,o= storage bootstrap/cache; \
    # Nginx berjalan sebagai user lain (uid 101) dan perlu membaca file upload
    # publik langsung dari volume. Beri hak telusur ke direktori induknya saja,
    # lalu hak baca penuh pada isi storage/app/public — memang untuk publik.
    chmod o+x storage storage/app; \
    chmod -R o+rX storage/app/public; \
    rm -f .env .env.example

# =============================================================================
# Stage: web — nginx produksi, sudah berisi asset statis
# =============================================================================
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine AS web

USER root
COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY --from=app /var/www/html/public /var/www/html/public
RUN chown -R nginx:nginx /var/www/html/public
USER nginx

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO /dev/null http://127.0.0.1:8080/up || exit 1

# =============================================================================
# Stage: caddy — web server alternatif (default), TLS otomatis
# =============================================================================
FROM caddy:2-alpine AS caddy

# Caddy resmi berjalan sebagai root. Buat user biasa supaya sejajar dengan
# pilihan nginx-unprivileged. Bisa non-root karena Caddyfile memakai port
# 8080/8443, bukan 80/443 yang butuh privilege.
RUN addgroup -S -g 10001 caddyapp \
    && adduser -S -u 10001 -G caddyapp -H -s /sbin/nologin caddyapp \
    && mkdir -p /data /config \
    && chown -R caddyapp:caddyapp /data /config \
    # Binary caddy dikirim dengan file capability cap_net_bind_service=ep agar
    # bisa bind port 80/443 sebagai non-root. Kita tidak membutuhkannya (port
    # 8080/8443), dan capability ini justru MEMBUAT GAGAL: dengan
    # allowPrivilegeEscalation=false — wajib di Pod Security "restricted" —
    # kernel menolak meng-exec file yang punya effective file capability, dengan
    # pesan "operation not permitted" yang sama sekali tidak menjelaskan apa pun.
    && apk add --no-cache libcap \
    && setcap -r /usr/bin/caddy \
    && apk del libcap

COPY docker/caddy/Caddyfile /etc/caddy/Caddyfile
COPY --from=app --chown=caddyapp:caddyapp /var/www/html/public /var/www/html/public

RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

USER caddyapp
ENV XDG_DATA_HOME=/data \
    XDG_CONFIG_HOME=/config

EXPOSE 8080 8443

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO /dev/null http://127.0.0.1:8080/up || exit 1

# =============================================================================
# Stage: dev — untuk pengembangan lokal (kode di-bind-mount dari host)
# =============================================================================
FROM base AS dev

ENV APP_ENV=local \
    APP_DEBUG=true \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
RUN install-php-extensions xdebug \
    && rm -f /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

COPY docker/php/conf.d-dev/ /usr/local/etc/php/conf.d/
COPY docker/php/php-fpm.d-dev/ /usr/local/etc/php-fpm.d/
