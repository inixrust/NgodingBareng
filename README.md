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
│   ├── caddy/              # Caddyfile
│   └── mysql/              # image MySQL + my.cnf
├── k8s/                    # manifest Kubernetes (Kustomize)
│   ├── base/               # sumber tunggal: semua Deployment/StatefulSet/Service
│   ├── overlays/local/     # overlay Docker Desktop (secrets.env + imagePullPolicy)
│   └── tools/              # utilitas (wipe data mysql)
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

## Deploy ke Kubernetes (Docker Desktop)

Selain Docker Compose, stack ini juga bisa dijalankan di Kubernetes bawaan
Docker Desktop lewat manifest di `k8s/`. Prosesnya sudah diuji end-to-end:
9 Pod Running + Job migrate Completed, `http://localhost` membalas 200 dengan
halaman Laravel, MySQL 8.4.10 dengan migrasi terpasang, Redis dan cache
terhubung, seluruh proses non-root, dan Horizon/scheduler start bersih tanpa
restart (setelah initContainer `wait-for-deps` ditambahkan).

### Prasyarat

Aktifkan Kubernetes: Docker Desktop → Settings → Kubernetes → Enable, lalu:

```powershell
kubectl config use-context docker-desktop
kubectl get nodes    # docker-desktop  Ready  control-plane
```

### Langkah 1 — Build tiga image

Manifest memakai `imagePullPolicy: Never` (overlay local), jadi image **wajib**
ada di daemon Docker lokal — Docker Desktop berbagi daemon image dengan
Kubernetes-nya, jadi cukup `docker build`, tanpa push.

```powershell
# aplikasi (php-fpm) — stage "app"
docker build -f docker/php/Dockerfile --target app   -t laravel-app:latest .
# caddy — stage "caddy" (sudah membawa public/)
docker build -f docker/php/Dockerfile --target caddy -t laravel-app-caddy:latest .
# mysql — config di-bake agar tidak diabaikan karena world-writable
docker build -f docker/mysql/Dockerfile -t laravel-app-mysql:latest docker/mysql
```

> Kalau ingin nginx sebagai pengganti Caddy, build juga
> `--target web -t laravel-app-web:latest` dan sesuaikan manifest-nya.

### Langkah 2 — Siapkan rahasia

Rahasia dibuat dari file lokal yang **tidak** ikut ter-commit (`.gitignore`
sudah mengecualikan `k8s/overlays/*/secrets.env`). Kustomize menambahkan hash
isi ke nama Secret, jadi mengganti password otomatis memicu rollout pod —
bukan diam-diam tidak berlaku.

```powershell
cd k8s/overlays/local
Copy-Item secrets.env.example secrets.env
# buat APP_KEY:
docker run --rm laravel-app:latest php artisan key:generate --show
# tempel hasilnya ke APP_KEY, lalu isi DB_PASSWORD, DB_ROOT_PASSWORD,
# REDIS_PASSWORD, REDIS_CACHE_PASSWORD dengan nilai acak
cd ../../..
```

### Langkah 3 — Deploy

```powershell
kubectl apply -k k8s/overlays/local
```

Urutan boot ditangani sendiri oleh manifest: Service MySQL/Redis headless,
Job `migrate` punya initContainer `wait-for-deps` yang menunggu database +
Redis siap, dan **Horizon serta scheduler juga menunggu dependensinya**
sebelum start (mencegah crash-loop cold-start saat Redis belum ter-resolve).

Tunggu berlapis — data dulu, migrasi, lalu aplikasi (urutan ini yang dipakai
saat menguji):

```powershell
kubectl -n laravel rollout status statefulset/mysql --timeout=300s
kubectl -n laravel wait --for=condition=complete job/migrate --timeout=300s
kubectl -n laravel rollout status deployment/caddy   --timeout=240s
kubectl -n laravel rollout status deployment/app     --timeout=240s
kubectl -n laravel rollout status deployment/horizon --timeout=120s
```

Lalu periksa semua Pod:

```powershell
kubectl -n laravel get pods
```

```
NAME                          READY   STATUS      RESTARTS   AGE
app-...                       1/1     Running     0          2m
app-...                       1/1     Running     0          2m
caddy-...                     1/1     Running     0          2m
caddy-...                     1/1     Running     0          2m
horizon-...                   1/1     Running     0          2m
migrate-...                   0/1     Completed   0          2m
mysql-0                       1/1     Running     0          2m
redis-0                       1/1     Running     0          2m
redis-cache-...               1/1     Running     0          2m
scheduler-...                 1/1     Running     0          2m
```

> `horizon` sempat `0/1` selama ~20–30 detik saat pertama start — itu jeda
> readiness probe `horizon:status`, **bukan** crash (RESTARTS tetap 0). Berkat
> initContainer `wait-for-deps`, ia tidak lagi crash-loop menunggu Redis
> seperti sebelum perbaikan.

### Langkah 4 — Akses di browser

Service `caddy` bertipe `LoadBalancer`, dan Docker Desktop memetakannya ke
`localhost`. Buka:

**http://localhost**

Tidak perlu ingress controller maupun mengedit berkas hosts. Terverifikasi
saat pengujian: `caddy` mendapat `EXTERNAL-IP: localhost` dan `http://localhost`
membalas **200** dengan halaman selamat datang Laravel.

> **Port 80 hanya bisa dimiliki satu Service.** Kalau ada deployment lain yang
> sudah mengambil `localhost:80` (mis. sebuah ingress controller dari demo
> lain), Service Caddy tidak akan kebagian port itu — dan `http://localhost`
> akan menampilkan **404 milik controller itu**, bukan aplikasi Anda.
>
> Gejala nyata yang ditemui saat menguji: sebuah ingress-nginx dari deployment
> lain yang ikut memakai **namespace `laravel`** menyita port 80. Karena
> project ini juga men-deploy ke namespace `laravel`, keduanya tidak bisa
> hidup bersamaan. Yang berhasil: singkirkan deployment lain itu **seluruhnya**
> sebelum deploy project ini —
>
> ```powershell
> # hapus namespace demo lain + namespace ingress-nya (membebaskan port 80)
> kubectl delete namespace laravel ingress-nginx
> # (abaikan pesan timeout pada ingress-nginx; penghapusan tetap berjalan)
> # tunggu benar-benar hilang, lalu deploy ulang project ini:
> kubectl apply -k k8s/overlays/local
> ```
>
> Kalau Anda justru ingin **kedua** deployment tetap ada, jalankan yang kedua
> di namespace berbeda dan akses lewat port-forward (tanpa butuh port 80):
>
> ```powershell
> kubectl -n laravel port-forward svc/caddy 8080:80
> #    lalu buka http://localhost:8080
> ```

### Langkah 5 — Verifikasi

```powershell
# HTTP dari luar
curl.exe -s -o NUL -w "%{http_code}`n" http://localhost/        # 200
curl.exe -s -o NUL -w "%{http_code}`n" http://localhost/up      # 200
curl.exe -s -o NUL -w "%{http_code}`n" http://localhost/.env    # 403

# Dari dalam pod (butuh kubectl exec berfungsi)
kubectl -n laravel exec deploy/app -c php-fpm -- php artisan db:show
kubectl -n laravel exec deploy/app -c php-fpm -- php artisan migrate:status
```

> **Kalau `kubectl exec` gagal** dengan `http: server gave HTTP response to
> HTTPS client`, itu bug streaming containerd pada sebagian Docker Desktop —
> **bukan** masalah aplikasi (`kubectl logs` tetap jalan, dan HTTP sudah 200).
> Biasanya pulih setelah Docker Desktop di-restart. Sebagai alternatif,
> pemeriksaan dalam-pod bisa dijalankan lewat Job sekali-pakai yang
> hasilnya dibaca dari `kubectl logs`.

### Update image tanpa downtime

```powershell
docker build -f docker/php/Dockerfile --target app -t laravel-app:latest .
kubectl -n laravel rollout restart deployment/app deployment/caddy deployment/horizon
kubectl -n laravel rollout status deployment/app
```

### Membongkar

```powershell
kubectl delete -k k8s/overlays/local
# PVC (data MySQL/Redis) TIDAK ikut terhapus — hapus manual bila ingin bersih:
kubectl -n laravel delete pvc --all
```

> Menghapus PVC MySQL belum tentu menghapus datadir di disk (provisioner
> hostpath memetakan berdasarkan nama PVC). Untuk benar-benar mengulang dari
> nol, pakai `k8s/tools/wipe-mysql-data.yaml`.

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
