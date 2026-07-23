# 5. Laravel: Artisan, Queue, Scheduler, Health Check

## 5.1 Perintah Artisan — Kapan Dijalankan

Ini tabel terpenting di seluruh panduan. Menjalankan perintah yang benar di
waktu yang salah adalah sumber kegagalan yang paling sering dan paling sulit
didiagnosis.

| Perintah | Kapan | Di mana | Alasan |
|---|---|---|---|
| `key:generate` | **sekali per environment** | manual / `create-secret.sh` | hasilnya disimpan di Secret |
| `migrate --force` | **sekali per rilis** | Job `db-migrate` | harus tepat satu kali |
| `storage:link` | **saat build** | Dockerfile (`ln -s`) | `public/` read-only saat runtime |
| `config:cache` | **setiap Pod start** | entrypoint | butuh env yang sudah ter-inject |
| `route:cache` | setiap Pod start | entrypoint | idem |
| `view:cache` | setiap Pod start | entrypoint | idem |
| `event:cache` | setiap Pod start | entrypoint | idem |
| `optimize` | — | *(tidak dipakai)* | lihat di bawah |
| `queue:work` | terus-menerus | Deployment `laravel-queue` | proses panjang |
| `schedule:run` | tiap menit | CronJob | Laravel yang memilih tugas |

### `key:generate` — sekali seumur environment

```bash
php artisan key:generate --show
# base64:xY7k...
```

`APP_KEY` mengenkripsi sesi, cookie, dan kolom yang memakai cast
`encrypted`. **Menggantinya pada aplikasi yang sudah berjalan membuat semua
itu tidak bisa dibaca lagi** — pengguna ter-logout massal, dan data terenkripsi
di database hilang permanen.

Karena itu nilainya dibuat sekali lalu disimpan di Secret, bukan dibuat ulang
setiap deploy.

### `migrate` — kenapa Job terpisah

Dengan 3 replika php-fpm, menaruh `migrate` di entrypoint berarti tiga Pod
menjalankannya bersamaan saat rollout.

`--isolated` mengambil lock di cache store sehingga hanya satu proses yang
mengerjakan. Ini **aman di sini karena `CACHE_STORE=redis`**.

> **Jebakan nyata:** bila cache store-nya `database`, `--isolated` mengunci
> dirinya sendiri. Tabel `cache_locks` yang mau dipakai untuk mengunci justru
> baru akan **dibuat** oleh migrasi yang sedang menunggu lock itu. Prosesnya
> menggantung tanpa pesan galat yang berguna.

Aturan migrasi yang aman untuk rolling update — karena selama beberapa detik,
kode lama dan kode baru berjalan **bersamaan**:

- ✅ Tambah kolom baru sebagai `nullable`
- ✅ Tambah tabel, tambah index
- ❌ Hapus kolom di rilis yang sama dengan kode yang berhenti memakainya
- ❌ `RENAME COLUMN` (kode lama langsung rusak)

Untuk perubahan yang merusak, pecah menjadi tiga rilis: tambah kolom baru →
deploy kode yang memakai keduanya → hapus kolom lama.

### `storage:link` — dibuat saat build

```dockerfile
RUN ln -sfn ../storage/app/public public/storage
```

`php artisan storage:link` menulis symlink ke `public/`, dan `public/` berada
di root filesystem yang **read-only** di Kubernetes. Menjalankannya saat
runtime akan gagal dengan permission denied.

### `config:cache` — runtime, BUKAN build

Ini keputusan yang paling sering salah.

`config:cache` membekukan hasil seluruh `env()` ke dalam satu berkas PHP.
Bila dijalankan **saat build**, nilai yang membeku adalah nilai saat build —
password dan host dari mesin CI, bukan dari klaster. Aplikasi lalu mencoba
menghubungi database yang tidak ada.

Karena itu ia dijalankan di [entrypoint](../docker/php/entrypoint.sh),
setelah ConfigMap dan Secret ter-inject.

Efek samping yang harus disadari: **setelah `config:cache`, fungsi `env()` di
luar berkas `config/` mengembalikan `null`**. Kode aplikasi harus memakai
`config('services.foo')`, bukan `env('FOO')`. Ini penyebab klasik "jalan di
lokal, `null` di produksi".

### Kenapa `optimize` tidak dipakai

`php artisan optimize` menjalankan `config:cache` + `route:cache` sekaligus,
tetapi perintah-perintahnya dijalankan terpisah di entrypoint agar bila salah
satu gagal, log menunjukkan **yang mana**. `optimize` hanya melaporkan
kegagalan secara umum.

## 5.2 Queue Worker

Berkas: [`deployment-queue.yaml`](../kubernetes/base/deployment-queue.yaml)

### Pilihan flag dan alasannya

```yaml
command: ["php", "artisan", "queue:work", "redis"]
args:
  - --queue=high,default,low   # urutan prioritas
  - --tries=3
  - --backoff=10
  - --max-jobs=1000
  - --max-time=3600
  - --timeout=60
```

| Flag | Alasan |
|---|---|
| `--queue=high,default,low` | antrian dibaca berurutan; `high` selalu didahulukan |
| `--tries=3` | tanpa ini, job yang gagal diulang **selamanya** |
| `--max-jobs` / `--max-time` | daur ulang proses; PHP long-running pasti bocor memori sedikit demi sedikit |
| `--timeout=60` | harus **lebih kecil** daripada `terminationGracePeriodSeconds` |

### `terminationGracePeriodSeconds: 120` — nilai paling penting

`queue:work` menangkap SIGTERM, **menyelesaikan job yang sedang berjalan**,
lalu keluar. Kubernetes memberi waktu sebesar grace period sebelum mengirim
SIGKILL.

Nilainya harus lebih besar daripada job terlama Anda. Kalau tidak, SIGKILL
memotong job di tengah jalan — pekerjaannya setengah jadi, tetapi sudah
dihapus dari antrian. Ini kehilangan data yang senyap.

### `queue:work` atau Horizon?

**Horizon** memberi dashboard, metrik, dan penyeimbangan antrian otomatis.
Bila dipakai:

```yaml
command: ["php", "artisan", "horizon"]
```

Yang harus disiapkan: ekstensi `pcntl` dan `posix` (sudah ada di image kita),
gerbang akses di `HorizonServiceProvider`, dan `php artisan horizon:terminate`
pada `preStop` agar berhenti dengan rapi.

**Catatan:** Horizon dirancang mengelola proses worker-nya sendiri. Menjalankan
beberapa replika Horizon berarti beberapa supervisor yang saling tidak sadar.
Untuk Kubernetes, umumnya lebih sederhana memakai `queue:work` polos dan
menyerahkan penskalaan ke HPA — satu Pod, satu worker, dan Kubernetes yang
menghitung.

### Autoscaling worker — kenapa CPU adalah metrik yang salah

Worker yang menunggu job menganggur di ~0% CPU, padahal antriannya bisa saja
menumpuk 10.000 job. HPA berbasis CPU **tidak akan menambah worker sama
sekali**.

Yang benar adalah menskalakan berdasarkan **panjang antrian**, dan itu butuh
metrik eksternal. Cara paling langsung adalah KEDA:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: laravel-queue
  namespace: laravel
spec:
  scaleTargetRef:
    name: laravel-queue
  minReplicaCount: 1
  maxReplicaCount: 20
  cooldownPeriod: 300
  triggers:
    - type: redis
      metadata:
        address: redis.laravel.svc.cluster.local:6379
        listName: laravel:queues:default   # sesuaikan dengan REDIS_PREFIX
        listLength: "20"                   # 1 Pod per 20 job menunggu
```

KEDA bahkan bisa menurunkan ke **nol** replika saat antrian kosong — sesuatu
yang tidak bisa dilakukan HPA biasa.

HPA berbasis CPU di [`hpa.yaml`](../kubernetes/base/hpa.yaml) tetap disertakan
sebagai jaring pengaman untuk job yang memang berat CPU (pemrosesan gambar,
ekspor laporan) — bukan sebagai solusi utama.

### Menangani job yang gagal

```bash
kubectl -n laravel exec deploy/laravel-fpm -- php artisan queue:failed
kubectl -n laravel exec deploy/laravel-fpm -- php artisan queue:retry all
```

## 5.3 Scheduler

Berkas: [`cronjob-scheduler.yaml`](../kubernetes/base/cronjob-scheduler.yaml)

Di server tradisional, scheduler adalah satu baris crontab:

```
* * * * * cd /path && php artisan schedule:run >> /dev/null 2>&1
```

Di Kubernetes, CronJob-lah padanannya.

### `concurrencyPolicy: Forbid` — yang paling sering salah

Tanpa ini, tugas yang berjalan lebih dari satu menit akan ditumpuk eksekusi
berikutnya. Dua salinan tugas yang sama berjalan bersamaan hampir selalu
berarti **data ganda**: dua email terkirim, dua baris laporan, dua tagihan.

### CronJob atau Deployment `schedule:work`?

| | CronJob (dipakai di sini) | Deployment `schedule:work` |
|---|---|---|
| Jadwal dipegang | Kubernetes (terlihat di `get cronjob`) | proses PHP |
| Log per eksekusi | terpisah, bisa ditelusuri | menumpuk di satu Pod |
| Resource saat idle | nol | terus terpakai |
| Overhead | ~2–5 detik start container/menit | tidak ada |
| Kegagalan senyap | terdeteksi (`lastScheduleTime`) | sulit disadari |

CronJob dipilih karena jadwalnya menjadi bagian dari objek klaster yang bisa
diamati, bukan tersembunyi di dalam proses.

### `activeDeadlineSeconds: 55`

Sedikit di bawah interval jadwal, supaya eksekusi yang macet tidak menabrak
eksekusi berikutnya.

### `SKIP_OPTIMIZE=true` pada scheduler

`config:cache` memakan 1–3 detik. Untuk Pod yang hidup 5 detik, itu
sepertiga waktunya — dan cache-nya toh dibuang lagi tiap menit.

### Memeriksa scheduler

```bash
kubectl -n laravel get cronjob laravel-scheduler
# SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE
# * * * * *   False     0        30s

kubectl -n laravel get jobs --sort-by=.metadata.creationTimestamp | tail -5
kubectl -n laravel logs job/laravel-scheduler-29385720

# Uji satu eksekusi manual tanpa menunggu jadwal
kubectl -n laravel create job uji-sched --from=cronjob/laravel-scheduler
```

## 5.4 Health Check

### Pembagian tugas antar probe

| Probe | Pertanyaan yang dijawab | Konsekuensi kegagalan |
|---|---|---|
| `startupProbe` | "Sudah selesai booting?" | menunda dua probe lain |
| `readinessProbe` | "Siap menerima trafik?" | dicabut dari Service (**tidak dibunuh**) |
| `livenessProbe` | "Masih waras?" | container **DIBUNUH** dan di-restart |

Prinsip yang dipegang di manifest ini: **liveness lebih longgar daripada
readiness**. Readiness gagal itu murah dan reversibel; liveness gagal itu
mahal. Lonjakan beban sesaat tidak boleh memicu restart beruntun.

### Kenapa `startupProbe` wajib ada

Tanpanya, `initialDelaySeconds` pada liveness harus disetel selonggar
skenario boot terlambat. Nilai longgar itu lalu berlaku **selamanya** —
termasuk saat aplikasi benar-benar mati di tengah operasi normal.

`startupProbe` memisahkan keduanya: longgar saat boot (40 × 3 detik = 120
detik), ketat setelahnya.

### Pembagian pada Nginx — keputusan desain penting

```yaml
livenessProbe:  { httpGet: { path: /healthz } }   # TIDAK menyentuh PHP
readinessProbe: { httpGet: { path: /up } }        # melewati FastCGI ke PHP
```

`/healthz` dijawab Nginx sendiri. Yang diuji adalah "apakah proses Nginx ini
masih waras".

Kalau liveness ikut menguji PHP, matinya PHP-FPM akan ikut **membunuh seluruh
Pod Nginx** — kegagalan berantai yang tidak perlu, dan justru memperlambat
pemulihan.

`/up` melewati seluruh rantai. Bila PHP-FPM belum siap, Pod Nginx dicabut
dari Service tanpa dibunuh, dan otomatis kembali saat PHP pulih.

### Endpoint kesehatan yang lebih dalam

`/up` adalah rute bawaan Laravel 11+ yang hanya membuktikan "PHP bisa
mengeksekusi Laravel". Untuk readiness yang juga menguji dependensi, tambahkan:

```php
// src/routes/web.php
use Illuminate\Support\Facades\{DB, Redis, Route};

Route::get('/health/ready', function () {
    $cek = [];
    $sehat = true;

    try {
        DB::connection()->getPdo()->query('SELECT 1');
        $cek['database'] = 'ok';
    } catch (\Throwable $e) {
        $cek['database'] = 'gagal: ' . $e->getMessage();
        $sehat = false;
    }

    try {
        Redis::connection()->ping();
        $cek['redis'] = 'ok';
    } catch (\Throwable $e) {
        $cek['redis'] = 'gagal: ' . $e->getMessage();
        $sehat = false;
    }

    return response()->json(
        ['status' => $sehat ? 'ready' : 'not-ready', 'cek' => $cek],
        $sehat ? 200 : 503
    );
});
```

Lalu arahkan readiness ke sana lewat patch overlay:

```yaml
- target: { kind: Deployment, name: laravel-nginx }
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/readinessProbe/httpGet/path
      value: /health/ready
```

> **Peringatan.** Jangan pernah menaruh pemeriksaan dependensi di
> **liveness**. Database yang tersendat sesaat akan membuat *seluruh* Pod
> aplikasi di-restart bersamaan — badai restart yang membuat pemulihan jauh
> lebih lama daripada gangguan aslinya.

### `preStop` dan kenapa 502 muncul saat rollout

```yaml
lifecycle:
  preStop:
    exec: { command: ["sh", "-c", "sleep 5"] }
```

Saat Pod dihapus, dua hal terjadi **bersamaan dan tidak berurutan**:
Pod dicabut dari EndpointSlice, dan container menerima SIGTERM.

Karena kube-proxy di setiap Node butuh waktu memperbarui aturannya, sebagian
request masih dikirim ke Pod yang sudah mulai mati → **502**.

`sleep 5` pada `preStop` menunda SIGTERM, memberi waktu propagasi selesai
lebih dulu. Lima detik cukup untuk sebagian besar klaster.

---

Berikutnya: [06-resource-security.md](06-resource-security.md)
