# Deploy ke Kubernetes (Docker Desktop)

Manifest Kustomize untuk stack Laravel 13 + MySQL + Redis + Caddy, disusun
dengan Pod Security `restricted` sebagai syarat, bukan sebagai tambahan.

## Struktur

```
k8s/
├── base/
│   ├── namespace.yaml          # Pod Security Admission: restricted
│   ├── serviceaccounts.yaml    # satu SA per workload, tanpa token
│   ├── app-config.env          # konfigurasi non-rahasia  -> configMapGenerator
│   ├── redis.conf              # queue+session: noeviction
│   ├── redis-cache.conf        # cache: allkeys-lru
│   ├── storage.yaml            # PVC RWX untuk upload
│   ├── mysql.yaml              # StatefulSet + headless Service
│   ├── redis.yaml              # dua instance Redis
│   ├── app.yaml                # php-fpm + Service + PDB
│   ├── caddy.yaml              # web + LoadBalancer + PDB
│   ├── workers.yaml            # horizon + scheduler
│   ├── migrate-job.yaml        # migrasi sebagai Job
│   └── networkpolicies.yaml    # default deny + izin eksplisit
├── overlays/local/
│   ├── kustomization.yaml
│   ├── secrets.env             # TIDAK di-commit
│   └── secrets.env.example
└── tools/
    └── wipe-mysql-data.yaml    # lihat "Jebakan Docker Desktop"
```

## Deploy

```powershell
# 1. Build image (Kubernetes Docker Desktop memakai daemon Docker yang sama)
docker compose -f compose.yaml --profile caddy build app caddy mysql

# 2. Siapkan rahasia
copy k8s\overlays\local\secrets.env.example k8s\overlays\local\secrets.env
#    isi APP_KEY, DB_PASSWORD, DB_ROOT_PASSWORD, REDIS_PASSWORD, REDIS_CACHE_PASSWORD

# 3. Apply
kubectl apply -k k8s/overlays/local

# 4. Tunggu siap
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=app -n laravel --timeout=300s
```

Buka <http://localhost> — Docker Desktop memetakan Service `LoadBalancer` ke
localhost, jadi tidak perlu memasang ingress controller.

Deploy ulang setelah mengubah kode:

```powershell
docker compose -f compose.yaml --profile caddy build app caddy
kubectl rollout restart deployment/app deployment/caddy deployment/horizon deployment/scheduler -n laravel
```

## Perintah sehari-hari

| Keperluan          | Perintah                                                            |
| ------------------ | ------------------------------------------------------------------- |
| Status             | `kubectl get pods -n laravel`                                        |
| Log aplikasi       | `kubectl logs -f -l app.kubernetes.io/name=app -n laravel`           |
| Log queue          | `kubectl logs -f -l app.kubernetes.io/name=horizon -n laravel`       |
| Artisan            | `kubectl exec -n laravel deploy/app -- php artisan migrate:status`   |
| Tinker             | `kubectl exec -it -n laravel deploy/app -- php artisan tinker`       |
| Migrasi ulang      | naikkan anotasi `revision` di `migrate-job.yaml`, lalu apply         |
| Hapus semua        | `kubectl delete -k k8s/overlays/local` (baca peringatan di bawah)    |

## Keputusan keamanan

Semua sudah diuji di cluster ini, bukan sekadar ditulis di manifest.

**Pod Security `restricted`, ditegakkan.** Terbukti:

```
$ kubectl run uji -n laravel --image=busybox --restart=Never -- sleep 30
Error from server (Forbidden): pods "uji" is forbidden: violates PodSecurity
"restricted:latest": allowPrivilegeEscalation != false, unrestricted
capabilities, runAsNonRoot != true, seccompProfile ...
```

**Semua container non-root, tanpa kecuali.** Termasuk php-fpm, yang normalnya
menjalankan proses master sebagai root untuk bisa menurunkan hak worker-nya.
Di sini seluruh proses berjalan sebagai uid 82 sejak awal.

**`readOnlyRootFilesystem: true` di semua container.** Yang benar-benar perlu
ditulis dipasang eksplisit: `storage` (PVC), `bootstrap/cache`, `/tmp`, dan
untuk MySQL `/var/run/mysqld`.

**Seluruh capability di-drop, `allowPrivilegeEscalation: false`.**

**Token ServiceAccount tidak dipasang.** Aplikasi ini tidak perlu bicara dengan
API Kubernetes, jadi container yang berhasil dikompromikan tidak punya
kredensial apa pun untuk bergerak lebih jauh.

**Password tidak pernah muncul di command line.** Redis dikonfigurasi lewat file
yang dirakit initContainer dari Secret; probe MySQL dan Redis memakai variabel
environment (`MYSQL_PWD` di dalam perintah probe, `REDISCLI_AUTH`), bukan
argumen `-p`/`-a` yang terlihat di `ps`.

**Rahasia tidak ada di repo.** Secret dibuat `secretGenerator` dari
`secrets.env` yang di-gitignore. Namanya ber-hash, sehingga mengganti password
otomatis memicu rollout — bukan diam-diam tidak berlaku.

**Probe menguji fungsi, bukan sekadar port.** php-fpm diuji lewat protokol
FastCGI, MySQL lewat query terautentikasi sebagai user aplikasi, Caddy lewat
`/up` yang menembus sampai PHP.

### NetworkPolicy: ADA, tapi TIDAK ditegakkan di sini

Manifest-nya lengkap (default deny ingress+egress, lalu izin eksplisit per
jalur). Tapi CNI bawaan Docker Desktop tidak mengimplementasikan NetworkPolicy.
Diuji langsung dengan pod tanpa label yang diizinkan:

```
mysql:3306  -> TERHUBUNG (policy TIDAK ditegakkan)
redis:6379  -> TERHUBUNG (policy TIDAK ditegakkan)
```

Jadi di Docker Desktop, **setiap pod di cluster bisa membuka MySQL dan Redis
secara langsung**. Manifest-nya tetap disertakan supaya benar begitu dipindah ke
cluster ber-CNI yang mendukung (Calico, Cilium, GKE Dataplane V2). Verifikasi
ulang di cluster tujuan dengan cara yang sama sebelum menganggapnya aktif.

## Jebakan Docker Desktop

**Menghapus PVC tidak menghapus datanya.** Provisioner hostpath memetakan volume
berdasarkan NAMA PVC. Menghapus PVC — bahkan sampai PV-nya hilang — meninggalkan
isi direktori di host apa adanya, dan PVC baru bernama sama akan menemukannya
kembali.

Ini berbahaya khusus untuk MySQL: kalau inisialisasi pernah terputus di tengah,
datadir berisi tabel sistem tapi tanpa user aplikasi. MySQL akan start normal
selamanya (entrypoint resminya melewati inisialisasi karena datadir tidak
kosong) sementara aplikasi ditolak dengan pesan yang menyesatkan:

```
SQLSTATE[HY000] [1130] Host '10.1.0.187' is not allowed to connect
```

`kubectl delete pvc` TIDAK memperbaikinya. Datadir harus dikosongkan eksplisit —
gunakan `k8s/tools/wipe-mysql-data.yaml`, langkahnya ada di dalam file itu.

**`kubectl delete -k` tidak menghapus PVC dari StatefulSet.** `volumeClaimTemplates`
sengaja meninggalkan PVC-nya. Untuk benar-benar bersih:

```powershell
kubectl delete -k k8s/overlays/local
kubectl delete pvc --all -n laravel
```

Dan ingat: karena jebakan di atas, itu pun belum tentu menghapus datanya.

## Yang berbeda dari cluster produksi sungguhan

- **Storage RWX.** PVC `app-storage` bisa RWX di sini hanya karena cluster-nya
  satu node. Di multi-node, hostpath tidak akan bekerja — pakai object storage
  (driver `s3` Laravel) atau CSI yang benar-benar mendukung RWX.
- **TLS.** Service `LoadBalancer` ini melayani HTTP polos. Di cloud, ganti ke
  `ClusterIP` + Ingress dengan cert-manager, lalu set `SESSION_SECURE_COOKIE=true`.
- **MySQL satu replika, tanpa backup.** Cukup untuk lokal. Untuk produksi pakai
  database terkelola atau operator (Percona, Vitess), dan siapkan backup.
- **Secret masih Secret biasa** — hanya base64, bukan enkripsi. Untuk produksi
  aktifkan encryption-at-rest di etcd, atau pakai External Secrets Operator /
  Sealed Secrets.
- **Tidak ada HPA, resource metrics, atau monitoring.**
- **`/register` terbuka untuk publik** — bawaan starter kit Breeze. Siapa pun
  yang bisa menjangkau Service ini dapat membuat akun. Akun biasa TIDAK bisa
  membuka `/horizon` (gate memeriksa `HORIZON_ALLOWED_EMAILS`, sudah diuji),
  tapi tetap mendapat `/dashboard`. Untuk deployment tanpa pendaftaran umum,
  hapus dua route `register` di `src/routes/auth.php`.
- **Verifikasi email tidak berfungsi** selama `MAIL_MAILER=log`.

## Akun dan akses Horizon

`HORIZON_ALLOWED_EMAILS` berisi `rustan@inixindobdg.co.id`, dan user dengan email
itu sudah ada di database (id=1). Set password-nya:

```powershell
kubectl exec -n laravel deploy/app -- php artisan tinker --execute="App\Models\User::where('email','rustan@inixindobdg.co.id')->update(['password'=>Hash::make('PASSWORD-BARU')]);"
```

Lalu login di <http://localhost/login> dan buka <http://localhost/horizon>.

Alur ini sudah diuji end-to-end di cluster: login berhasil, `/dashboard` 200,
`/horizon` 200, `/horizon/api/stats` 200. User kedua dengan email berbeda
mendapat `/dashboard` 200 tetapi `/horizon` 403.
