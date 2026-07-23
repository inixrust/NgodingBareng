# 2. Docker & Docker Compose

Berkas: [`docker/php/Dockerfile`](../docker/php/Dockerfile),
[`compose.yaml`](../compose.yaml)

## 2.1 Menyiapkan Kode Laravel

Panduan ini mengharapkan aplikasi Laravel berada di `src/`.

```bash
# Aplikasi baru
composer create-project laravel/laravel src

# Atau, memakai proyek yang sudah ada
cp -r /path/ke/proyek-laravel src
```

Satu penyesuaian kecil di aplikasi agar cocok dengan Kubernetes — Laravel
harus mempercayai header dari Ingress supaya `url()` menghasilkan `https://`
dan `request()->ip()` memberi IP pengunjung asli, bukan IP Pod:

```php
// src/bootstrap/app.php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(
        at: env('TRUSTED_PROXIES', '*'),
        headers: Request::HEADER_X_FORWARDED_FOR
               | Request::HEADER_X_FORWARDED_HOST
               | Request::HEADER_X_FORWARDED_PORT
               | Request::HEADER_X_FORWARDED_PROTO,
    );
})
```

## 2.2 Dockerfile: Enam Stage, Dua Image

Satu berkas menghasilkan dua image berbeda:

```bash
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:dev   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:dev .
```

| Stage | Isi | Ikut ke produksi? |
|---|---|---|
| `base` | runtime PHP + ekstensi + user non-root | ya (sebagai fondasi) |
| `vendor` | `composer install --no-dev` | hanya hasilnya |
| `assets` | Node + Vite build | hanya `public/build` |
| `php` | image PHP-FPM final | **ya** |
| `nginx` | image Nginx + `public/` | **ya** |
| `dev` | Xdebug, OPcache mati | tidak (hanya Compose) |

### Alasan setiap keputusan

#### Urutan instruksi = biaya build

Inti optimasi cache ada di tiga baris ini:

```dockerfile
COPY src/composer.json src/composer.lock ./     # ← hanya manifest
RUN composer install --no-dev --no-scripts --no-autoloader
COPY src/ ./                                    # ← baru kode aplikasi
```

Setiap instruksi Dockerfile menghasilkan satu layer, dan satu layer yang
berubah membatalkan cache **semua layer di atasnya**. Menyalin `composer.json`
lebih dulu berarti `composer install` hanya diulang ketika dependensinya
benar-benar berubah — bukan setiap kali seseorang mengubah satu baris di
`app/Http/Controllers/`.

Dampaknya nyata: build yang mengubah kode saja turun dari ~3 menit menjadi
~20 detik.

#### Multi-stage: yang membangun tidak ikut dikirim

Composer, Node, npm, dan seluruh `devDependencies` hanya ada di stage
`vendor` dan `assets`. Stage `php` hanya menyalin **hasilnya**:

```dockerfile
COPY --from=vendor --chown=10001:10001 /var/www/html ./
COPY --from=assets --chown=10001:10001 /app/public/build ./public/build
```

Ini bukan sekadar soal ukuran. Composer di dalam image produksi berarti
penyerang yang berhasil mengeksekusi perintah punya alat untuk mengunduh
paket dari internet.

#### Flag Composer, satu per satu

| Flag | Alasan |
|---|---|
| `--no-dev` | PHPUnit, Faker, dan Pest tidak punya urusan di produksi |
| `--no-scripts` | script Laravel butuh kode lengkap; dijalankan setelah `COPY src/` |
| `--no-autoloader` | autoloader dibuat belakangan, setelah semua kode ada |
| `--prefer-dist` | unduh arsip, bukan clone git — lebih kecil dan lebih cepat |
| `dump-autoload --optimize --classmap-authoritative` | peta kelas statis; menghilangkan puluhan `stat()` per request |

`--classmap-authoritative` berarti PHP **tidak akan pernah** mencari kelas di
filesystem — kalau tidak ada di peta, kelasnya dianggap tidak ada. Aman di
produksi karena kodenya sudah beku di dalam image, dan berbahaya saat
pengembangan (karena itu stage `dev` tidak memakainya).

#### OPcache: satu setelan yang paling menentukan

```ini
opcache.validate_timestamps = 0
```

Dengan `1` (default), PHP memeriksa waktu modifikasi **setiap berkas pada
setiap request**. Aplikasi Laravel menyentuh ribuan berkas, jadi itu ribuan
syscall yang sia-sia.

`0` aman di produksi justru karena image bersifat *immutable*: kode hanya
berubah lewat deploy image baru, dan deploy berarti container baru dengan
OPcache yang kosong. Efeknya pada aplikasi Laravel biasanya 3–5× lebih cepat.

`opcache.max_accelerated_files = 20000` juga penting: Laravel + vendor
mudah melewati 10.000 berkas, dan bila angkanya kekecilan OPcache **diam-diam
berhenti meng-cache sisanya** tanpa peringatan apa pun.

#### Non-root, dengan UID eksplisit

```dockerfile
RUN addgroup -g 10001 app && adduser -u 10001 -G app -D app
USER 10001:10001
```

UID ditetapkan angka, bukan diserahkan ke distro, supaya kepemilikan berkas
di PersistentVolume konsisten antar-Node dan antar-rebuild. Nilai `fsGroup`
di manifest Kubernetes harus cocok dengan angka ini.

Nginx memakai image `nginxinc/nginx-unprivileged` yang berjalan sebagai UID
101 dan mendengarkan di **port 8080**. Port di atas 1024 berarti prosesnya
tidak butuh capability `NET_BIND_SERVICE` sama sekali — syarat lolos profil
Pod Security `restricted`.

#### Probe FastCGI, bukan probe TCP

```sh
env -i SCRIPT_NAME=/fpm-ping SCRIPT_FILENAME=/fpm-ping REQUEST_METHOD=GET \
  cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong
```

Port 9000 sudah terbuka sejak master PHP-FPM start — **bahkan ketika seluruh
worker macet**. `tcpSocket` akan melaporkan sehat pada Pod yang sebenarnya
tidak bisa melayani satu request pun. `cgi-fcgi` benar-benar berbicara
protokol FastCGI dan menunggu jawaban dari sebuah worker.

#### `.dockerignore` adalah soal keamanan

```
.env
.env.*
!.env.example
src/public/hot
```

`docker build .` mengirim **seluruh** direktori ke daemon sebelum satu
instruksi pun dijalankan — termasuk `.env` berisi password produksi.

`public/hot` layak disebut khusus: berkas ini ditulis Vite saat mode
development dan berisi alamat server HMR. Bila ikut terbawa ke image
produksi, aplikasi akan mencoba memuat seluruh aset dari `localhost:5173`
milik pengembang. Situsnya rusak total, dan penyebabnya nyaris mustahil
ditebak dari gejalanya.

## 2.3 Docker Compose untuk Pengembangan

```bash
cp .env.example .env
docker compose run --rm app php artisan key:generate --show   # salin ke .env
docker compose up -d --build
docker compose exec app php artisan migrate
```

Buka `http://localhost:8080`.

### Perbedaan yang disengaja terhadap Kubernetes

| Aspek | Compose (dev) | Kubernetes (prod) | Alasan |
|---|---|---|---|
| Kode | bind-mount dari host | dibakar ke image | edit-refresh instan vs immutable |
| OPcache | mati | `validate_timestamps=0` | perubahan langsung terlihat |
| Xdebug | aktif | tidak ada | debugging vs kinerja |
| `config:cache` | dilewati (`SKIP_OPTIMIZE=true`) | dijalankan | perubahan `.env` langsung berlaku |
| Port database | dibuka ke host | hanya internal | agar bisa dibuka DBeaver/TablePlus |
| Scheduler | `schedule:work` | CronJob | Compose tidak punya penjadwal |

### Yang tetap sama — dan ini yang penting

Nama host layanan **identik** di kedua lingkungan: `mariadb`, `redis`,
`redis-cache`. Di Compose itu nama service; di Kubernetes itu nama Service.
Karena itu `DB_HOST=mariadb` benar di keduanya, dan kode aplikasi tidak
pernah perlu tahu ia sedang berjalan di mana.

### Kenapa `vendor/` memakai named volume

```yaml
volumes:
  - ./src:/var/www/html          # bind mount
  - vendor:/var/www/html/vendor  # named volume
```

Di Windows dan macOS, bind mount berisi puluhan ribu berkas kecil membuat
autoload Composer jauh lebih lambat karena setiap akses berkas melewati
lapis terjemahan filesystem. Named volume hidup di dalam VM Docker dan tidak
melewati lapis itu.

Pengukuran pada proyek serupa: **2,0 detik → 0,15 detik** per request.

### Perintah yang sering dipakai

```bash
docker compose logs -f app                     # ikuti log PHP
docker compose exec app php artisan tinker     # REPL
docker compose exec app php artisan migrate:fresh --seed
docker compose exec mariadb mariadb -ularavel -p laravel
docker compose down -v                         # -v ikut menghapus volume
```

---

Berikutnya: [03-kubernetes-manifest.md](03-kubernetes-manifest.md)
