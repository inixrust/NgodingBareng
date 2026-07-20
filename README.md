# Laravel 13 + MySQL + Nginx di Docker

Kontainerisasi Laravel 13 dengan build multi-stage, siap untuk produksi, dan
nyaman dipakai untuk ngoding sehari-hari di Docker Desktop (Windows).

## Struktur

```
.
├── compose.yaml            # stack produksi
├── compose.override.yaml   # override development (dimuat OTOMATIS)
├── .env                    # konfigurasi + rahasia (jangan di-commit)
├── .env.example            # contoh konfigurasi
├── docker/
│   ├── php/                # Dockerfile multi-stage + konfigurasi PHP/FPM
│   ├── nginx/              # konfigurasi nginx
│   └── mysql/              # image MySQL + my.cnf
└── src/                    # aplikasi Laravel 13
```

## Mulai cepat

```powershell
copy .env.example .env
# isi APP_KEY, DB_PASSWORD, dan DB_ROOT_PASSWORD
docker compose run --rm artisan key:generate --show   # salin hasilnya ke APP_KEY

docker compose up -d --build
```

Buka <http://localhost:8080>.

Booting pertama memakan waktu (build image + inisialisasi MySQL). Pantau dengan
`docker compose logs -f app`.

## Perintah sehari-hari

| Keperluan            | Perintah                                                  |
| -------------------- | --------------------------------------------------------- |
| Jalankan / hentikan  | `docker compose up -d` / `docker compose down`             |
| Lihat log            | `docker compose logs -f app` (atau `caddy`, `horizon`, `mysql`) |
| Artisan              | `docker compose run --rm artisan migrate`                  |
| Tinker               | `docker compose run --rm artisan tinker`                   |
| Composer             | `docker compose run --rm composer require nama/paket`      |
| Shell di container   | `docker compose exec app sh`                               |
| Status queue         | `docker compose exec app php artisan horizon:status`       |
| Uji queue worker     | `docker compose run --rm artisan tinker --execute="App\Jobs\PingJob::dispatch();"` |
| Inspeksi Redis       | `docker compose exec redis redis-cli -a "$env:REDIS_PASSWORD"` |
| Ganti web server     | ubah `COMPOSE_PROFILES` di `.env`, lalu `docker compose down --remove-orphans && docker compose up -d` |
| Reset total          | `docker compose down -v --remove-orphans` (menghapus database!) |

## Arsitektur

```
Browser :8080 ──► caddy (atau nginx)
                    ├─ /build/*, /storage/*  → dilayani langsung dari disk
                    └─ selain itu           → FastCGI ──► app (php-fpm)
                                                            │
                                                            ├──► mysql
                    horizon, scheduler (image sama) ────────┼──► redis        (queue + session)
                                                            └──► redis-cache  (cache)
```

- **caddy** — web server default, non-root, TLS otomatis. Profile `caddy`.
- **web** — nginx `nginx-unprivileged`, alternatif setara. Profile `nginx`.
- **app** — PHP-FPM. Container inilah yang menjalankan migrasi saat boot.
- **horizon** — supervisor queue Redis, dashboard di `/horizon`.
- **scheduler** — `schedule:work`, pengganti cron.
- **mysql** — MySQL 8.4 dengan konfigurasi yang dipanggang ke dalam image.
- **redis** — queue + session, `noeviction`, AOF menyala.
- **redis-cache** — cache saja, `allkeys-lru`, tanpa persistensi.

`horizon` dan `scheduler` memakai image yang **persis sama** dengan `app`, hanya
berbeda perintah — sehingga tidak mungkin ada perbedaan versi kode antar proses.

### Memilih web server

Ditentukan `COMPOSE_PROFILES` di `.env`:

```dotenv
COMPOSE_PROFILES=caddy   # default
COMPOSE_PROFILES=nginx   # alternatif
```

> Saat berganti, **wajib** `docker compose down --remove-orphans` lebih dulu.
> Compose tidak menghentikan service di luar profile aktif, jadi web server lama
> tetap hidup dan port 8080 bentrok.

Keduanya diuji berperilaku sama untuk `/`, `/up`, `/horizon`, `/storage/*`,
`/build/*`, blokir dotfile, header keamanan, dan kompresi. Satu-satunya beda:
akses langsung ke `/index.php` dijawab `308` oleh Caddy dan `404` oleh nginx —
keduanya sama-sama menolak.

Caddyfile ~60 baris (termasuk komentar) vs nginx ~150 baris, dan Caddy sekalian
mengurus sertifikat TLS. Nginx dipertahankan karena masih jauh lebih umum
ditemui di lapangan.

### Kenapa Redis-nya dua

Kebijakan eviction Redis berlaku **per-server**, bukan per-database. Kalau cache
dan queue berbagi satu instance, hanya ada dua pilihan dan keduanya buruk:

| Kebijakan     | Akibatnya                                                     |
| ------------- | ------------------------------------------------------------- |
| `allkeys-lru` | Redis boleh membuang key apa pun saat memori penuh — termasuk job yang masih mengantre. Job hilang diam-diam. |
| `noeviction`  | Job aman, tapi penulisan cache mulai gagal (OOM) begitu penuh. |

Dua instance membuat masing-masing bisa memakai kebijakan yang benar. Kalau
hanya ingin satu instance, kosongkan `REDIS_CACHE_HOST` — `config/database.php`
otomatis jatuh ke `REDIS_HOST`, tapi konsekuensi di tabel atas berlaku.

### Autentikasi (Laravel Breeze)

Starter kit resmi Laravel, stack Blade. Menambahkan `/login`, `/register`,
`/dashboard`, `/profile`, reset password, dan verifikasi email.

Buat akun pertama lewat <http://localhost:8080/register>, atau langsung:

```powershell
docker compose exec app php artisan tinker --execute="App\Models\User::updateOrCreate(['email'=>'anda@contoh.com'],['name'=>'Nama','password'=>Hash::make('password-anda'),'email_verified_at'=>now()]);"
```

> **`/register` terbuka untuk publik.** Itu memang bawaan starter kit. Untuk
> deployment yang tidak menerima pendaftaran umum, matikan dengan menghapus dua
> route `register` di `src/routes/auth.php`. Akun tetap bisa dibuat lewat
> perintah di atas.

Reset password memakai email, sedangkan `MAIL_MAILER=log` — jadi tautannya
muncul di log, bukan terkirim: `docker compose logs app | Select-String "reset"`.

**Catatan Tailwind.** Breeze v2.4 masih men-scaffold untuk Tailwind 3 (direktif
`@tailwind`, `tailwind.config.js`, `postcss.config.js`), sedangkan skeleton
Laravel 13 memakai Tailwind 4. Stack ini disamakan ke **Tailwind 4**: konfigurasi
pindah ke `resources/css/app.css` (`@import`, `@plugin`, `@source`, `@theme`) dan
kedua file config bawaan Breeze dihapus. Breeze juga menimpa `vite.config.js`
saat scaffolding — konfigurasi khusus Windows dan plugin fonts sudah dikembalikan.

### Horizon

Dashboard: <http://localhost:8080/horizon>.

Di `APP_ENV=local` terbuka untuk siapa pun. Di luar itu, akses ditentukan gate di
`src/app/Providers/HorizonServiceProvider.php`, yang membaca
`HORIZON_ALLOWED_EMAILS` (dipisah koma) dan mencocokkannya dengan email user
yang **sedang login**. Kosong = tidak ada yang bisa masuk.

Diuji di Kubernetes (`APP_ENV=production`): user dengan email di daftar mendapat
`/horizon` 200, user lain yang sudah login mendapat 403, belum login mendapat 403.

Horizon mengelola sendiri jumlah worker dan auto-scaling-nya
(`src/config/horizon.php`), jadi tidak ada `--max-time` seperti `queue:work`
biasa. Saat deploy, `stop_grace_period: 60s` memberi waktu job yang sedang
berjalan untuk selesai.

## Build multi-stage

`docker/php/Dockerfile` berisi enam stage:

| Stage     | Isi                                                        |
| --------- | ---------------------------------------------------------- |
| `base`    | PHP-FPM Alpine + ekstensi (pdo_mysql, redis, gd, intl, …)   |
| `vendor`  | `composer install --no-dev` + autoloader ter-optimasi       |
| `assets`  | Node 22, `npm ci` + `vite build`                            |
| `app`     | **produksi** — base + vendor + asset hasil build            |
| `caddy`   | **produksi** — Caddy + salinan `public/` dari stage `app`   |
| `web`     | **produksi** — nginx + salinan `public/` dari stage `app`   |
| `dev`     | base + Composer + Xdebug, untuk bind mount lokal            |

Stage `caddy` menjalankan `caddy validate` saat build, jadi Caddyfile yang salah
menggagalkan build, bukan menggagalkan container saat sudah jalan.

Composer dan Node **tidak ikut** ke image akhir. Hasilnya:

```
laravel-app:latest         272 MB   ← produksi (tanpa composer, npm, xdebug)
laravel-app-caddy:latest    89 MB   ← produksi
laravel-app-web:latest      82 MB   ← produksi (nginx)
laravel-app:dev            227 MB   ← development
```

Tag `:dev` dan `:latest` sengaja dipisah. Kalau disamakan, `docker compose up
--build` di lokal akan menimpa image produksi dengan versi berisi Xdebug —
dan itu yang ikut ter-deploy.

## Keputusan produksi

**Cache dibangun saat runtime, bukan saat build.** `config:cache` menyimpan nilai
environment ke dalam file. Kalau dijalankan waktu build, yang tersimpan adalah
environment milik mesin build — bukan milik server. Karena itu `config:cache`,
`route:cache`, `view:cache`, dan `event:cache` dijalankan di entrypoint.

**OPcache dengan `validate_timestamps=0`.** Kode di dalam image tidak pernah
berubah saat runtime, jadi tidak perlu `stat()` ke setiap file di tiap request.
Konsekuensinya: deploy = ganti container, bukan menimpa file.

**Migrasi hanya dijalankan satu container.** Hanya service `app` yang punya
`RUN_MIGRATIONS=true`. Jangan mengaktifkan `MIGRATE_ISOLATED` selama
`CACHE_STORE=database` — lock-nya tersimpan di tabel `cache_locks`, yang justru
baru dibuat oleh migrasi itu sendiri, sehingga database kosong selalu gagal.

**Nginx melayani file statis sendiri.** `/build/*` (nama file sudah ber-hash →
`Cache-Control: immutable`, 1 tahun) dan `/storage/*` (upload disk publik, lewat
volume bersama) tidak pernah menyentuh PHP.

**`/index.php` ditandai `internal`.** Hanya bisa dicapai lewat rewrite internal
dari `try_files`, jadi tidak bisa diakses langsung dari luar. File `.php` lain
dibalas 404.

**Semua proses drop privilege.** Worker PHP-FPM berjalan sebagai `www-data`,
nginx sebagai `nginx` (uid 101). Hanya master php-fpm yang tetap root, sebatas
untuk bind port lalu menurunkan hak akses.

**Healthcheck di setiap lapis.** MySQL diping sebagai user aplikasi (bukan root,
supaya grant-nya ikut terverifikasi); php-fpm lewat `ping.path` FastCGI; nginx
lewat `GET /up` yang menembus sampai ke PHP.

## Catatan khusus Windows / Docker Desktop

Bind mount dari drive Windows sangat lambat untuk direktori berisi banyak file.
Terukur di setup ini: **~2,0 detik per request** dengan `vendor/` di bind mount,
turun menjadi **~0,15 detik** setelah `vendor/` dipindah ke named volume.

Karena itu `compose.override.yaml` memasang `vendor/` dan `node_modules/` sebagai
named volume. Ada satu konsekuensi yang perlu diingat:

> `./src/vendor` di host **tidak ikut ter-update** saat menambah paket.
> Container memakai isi volume, sementara salinan di host tetap seperti semula.

Salinan di host hanya dipakai IDE untuk autocomplete. Kalau autocomplete mulai
terasa ketinggalan setelah menambah paket, segarkan dengan:

```powershell
docker compose cp app:/var/www/html/vendor/. ./src/vendor
```

Alternatif tercepat: pindahkan seluruh project ke filesystem WSL2
(`\\wsl$\Ubuntu\home\<user>\...`) — di sana bind mount berjalan pada kecepatan
Linux dan trik named volume tidak diperlukan sama sekali.

## Xdebug

Sudah terpasang di stage `dev`, tapi **mati** secara default (Xdebug aktif
memperlambat PHP cukup signifikan). Untuk mengaktifkan:

```powershell
$env:XDEBUG_MODE="debug"; docker compose up -d app
```

Konfigurasinya: port 9003, `start_with_request=trigger`, IDE key `VSCODE`.

## Hot reload frontend

Service `vite` menjalankan dev server di port 5173. Tetap buka
<http://localhost:8080> seperti biasa — Blade otomatis menarik asset dari Vite
selama file `src/public/hot` ada.

`vite.config.js` mengunci `server.origin` ke `http://localhost:5173`. Tanpa itu
laravel-vite-plugin menulis `http://0.0.0.0:5173` ke file `hot`, dan browser
gagal memuat asset.

## Menjalankan mode produksi di lokal

`compose.override.yaml` dimuat otomatis. Untuk menguji image produksi apa adanya,
lewati file itu secara eksplisit:

```powershell
docker compose -f compose.yaml up -d --build
```

Set juga `APP_ENV=production`, `APP_DEBUG=false`, dan `LOG_LEVEL=warning` di
`.env`.

> Catatan: flag `--env-file` hanya memengaruhi interpolasi `${...}` di dalam file
> compose, **bukan** direktif `env_file:` yang diteruskan ke container. Nilai yang
> diterima aplikasi selalu berasal dari `.env`.

## Sebelum benar-benar dipakai di produksi

Yang belum ditangani dan perlu disiapkan sendiri:

- **TLS.** Dengan profile `caddy`, cukup set `SITE_ADDRESS` ke domain sungguhan
  dan `ACME_EMAIL`, lalu petakan port host `80:8080` dan `443:8443` di
  `compose.yaml` — Caddy mengurus sertifikatnya sendiri. Setelah itu set
  `SESSION_SECURE_COOKIE=true` dan `TRUSTED_PROXIES`.
  Dengan profile `nginx`, sediakan TLS-nya sendiri di depan.
- **Gate Horizon.** Isi `HORIZON_ALLOWED_EMAILS`, atau `/horizon` akan tertutup
  untuk semua orang di produksi.
- **Rahasia.** `.env` cukup untuk satu server. Untuk beberapa host, pindahkan ke
  Docker secrets atau secret manager.
- **Backup.** Volume `mysql-data` dan `redis-data` tidak otomatis di-backup.
  `redis-data` berisi antrean job yang belum diproses.
- **Ukuran resource.** Limit memori di `compose.yaml`, `maxmemory` Redis, dan
  `innodb_buffer_pool_size` di `docker/mysql/conf.d/app.cnf` disetel untuk mesin
  pengembangan. Sesuaikan dengan server sungguhan.
- **`pm.max_children`.** Disetel 20. Rumusnya: RAM tersedia ÷ rata-rata pemakaian
  memori per worker.
