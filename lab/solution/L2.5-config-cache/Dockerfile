# =============================================================================
# L2.5 — SOLUSI
#
# Perubahannya: `php artisan config:cache` DIHAPUS dari Dockerfile dan dipindah
# ke entrypoint, sehingga dijalankan saat runtime ketika environment container
# sudah tersedia.
#
# Bangun dari akar proyek:
#     docker build -t lab-l25:solution -f lab/solution/L2.5-config-cache/Dockerfile .
# =============================================================================

FROM php:8.4-fpm-alpine

COPY --from=mlocati/php-extension-installer:2 \
     /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pcntl posix redis pdo_mysql opcache

WORKDIR /var/www/html

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY src/composer.json src/composer.lock ./
RUN composer install --no-dev --no-scripts --prefer-dist --no-progress
COPY src/ ./
RUN composer dump-autoload --no-dev --optimize

# [3] TIDAK ADA config:cache di sini.
#
# Perintah itu membekukan seluruh hasil evaluasi berkas config/ — termasuk setiap
# pemanggilan env() — menjadi satu berkas PHP. Dijalankan saat build, yang
# terbekukan adalah environment MESIN BUILD. Nilai server tidak pernah ikut, dan
# tidak ada pesan error apa pun yang memberi tahu: aplikasi hanya memakai nilai
# yang salah, diam-diam.

COPY lab/solution/L2.5-config-cache/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]
