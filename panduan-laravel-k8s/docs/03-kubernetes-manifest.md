# 3. Manifest Kubernetes & Kustomize

Setiap manifest sudah berisi penjelasan sebagai komentar. Bab ini membahas
hal yang tidak muat di sana: keputusan lintas berkas, penyimpangan dari
daftar standar, dan cara kerja Kustomize.

## 3.1 Daftar Manifest

| Berkas | Isi | Catatan |
|---|---|---|
| [`namespace.yaml`](../kubernetes/base/namespace.yaml) | Namespace + label PSA | `enforce: restricted` |
| [`serviceaccount.yaml`](../kubernetes/base/serviceaccount.yaml) | 2 ServiceAccount | aplikasi tanpa token sama sekali |
| [`role.yaml`](../kubernetes/base/role.yaml) | Role baca-saja | tanpa akses `secrets` |
| [`rolebinding.yaml`](../kubernetes/base/rolebinding.yaml) | Penaut Role | hanya untuk SA `laravel-ops` |
| [`configmap.yaml`](../kubernetes/base/configmap.yaml) | Konfigurasi non-rahasia | semua host = nama Service |
| [`secret.yaml`](../kubernetes/base/secret.yaml) | Struktur rahasia | **placeholder**, bukan nilai asli |
| [`pvc.yaml`](../kubernetes/base/pvc.yaml) | Unggahan pengguna | **ReadWriteMany** |
| [`statefulset-mariadb.yaml`](../kubernetes/base/statefulset-mariadb.yaml) | Database | *bukan* Deployment — lihat 3.2 |
| [`statefulset-redis.yaml`](../kubernetes/base/statefulset-redis.yaml) | Redis antrian/sesi | `noeviction` + AOF |
| [`deployment-redis-cache.yaml`](../kubernetes/base/deployment-redis-cache.yaml) | Redis cache | `allkeys-lru`, tanpa PVC |
| [`deployment-laravel.yaml`](../kubernetes/base/deployment-laravel.yaml) | PHP-FPM | probe `cgi-fcgi` |
| [`deployment-nginx.yaml`](../kubernetes/base/deployment-nginx.yaml) | Nginx | uid 101, port 8080 |
| [`deployment-queue.yaml`](../kubernetes/base/deployment-queue.yaml) | Queue worker | grace period 120 detik |
| [`cronjob-scheduler.yaml`](../kubernetes/base/cronjob-scheduler.yaml) | Scheduler | `concurrencyPolicy: Forbid` |
| [`job-migrate.yaml`](../kubernetes/base/job-migrate.yaml) | Migrasi | `--isolated` |
| [`services.yaml`](../kubernetes/base/services.yaml) | 5 Service | semuanya ClusterIP/headless |
| [`ingress.yaml`](../kubernetes/base/ingress.yaml) | Aturan routing | rantai timeout selaras |
| [`networkpolicy.yaml`](../kubernetes/base/networkpolicy.yaml) | 7 policy | default-deny + izin |
| [`hpa.yaml`](../kubernetes/base/hpa.yaml) | 3 HPA | `autoscaling/v2` |
| [`pdb.yaml`](../kubernetes/base/pdb.yaml) | 2 PDB | tidak untuk replika-1 |
| [`resourcequota.yaml`](../kubernetes/base/resourcequota.yaml) | Kuota namespace | NodePort dilarang |
| [`limitrange.yaml`](../kubernetes/base/limitrange.yaml) | Default per container | melengkapi kuota |

### Versi API yang dipakai — semuanya stabil

| Resource | apiVersion | Catatan |
|---|---|---|
| Deployment, StatefulSet | `apps/v1` | stabil sejak 1.9 |
| Job, CronJob | `batch/v1` | `batch/v1beta1` sudah dihapus |
| Ingress | `networking.k8s.io/v1` | `extensions/v1beta1` sudah dihapus |
| NetworkPolicy | `networking.k8s.io/v1` | |
| HPA | `autoscaling/v2` | `v2beta1`/`v2beta2` sudah dihapus |
| PodDisruptionBudget | `policy/v1` | `policy/v1beta1` sudah dihapus |
| Role, RoleBinding | `rbac.authorization.k8s.io/v1` | |

Seluruh manifest sudah diverifikasi dengan `kubectl apply --dry-run=server`
terhadap API server Kubernetes v1.36 yang berjalan — termasuk melewati
admission Pod Security `restricted`.

## 3.2 Tiga Penyimpangan dari Daftar Standar (dan alasannya)

### `statefulset-mariadb.yaml`, bukan `deployment-mysql.yaml`

Deployment dengan strategi RollingUpdate membuat Pod **baru sebelum** Pod
lama mati. Kedua Pod lalu memasang PVC yang sama dan menulis ke datadir
InnoDB yang sama secara bersamaan — jalan tercepat menuju korupsi data.

StatefulSet memberi identitas stabil, pembaruan berurutan, dan
`volumeClaimTemplates` yang menjamin satu volume per replika.

### `services.yaml`, bukan lima berkas terpisah

Kelima Service hanya belasan baris dan selalu dibaca bersamaan. Bila Anda
lebih suka satu berkas per resource, pecah saja dan daftarkan semuanya di
`kustomization.yaml` — tidak ada yang lain perlu berubah.

### Nginx sebagai Deployment terpisah — dan konsekuensinya

Ini yang paling perlu dipahami.

**Pilihan A — Deployment terpisah (dipakai di sini).** Sesuai permintaan
pemisahan concern. Keduanya bisa diskalakan sendiri: situs beraset berat
butuh lebih banyak Nginx, situs berproses berat butuh lebih banyak FPM.

Konsekuensinya, Nginx tidak berbagi filesystem dengan PHP-FPM. Dua akibatnya
sudah ditangani:

1. **Berkas statis** dibakar ke image Nginx pada stage terpisah di Dockerfile
   yang sama. Karena keduanya dibangun dari commit yang sama dan diberi tag
   yang sama, tidak pernah ada selisih versi.
2. **Berkas unggahan** tidak ada di image mana pun, jadi PVC ReadWriteMany
   yang sama dipasang di Nginx secara *read-only*.

Sisa risikonya: selama beberapa detik rollout, sebagian Pod Nginx sudah versi
baru sementara sebagian Pod FPM masih versi lama. Untuk Laravel + Vite ini
aman karena nama berkas aset mengandung hash isi — versi lama dan baru punya
nama berbeda dan bisa hidup berdampingan.

**Pilihan B — pola sidecar (satu Pod, dua container).** Lebih sederhana:
berkas statis dibagi lewat `emptyDir`, komunikasi lewat `localhost` tanpa
lompatan jaringan, dan tidak mungkin ada selisih versi. Harganya, Nginx dan
FPM harus diskalakan bersamaan.

Untuk beralih ke pola sidecar, tambahkan patch berikut ke overlay Anda:

```yaml
# patch-sidecar.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: laravel-fpm
spec:
  template:
    spec:
      containers:
        - name: nginx
          image: laravel-app/nginx:latest
          ports:
            - { name: http, containerPort: 8080 }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsUser: 101
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: tmp-nginx, mountPath: /tmp }
      volumes:
        - name: tmp-nginx
          emptyDir: {}
```

lalu arahkan Service `laravel-web` ke label `laravel-fpm`, dan hapus
Deployment `laravel-nginx`. Ubah juga `fastcgi_pass` di `default.conf`
menjadi `127.0.0.1:9000`.

## 3.3 Cara Kerja Kustomize di Project Ini

```
base/                     ← satu-satunya sumber kebenaran
  └── kustomization.yaml
overlays/
  ├── docker-desktop/     ← 4 perbedaan
  └── onprem/             ← 6 perbedaan
```

Tidak ada satu pun manifest yang diduplikasi. Overlay hanya berisi
*perbedaannya*.

### Hasil nyata

```bash
kubectl kustomize kubernetes/overlays/docker-desktop | grep -c '^apiVersion'
# 31 objek

kubectl kustomize kubernetes/overlays/onprem | grep -c '^apiVersion'
# 36 objek  (selisihnya: 3 HPA + 2 PDB)
```

| Aspek | docker-desktop | onprem |
|---|---|---|
| StorageClass unggahan | `hostpath` | `nfs-client` |
| StorageClass database | `hostpath` | `local-path` |
| Host Ingress | `laravel.localhost` | `laravel.192.168.50.200.nip.io` |
| Image | `laravel-app/php:dev` | `ghcr.io/ORG/laravel-php:v1.0.0` |
| Replika (fpm/nginx/queue) | 1 / 1 / 1 | 3 / 3 / 2 |
| HPA | dihapus | aktif |
| PDB | dihapus | aktif |
| `topologySpread` | `ScheduleAnyway` | `DoNotSchedule` |
| `imagePullPolicy` | `IfNotPresent` | `Always` + `imagePullSecrets` |

Semua yang lain — nama Service, struktur Deployment, probe, securityContext,
NetworkPolicy — **identik**. Itulah tujuannya: yang Anda uji di laptop adalah
objek yang sama dengan yang berjalan di on-premise.

### Teknik yang dipakai

**Transformer `images`** — mengganti image tanpa menyentuh manifest:

```bash
cd kubernetes/overlays/onprem
kustomize edit set image laravel-app/php=ghcr.io/org/laravel-php:v1.2.3
```

**`replicas`** — mengubah jumlah replika secara deklaratif, tanpa patch.

**JSON 6902 patch** — untuk perubahan satu nilai yang presisi:

```yaml
- target: { kind: Ingress, name: laravel }
  patch: |-
    - op: replace
      path: /spec/rules/0/host
      value: laravel.localhost
```

**Strategic merge patch** — untuk perubahan berstruktur; hanya field yang
disebutkan yang berubah, sisanya diwarisi base.

**`$patch: delete`** — membuang resource yang datang dari base:

```yaml
- patch: |-
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    metadata:
      name: laravel-fpm
    $patch: delete
```

Dipakai untuk menghapus HPA di Docker Desktop, tempat `metrics-server` tidak
terpasang sehingga HPA hanya menampilkan `<unknown>/70%`.

### Jebakan: `includeSelectors`

```yaml
labels:
  - includeSelectors: false      # ← WAJIB false
    pairs:
      app.kubernetes.io/part-of: laravel-stack
```

Dengan `true`, Kustomize menambahkan label ke `spec.selector` Deployment.
Padahal selector bersifat **immutable**: begitu Deployment sudah ada di
klaster, apply berikutnya gagal dengan `field is immutable`, dan satu-satunya
jalan keluar adalah menghapus Deployment-nya.

### Melihat hasil sebelum menerapkan

```bash
# Render tanpa mengirim ke klaster
kubectl kustomize kubernetes/overlays/onprem

# Bandingkan dengan yang sekarang berjalan di klaster
kubectl diff -k kubernetes/overlays/onprem
```

Biasakan menjalankan `kubectl diff` sebelum `kubectl apply`. Ia menampilkan
persis apa yang akan berubah — termasuk perubahan tak sengaja yang tidak Anda
maksudkan.

---

Berikutnya: [04-storage-jaringan.md](04-storage-jaringan.md)
