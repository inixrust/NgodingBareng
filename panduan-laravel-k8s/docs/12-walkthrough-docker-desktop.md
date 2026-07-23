# 12. Walkthrough Nyata: Deploy di Docker Desktop sampai Berhasil

[Bagian 8.1](08-deployment.md) memberi jalur ideal (happy path). Dokumen ini
berbeda: ia menarasikan **run yang sesungguhnya** — setiap perintah, keluaran
nyatanya, **tiga kegagalan yang benar-benar muncul**, dan bagaimana
masing-masing dipecahkan sampai `verify.sh` melaporkan **24/24 lulus** dan
aplikasi terbuka di browser.

Kenapa dokumen terpisah? Karena bug-bug ini **lolos `--dry-run=server`** —
mereka baru muncul ketika Pod benar-benar dibuat. Membaca ini lebih dulu
menghemat waktu Anda: ketiga perbaikannya sudah dipermanenkan di manifest
repo, jadi run baru Anda **tidak akan** menabraknya. Bagian ini menjelaskan
*kenapa* manifest berbentuk seperti sekarang.

> **Lingkungan run ini:** Docker Desktop, Kubernetes v1.36.1, Laravel 13.8,
> Windows + Git Bash. Semua perintah dari direktori `panduan-laravel-k8s/`.

---

## Langkah 0 — Prasyarat

```bash
kubectl config current-context      # harus: docker-desktop
kubectl get nodes
```
```
NAME             STATUS   ROLES           AGE   VERSION
docker-desktop   Ready    control-plane   47h   v1.36.1
```

Docker Desktop → Settings → Resources: minimal **4 CPU / 8 GB**. Stack ini
menjalankan 8 Pod (php-fpm, nginx, queue, scheduler, 2 redis, mariadb,
redis-cache) — kurang dari itu, MariaDB dan Pod aplikasi berebut memori.

## Langkah 1 — Kode Laravel + lock file

```bash
composer create-project laravel/laravel src   # bila belum ada
```

Satu langkah yang mudah terlewat: **`package-lock.json`**. `composer
create-project` tidak menjalankan `npm install`, jadi lock file npm belum
ada — padahal Dockerfile stage `assets` memakai `npm ci` yang **mensyaratkan**
lock file. Buat tanpa memasang apa pun:

```bash
cd src && npm install --package-lock-only && cd ..
```

Lalu satu penyesuaian aplikasi supaya Laravel mempercayai header dari Ingress
(tanpa ini, `url()` menghasilkan `http://` di situs `https://`, dan
`request()->ip()` memberi IP Pod, bukan IP pengunjung). Di
`src/bootstrap/app.php`, dalam `withMiddleware`:

```php
$middleware->trustProxies(
    at: env('TRUSTED_PROXIES', '*'),
    headers: Request::HEADER_X_FORWARDED_FOR
           | Request::HEADER_X_FORWARDED_HOST
           | Request::HEADER_X_FORWARDED_PORT
           | Request::HEADER_X_FORWARDED_PROTO,
);
```

## Langkah 2 — Build dua image

```bash
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:dev   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:dev .
docker images | grep laravel-app
```
```
laravel-app/nginx   dev   ...   74.1MB
laravel-app/php     dev   ...   279MB
```

Tidak perlu `docker push` maupun `kind load` — Docker Desktop berbagi daemon
image dengan Kubernetes-nya. Tag `dev` (bukan `latest`) karena `latest`
memicu `imagePullPolicy: Always` implisit → Kubernetes mencari di Docker Hub
→ `ImagePullBackOff` walau image ada di lokal.

## Langkah 3 — Ingress Controller (sekali per klaster)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s
kubectl -n ingress-nginx get svc ingress-nginx-controller
```
```
NAME                       TYPE           EXTERNAL-IP   PORT(S)
ingress-nginx-controller   LoadBalancer   localhost     80:30780/TCP,443:32455/TCP
```

`EXTERNAL-IP: localhost` — Docker Desktop memenuhi Service LoadBalancer dengan
memetakannya ke `localhost` mesin Anda. Itulah yang membuat
`http://laravel.localhost` nanti bisa dibuka tanpa mengedit berkas hosts.

## Langkah 4 — Namespace + Secret

```bash
kubectl apply -f kubernetes/base/namespace.yaml
bash scripts/create-secret.sh
```
```
secret/laravel-secret created
laravel-secret dibuat di namespace laravel
salinan untuk Docker Compose ditulis ke .env.local
```

`create-secret.sh` membuat `APP_KEY` dan password database **acak** langsung
di klaster — tidak ada rahasia yang menyentuh Git.

## Langkah 5 — Deploy, dan KEGAGALAN PERTAMA

```bash
kubectl apply -k kubernetes/overlays/docker-desktop
```

Apply-nya sukses (semua objek "created"). Tapi beberapa menit kemudian:

```bash
kubectl -n laravel get pods
# No resources found in laravel namespace.     <- kosong! tidak ada Pod sama sekali
```

Objeknya ada (StatefulSet, Deployment), tapi **tidak satu Pod pun dibuat**.
Selalu periksa Events saat Pod hilang tanpa jejak:

```bash
kubectl -n laravel get events --sort-by=.lastTimestamp | tail -5
```
```
Warning  FailedCreate  statefulset/mariadb  Error creating: pods "mariadb-0" is
  forbidden: cpu max limit to request ratio per Container is 4, but provided
  ratio is 10.000000
```

### Bug #1 — `maxLimitRequestRatio` menolak seluruh workload

**Penyebabnya:** [`limitrange.yaml`](../kubernetes/base/limitrange.yaml)
membatasi rasio limit-terhadap-request CPU maksimal **4**. Tapi stack ini
**sengaja burstable** pada CPU — misalnya queue `requests.cpu: 100m` dengan
`limits.cpu: 1000m` = rasio **10**. LimitRange menolak setiap Pod semacam itu
**saat pembuatan Pod**, bukan saat apply — itulah kenapa `--dry-run` lolos
tapi klaster nyata gagal.

CPU bersifat *compressible* (melampaui limit = throttle, bukan mati), jadi
membiarkan Pod memakai CPU menganggur tidak berbahaya. Naikkan rasionya ke
10:

```yaml
# kubernetes/base/limitrange.yaml
maxLimitRequestRatio:
  cpu: "10"      # dulu 4
  memory: "2"
```

```bash
kubectl apply -k kubernetes/overlays/docker-desktop
kubectl -n laravel rollout status statefulset/mariadb --timeout=300s
```

Kali ini Pod terbuat dan MariaDB mulai jalan. Lanjut.

## Langkah 6 — Migrasi jalan, tapi aplikasi 500: KEGAGALAN KEDUA

```bash
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=300s
# job.batch/db-migrate condition met         <- migrasi sukses

curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/up
# 200                                        <- rute statik Laravel: OK
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/
# 500                                        <- halaman utama: ERROR
```

`/up` (rute kesehatan bawaan, tak menyentuh enkripsi) menjawab 200, tapi `/`
gagal 500. Baca log php-fpm:

```bash
kubectl -n laravel logs deploy/laravel-fpm -c php-fpm --tail=30 | grep -i error
```
```
Unsupported cipher or incorrect key length. Supported ciphers are: aes-128-cbc,
aes-256-cbc, aes-128-gcm, aes-256-gcm.
```

`APP_KEY` tidak valid. Periksa isinya:

```bash
kubectl -n laravel get secret laravel-secret -o jsonpath='{.data.APP_KEY}' | base64 -d
# base64:GANTI-DENGAN-HASIL-openssl-rand-base64-32      <- ini PLACEHOLDER!
```

Padahal Langkah 4 jelas membuat `APP_KEY` acak. Kenapa jadi placeholder?

### Bug #2 — `secret.yaml` menimpa Secret asli dengan placeholder

**Penyebabnya:** [`secret.yaml`](../kubernetes/base/secret.yaml) (berkas contoh
struktur berisi placeholder) terdaftar di `kustomization.yaml`. Setiap
`kubectl apply -k` di Langkah 5 **menimpa** Secret acak yang dibuat
`create-secret.sh` dengan placeholder dari berkas itu.

Lebih buruk: MariaDB sudah terlanjur inisialisasi memakai password placeholder
dan **menyimpannya permanen di datadir** — `MARIADB_PASSWORD` hanya berlaku
sekali, saat init pertama. Jadi memperbaiki Secret saja tidak cukup; database
harus di-reset.

Keluarkan `secret.yaml` dari kustomization:

```yaml
# kubernetes/base/kustomization.yaml
resources:
  - configmap.yaml
  # secret.yaml SENGAJA TIDAK didaftarkan — Secret asli dibuat create-secret.sh,
  # apply -k tidak boleh menimpanya dengan placeholder.
```

Lalu buat ulang Secret + reset database + apply ulang:

```bash
bash scripts/create-secret.sh                         # Secret acak, kali ini tak tertimpa
kubectl -n laravel delete statefulset mariadb
kubectl -n laravel wait --for=delete pod/mariadb-0 --timeout=120s
kubectl -n laravel delete pvc data-mariadb-0          # buang datadir password lama
kubectl -n laravel delete job db-migrate --ignore-not-found
kubectl apply -k kubernetes/overlays/docker-desktop

# verifikasi APP_KEY sekarang nyata:
kubectl -n laravel get secret laravel-secret -o jsonpath='{.data.APP_KEY}' | base64 -d | cut -c1-12
# base64:9S2Oz...                                     <- acak, bukan placeholder
```

Tunggu database fresh + migrasi, lalu restart Pod aplikasi supaya membaca
APP_KEY & password baru:

```bash
kubectl -n laravel rollout status statefulset/mariadb --timeout=300s
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=300s
for d in laravel-fpm laravel-queue; do kubectl -n laravel rollout restart deployment/$d; done
kubectl -n laravel rollout status deployment/laravel-fpm --timeout=300s
```

Uji lagi:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/.env   # 403
```

Halaman utama **200**. Aplikasi hidup.

## Langkah 7 — Verifikasi, dan KEGAGALAN KETIGA (bukan bug aplikasi)

```bash
bash scripts/verify.sh
```

Sebagian besar lulus, tapi seluruh bagian "5. Aplikasi" gagal dengan pesan
identik:

```
[GAGAL] Koneksi database berhasil
        error: ... Post "//[::]:39143/cri/exec/...": http: server gave HTTP
        response to HTTPS client
```

### Ini masalah INFRASTRUKTUR, bukan aplikasi

Pesan `http: server gave HTTP response to HTTPS client` pada endpoint
`/cri/exec/` berarti **`kubectl exec` rusak di level containerd streaming** —
bug yang kadang muncul di Docker Desktop tertentu. Buktinya aplikasi
sebenarnya sehat: `kubectl logs` tetap jalan normal, dan HTTP sudah 200.

```bash
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-fpm -o name | head -1)
kubectl -n laravel exec $POD -c php-fpm -- id
# error: ... http: server gave HTTP response to HTTPS client   <- exec memang rusak
kubectl -n laravel logs $POD -c php-fpm --tail=1
# (keluar normal)                                              <- logs sehat
```

Karena `verify.sh` mengandalkan `exec` untuk pemeriksaan dalam-Pod, saya
menambahkan **fallback**: bila `exec` terdeteksi rusak, skrip menjalankan
pemeriksaan yang sama lewat **Job** ([`uji-dalam-job.yaml`](../scripts/uji-dalam-job.yaml))
dan membaca hasilnya dari **log** (yang tidak terpengaruh). Ini sudah
tertanam di `verify.sh` sekarang, jadi Anda tak perlu melakukan apa pun —
skrip mendeteksi dan beralih sendiri.

> **Solusi permanennya** biasanya restart Docker Desktop (Quit → buka lagi),
> yang mereset containerd streaming. Setelah itu `exec` normal dan `verify.sh`
> memakai jalur langsung.

Jalankan lagi:

```bash
bash scripts/verify.sh
```
```
5. Aplikasi (exec rusak — memakai fallback Job uji-dalam)
  [ OK ] storage/app/public bisa ditulis
  [ OK ] bootstrap/cache bisa ditulis
  [ OK ] Koneksi database berhasil
  [ OK ] Migrasi sudah dijalankan semua
  [ OK ] Koneksi Redis berhasil
  [ OK ] Cache Laravel berfungsi
  [ OK ] Root filesystem read-only
...
HASIL: 24 lulus, 0 gagal
```

## Langkah 8 — Bukti end-to-end

**Halaman di browser:**

```bash
curl -s http://laravel.localhost/ | grep -o '<title>[^<]*</title>'
# <title>Laravel</title>
```
Buka **http://laravel.localhost** — halaman selamat datang Laravel muncul.

**Antrian lintas-Pod** (job di-dispatch dari satu Pod, diproses worker di Pod
lain). Ini perlu job class sungguhan — closure dari `tinker` tidak bisa
di-unserialize di proses lain. Repo sudah punya
[`src/app/Jobs/UjiE2e.php`](../src/app/Jobs/UjiE2e.php):

```bash
# dispatch lewat Job sekali-pakai, lalu cek log worker
kubectl -n laravel logs deploy/laravel-queue --tail=15 | grep UjiE2e
```
```
2026-... App\Jobs\UjiE2e ... RUNNING
{"message":"JOB-E2E-BERJALAN","context":{"pod":"laravel-queue-...-rfrfp"},...}
2026-... App\Jobs\UjiE2e ... 5.07ms DONE
```
Penanda muncul di log worker dengan nama Pod-nya — antrian benar-benar
diproses lintas-Pod.

**Rolling update tanpa downtime** — loop curl selama rollout image baru:

```bash
# terminal 1: pantau tanpa henti
while true; do curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/up; sleep 0.5; done
# terminal 2:
kubectl -n laravel rollout restart deployment/laravel-fpm deployment/laravel-nginx
```
Seluruh 120 respons **200** — nol downtime, bahkan pada satu replika (berkat
`maxUnavailable: 0` + `preStop sleep` + readinessProbe).

---

## Ringkasan: Tiga Kegagalan dan Statusnya

| # | Gejala | Akar penyebab | Perbaikan (sudah permanen di repo) |
|---|--------|---------------|-----------------------------------|
| 1 | Nol Pod dibuat; `FailedCreate ... ratio is 10` | `maxLimitRequestRatio.cpu: 4` menolak workload burstable | dinaikkan ke `10` di `limitrange.yaml` |
| 2 | `/` 500, "Unsupported cipher"; APP_KEY = placeholder | `secret.yaml` di kustomization menimpa Secret asli; MariaDB simpan password lama di datadir | `secret.yaml` dikeluarkan dari kustomization; database di-reset |
| 3 | `verify.sh` gagal, `http: server gave HTTP response...` | `kubectl exec` rusak (containerd streaming), BUKAN bug aplikasi | fallback Job di `verify.sh`; restart Docker Desktop untuk pulih |

Bonus temuan (bukan kegagalan deploy): `laravel-queue` menunjukkan RESTARTS
tinggi. Itu **normal** — exit 0 tiap jam karena `--max-time=3600` mendaur
ulang worker mencegah kebocoran memori. `verify.sh` kini memeriksa
`lastState.reason` (OOMKilled/Error), bukan angka restart mentah.

## Kalau Mulai dari Nol Sekarang

Karena ketiga perbaikan sudah permanen, run baru Anda seharusnya lurus:

```bash
cd src && npm install --package-lock-only && cd ..
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:dev   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:dev .
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s
kubectl apply -f kubernetes/base/namespace.yaml
bash scripts/create-secret.sh
kubectl apply -k kubernetes/overlays/docker-desktop
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=300s
kubectl -n laravel rollout status deployment/laravel-fpm --timeout=300s
bash scripts/verify.sh
# buka http://laravel.localhost
```

Atau cukup: `./scripts/deploy.sh docker-desktop` lalu `./scripts/verify.sh`.
