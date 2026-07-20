# =============================================================================
# L1.1 — SOLUSI
#
# Perubahannya hanya urutan: manifest dependensi disalin dan dipasang LEBIH DULU,
# kode aplikasi menyusul belakangan.
#
# Kenapa berhasil: cache sebuah layer batal bila instruksinya berubah ATAU ada
# layer di bawahnya yang berubah. Dengan `COPY src/ ./` berada di BAWAH
# `composer install`, perubahan kode tidak lagi menyentuh layer composer.
#
# Bangun dari akar proyek:
#     docker build -t lab-l11:solution -f lab/solution/L1.1-cache-build/Dockerfile .
# =============================================================================

FROM php:8.4-fpm-alpine

# Ekstensi yang dibutuhkan Laravel 13 + Horizon. Layer paling stabil,
# jadi letaknya paling atas — sesuai pelajaran lab ini.
COPY --from=mlocati/php-extension-installer:2      /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pcntl posix redis pdo_mysql opcache

WORKDIR /var/www/html

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# [3] Manifest dependensi lebih dulu — hanya berubah saat dependensi berubah.
COPY src/composer.json src/composer.lock ./

# Layer paling mahal, kini terlindung dari perubahan kode.
RUN composer install --no-dev --no-scripts --prefer-dist --no-progress

# Kode aplikasi paling belakang — berubah hampir tiap commit, dan itu tidak apa-apa
# karena tidak ada lagi layer mahal di atasnya.
COPY src/ ./
