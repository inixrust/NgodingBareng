# =============================================================================
# L1.1 — Mengurutkan Ulang Dockerfile
#
# Dockerfile ini BEKERJA, tetapi lambat: setiap perubahan satu baris kode PHP
# membuat Composer mengunduh ulang seluruh dependensi.
#
# Tugas Anda: ubah HANYA URUTAN instruksi. Jangan menambah atau menghapus
# perintah apa pun.
#
# Bangun dari akar proyek:
#     docker build -t lab-l11:starter -f lab/starter/L1.1-cache-build/Dockerfile .
# =============================================================================

FROM php:8.4-fpm-alpine

# Ekstensi yang dibutuhkan Laravel 13 + Horizon. Layer paling stabil,
# jadi letaknya paling atas — sesuai pelajaran lab ini.
COPY --from=mlocati/php-extension-installer:2      /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pcntl posix redis pdo_mysql opcache

WORKDIR /var/www/html

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# TODO [3] — Dua instruksi di bawah ini urutannya menyebabkan cache selalu batal.
#            Perhatikan: cache sebuah layer ikut batal bila ada layer DI BAWAHNYA
#            yang berubah. Instruksi mana yang paling mahal, dan apa yang membuat
#            cache-nya batal terus-menerus?
#
#            Susun ulang sehingga `composer install` hanya diulang ketika
#            dependensinya yang benar-benar berubah.

COPY src/ ./

RUN composer install --no-dev --no-scripts --prefer-dist --no-progress

# Catatan: --no-scripts dipakai agar lab ini tidak bergantung pada berkas .env.
