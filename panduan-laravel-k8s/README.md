# Laravel di Kubernetes — Panduan End-to-End yang Portabel

Panduan lengkap men-deploy Laravel (PHP-FPM + Nginx + MariaDB + Redis) ke dua
lingkungan **dengan manifest yang sama**:

1. **Kubernetes bawaan Docker Desktop** — pengembangan
2. **Klaster kubeadm on-premise** — control plane `192.168.50.14`, worker
   `192.168.50.15` / `.16` / `.17`

Perbedaan antar keduanya ditekan menjadi **empat sampai enam baris** di
overlay Kustomize. Tidak ada satu pun manifest yang diduplikasi.

## Isi

| # | Dokumen | Membahas |
|---|---|---|
| 1 | [Arsitektur & Struktur](docs/01-arsitektur.md) | diagram Mermaid, fungsi komponen, MariaDB vs MySQL, struktur direktori |
| 2 | [Docker & Compose](docs/02-docker.md) | multi-stage build, OPcache, non-root, stack pengembangan |
| 3 | [Manifest & Kustomize](docs/03-kubernetes-manifest.md) | 22 manifest, base/overlay, penyimpangan yang disengaja |
| 4 | [Storage, Ingress, MetalLB](docs/04-storage-jaringan.md) | PV/PVC/StorageClass, NFS vs Local PV, kolam IP |
| 5 | [Laravel Operasional](docs/05-laravel-operasional.md) | artisan, queue, scheduler, health check |
| 6 | [Resource & Keamanan](docs/06-resource-security.md) | requests/limits, PSA, RBAC, NetworkPolicy, Secret |
| 7 | [CI/CD & Monitoring](docs/07-cicd-monitoring.md) | GitHub Actions, Prometheus, Grafana, Loki |
| 8 | [Deployment](docs/08-deployment.md) | langkah lengkap kedua environment, rolling update, rollback |
| 9 | [Troubleshooting](docs/09-troubleshooting.md) | 11 masalah umum, penyebab, dan solusinya |
| 10 | [Verifikasi](docs/10-verifikasi.md) | daftar periksa lengkap |
| 11 | [Deploy On-Prem Lab](docs/11-deploy-onprem-lab.md) | langkah demi langkah ke klaster kubeadm 192.168.50.x, tanpa registry (overlay `onprem-lab`) |
| 12 | [Walkthrough Docker Desktop](docs/12-walkthrough-docker-desktop.md) | narasi run nyata sampai 24/24 lulus — 3 kegagalan yang benar-benar muncul dan cara mengatasinya |

## Quickstart — Docker Desktop

```bash
# 0. Prasyarat: Docker Desktop dengan Kubernetes aktif, minimal 4 CPU / 8 GB
kubectl config use-context docker-desktop

# 1. Ingress Controller (sekali per klaster)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

# 2. Kode Laravel
composer create-project laravel/laravel src

# 3. Deploy
./scripts/deploy.sh docker-desktop          # atau: .\scripts\deploy.ps1

# 4. Buka
open http://laravel.localhost
```

## Quickstart — On-Premise

```bash
# Fondasi klaster (sekali saja) — lihat docs/08 untuk rinciannya
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl apply -f infra/metallb-config.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml

# Deploy aplikasi
./scripts/deploy.sh onprem ghcr.io/organisasi v1.0.0

# Buka
curl -I http://laravel.192.168.50.200.nip.io
```

## Cara Manifest Ini Tetap Portabel

Semua perbedaan didorong ke overlay Kustomize. Base tidak pernah berisi IP,
hostname, nama StorageClass, atau tag image sungguhan.

| Aspek | docker-desktop | onprem |
|---|---|---|
| StorageClass unggahan | `hostpath` | `nfs-client` |
| StorageClass database | `hostpath` | `local-path` |
| Host Ingress | `laravel.localhost` | `laravel.192.168.50.200.nip.io` |
| Image | `laravel-app/php:dev` | `ghcr.io/ORG/laravel-php:v1.0.0` |
| Replika (fpm/nginx/queue) | 1 / 1 / 1 | 3 / 3 / 2 |
| HPA & PDB | dihapus | aktif |
| `topologySpread` | `ScheduleAnyway` | `DoNotSchedule` |

Semua yang lain — nama Service, struktur Deployment, probe, `securityContext`,
NetworkPolicy — **identik**. Yang Anda uji di laptop adalah objek yang sama
dengan yang berjalan di on-premise.

Tiga teknik yang membuatnya bekerja:

1. **Nama Service, bukan IP.** `DB_HOST=mariadb` benar di Docker Compose,
   Docker Desktop, dan kubeadm.
2. **`storageClassName` dikosongkan di base**, diisi overlay.
3. **Semua Service ClusterIP.** Perbedaan cara mengekspos ke luar dipusatkan
   di satu tempat: Ingress Controller.

## Verifikasi yang Sudah Dilakukan

Panduan ini sudah **dijalankan end-to-end dengan aplikasi Laravel 13.8
sungguhan** di Kubernetes Docker Desktop (v1.36):

- Kedua overlay ter-render tanpa galat; tidak ada API deprecated; seluruh
  Pod lolos admission Pod Security `restricted`
- `./scripts/verify.sh` **24/24 lulus**: halaman utama dan `/up` 200 lewat
  Ingress, database + migrasi + Redis + cache berfungsi, storage RWX bisa
  ditulis, rootfs read-only, `.env` 403, aset statis dilayani image Nginx
  dengan `Cache-Control: immutable`
- Antrian dibuktikan lintas-Pod: job `App\Jobs\UjiE2e` di-dispatch dari
  satu Pod dan diproses worker di Pod lain (penanda muncul di log worker)
- Rolling update diuji dengan loop curl selama rollout: **120/120 respons
  200** — nol downtime, bahkan pada satu replika

Tiga bug ditemukan justru **karena** dijalankan sungguhan (dry-run
melewatkannya, karena LimitRange divalidasi saat Pod dibuat):

1. `maxLimitRequestRatio.cpu: 4` menolak semua workload burstable → 10.
2. Default LimitRange (`512Mi`/`128Mi` = rasio 4) melanggar rasionya
   sendiri (2) → default diturunkan ke `256Mi`.
3. `secret.yaml` yang ikut terdaftar di kustomization membuat setiap
   `apply -k` menimpa Secret asli dengan placeholder — dan MariaDB terlanjur
   menyimpan password placeholder di datadir → `secret.yaml` dikeluarkan
   dari kustomization, database di-reset.

Belum diverifikasi: klaster kubeadm on-premise sungguhan (butuh perangkat
kerasnya), dan penegakan NetworkPolicy (CNI Docker Desktop tidak
menegakkannya — lihat Catatan Penting).

## Ringkasan Keputusan Arsitektur

| Keputusan | Pilihan | Alasan singkat |
|---|---|---|
| Database | **MariaDB 11.4** | driver Laravel tersendiri, image lebih ramping, `healthcheck.sh` yang benar |
| Database sebagai | **StatefulSet** | Deployment + RWO berisiko dua Pod menulis satu datadir |
| Redis | **dua instance** | kebijakan eviction per-server: `noeviction` untuk antrian, `allkeys-lru` untuk cache |
| Nginx | **Deployment terpisah** | penskalaan mandiri; alternatif sidecar didokumentasikan |
| Storage unggahan | **NFS (RWX)** | Pod tersebar di 3 worker harus melihat berkas yang sama |
| Storage database | **Local Path (RWO)** | InnoDB di atas NFS membuat kinerja tulis anjlok |
| Migrasi | **Job terpisah** | dengan 3 replika, entrypoint akan menjalankannya tiga kali |
| Scheduler | **CronJob** | jadwalnya menjadi objek klaster yang bisa diamati |
| `config:cache` | **runtime** | saat build, nilai `env()` membeku pada nilai mesin CI |
| LoadBalancer | **MetalLB L2** | tanpa penyedia cloud, `EXTERNAL-IP` akan `<pending>` selamanya |

## Catatan Penting

**Ingress-NGINX sedang dipensiunkan.** Proyek komunitasnya telah menghentikan
pengembangan fitur baru; penerusnya diarahkan ke Gateway API (v1.6 GA) atau
proyek InGate. Panduan ini tetap memakai Ingress-NGINX sesuai permintaan dan
mem-pin instalasinya ke rilis tertentu, tetapi **periksa status terkini
proyeknya** sebelum memakainya untuk klaster produksi baru. Contoh HTTPRoute
Gateway API ada di [docs/04](docs/04-storage-jaringan.md).

**NetworkPolicy tidak ditegakkan di Docker Desktop.** Objeknya tersimpan dan
terlihat di `kubectl get netpol`, tetapi CNI bawaannya mengabaikannya. Jangan
memvalidasi kebijakan jaringan di sana lalu menganggapnya terbukti — uji di
klaster kubeadm dengan Calico atau Cilium.

**Rentang IP MetalLB harus dikeluarkan dari kolam DHCP router.** Kolam
`192.168.50.200-240` sengaja menghindari IP node (`.14`–`.17`), tetapi bila
router masih boleh membagikannya ke perangkat lain, suatu hari akan terjadi
bentrok IP yang gejalanya sangat sulit didiagnosis.

## Perintah Sehari-hari

```bash
./scripts/deploy.sh docker-desktop     # build + deploy
./scripts/verify.sh                    # daftar periksa lengkap
./scripts/logs.sh fpm                  # ikuti log satu komponen
./scripts/rollback.sh                  # kembali ke revisi sebelumnya
./scripts/reset-database.sh            # hapus data database, mulai dari nol

kubectl -n laravel get pods -w
kubectl -n laravel exec deploy/laravel-fpm -c php-fpm -- php artisan about
kubectl diff -k kubernetes/overlays/onprem
```
