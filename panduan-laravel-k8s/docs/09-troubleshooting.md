# 9. Troubleshooting

## 9.1 Urutan Diagnosis Baku

Selalu dari ringkas ke rinci, dan **berhenti begitu penyebabnya ketemu**.

```bash
kubectl -n laravel get pods                    # 1. status apa, restart berapa kali
kubectl -n laravel describe pod <nama>         # 2. EVENTS di bagian bawah
kubectl -n laravel logs <nama> -c <container>  # 3. keluaran aplikasi
kubectl -n laravel logs <nama> --previous      # 4. log sebelum crash terakhir
kubectl -n laravel exec -it <nama> -- sh       # 5. periksa dari dalam
kubectl get nodes; kubectl -n kube-system get pods   # 6. naik satu lapis
```

**Bagian Events pada `describe` adalah sumber jawaban yang paling sering
terlewat.** Sebagian besar kegagalan sudah dijelaskan di sana dengan kalimat
lengkap.

### Peta status Pod

| Status | Lapis masalah | Perintah pertama |
|---|---|---|
| `Pending` | penjadwalan / PVC | `describe pod` → Events |
| `ContainerCreating` | volume / CNI | `describe pod` → Events |
| `ImagePullBackOff` | nama image / kredensial | `describe pod` → Events |
| `CrashLoopBackOff` | aplikasi keluar berulang | `logs --previous` |
| `Error` | keluar, tidak diulang | `logs` (**tanpa** `--previous`) |
| `Running` tapi `0/1` | probe gagal | `describe` + `logs` |
| `OOMKilled` | memori melampaui limit | `describe pod` → Last State |

> **Perbedaan yang sering salah:** `CrashLoopBackOff` hanya terjadi pada
> `restartPolicy: Always` (Deployment). Pod `--restart=Never` yang gagal
> berakhir `Error` dan **tidak punya container "previous"** — jadi
> `logs --previous` di sana pasti gagal.

## 9.2 Masalah Umum

### CrashLoopBackOff

```bash
kubectl -n laravel logs <pod> -c php-fpm --previous
kubectl -n laravel describe pod <pod> | grep -A5 'Last State'
```

| Penyebab | Gejala di log | Solusi |
|---|---|---|
| `APP_KEY` kosong | `No application encryption key has been specified` | isi Secret; entrypoint kita sudah menolak start lebih awal |
| Database belum siap | `SQLSTATE[HY000] [2002] Connection refused` | initContainer `tunggu-dependensi` seharusnya mencegah ini; periksa Pod MariaDB |
| Salah kredensial | `Access denied for user 'laravel'@'...'` | lihat "MySQL gagal start" di bawah — kemungkinan datadir lama |
| OOMKilled | `Last State: Terminated, Reason: OOMKilled` | naikkan `limits.memory`, atau turunkan `pm.max_children` |
| Path cache tidak ada | `Please provide a valid cache path` | `storage/framework/*` tidak ada; entrypoint membuatnya — periksa mount emptyDir |
| Config beku salah | error koneksi ke host yang aneh | `config:cache` dijalankan saat build, bukan runtime |

**Yang terakhir layak diperhatikan.** Bila `config:cache` dijalankan di
Dockerfile, nilai `env()` membeku pada nilai saat build — biasanya default
dari `.env.example`. Aplikasi lalu mencoba menghubungi `127.0.0.1` alih-alih
`mariadb`. Solusinya: jalankan di entrypoint, seperti pada panduan ini.

### ImagePullBackOff

```bash
kubectl -n laravel describe pod <pod> | grep -A10 Events
```

| Pesan | Penyebab | Solusi |
|---|---|---|
| `manifest unknown` | tag tidak ada di registry | periksa `docker push` benar-benar sukses |
| `unauthorized` | registry privat tanpa kredensial | buat `imagePullSecrets` |
| `pull access denied` | token tanpa scope `read:packages` | buat ulang token |
| `Error response from daemon: ... not found` | image ada di daemon lokal tetapi tag `latest` | **lihat di bawah** |

**Jebakan Docker Desktop yang paling sering.** Image sudah dibangun lokal,
`docker images` menampilkannya, tetapi Kubernetes tetap `ImagePullBackOff`.

Sebabnya: tag `latest` memicu `imagePullPolicy: Always` secara **implisit**,
sehingga Kubernetes mengabaikan image lokal dan mencarinya di Docker Hub.

Solusi — pakai tag selain `latest` (overlay kita memakai `dev`) dan pastikan
`imagePullPolicy: IfNotPresent`:

```bash
kubectl -n laravel get pod <pod> -o jsonpath='{.spec.containers[0].imagePullPolicy}'
```

Pada klaster kubeadm, ingat bahwa **Node tidak berbagi daemon Docker dengan
mesin Anda**. Image lokal tidak akan pernah terlihat oleh Node — harus lewat
registry.

### PVC Pending

```bash
kubectl -n laravel describe pvc laravel-storage | grep -A10 Events
```

| Pesan | Penyebab | Solusi |
|---|---|---|
| `no persistent volumes available` | tidak ada StorageClass default | set `storageClassName` di overlay |
| `storageclass.storage.k8s.io "x" not found` | StorageClass belum dibuat | pasang provisioner |
| `waiting for first consumer` | `volumeBindingMode: WaitForFirstConsumer` | **normal** — PVC terikat setelah Pod dijadwalkan |
| `only supports ReadWriteOnce` | backend tidak mendukung RWX | pakai NFS untuk PVC RWX |

Pesan ketiga bukan kesalahan. PVC memang menunggu Pod pertama muncul; itulah
perilaku yang benar untuk Local PV.

```bash
kubectl get storageclass
kubectl get pv
kubectl -n kube-system get pods | grep -E 'nfs|local-path'
```

### Ingress tidak bisa diakses

Telusuri dari luar ke dalam. Setiap langkah menyingkirkan satu kemungkinan:

```bash
# 1. Apakah Ingress punya ADDRESS?
kubectl -n laravel get ingress
# ADDRESS kosong -> controller tidak memproses; periksa ingressClassName

# 2. Apakah controller berjalan?
kubectl -n ingress-nginx get pods

# 3. Apakah Service controller punya EXTERNAL-IP?
kubectl -n ingress-nginx get svc
# <pending> di kubeadm -> MetalLB belum jalan atau kolamnya habis

# 4. Apakah controller mengenali aturan kita?
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep laravel

# 5. Apakah backend-nya sehat?
kubectl -n laravel get endpointslices
# Endpoint kosong -> selector Service tidak cocok, atau Pod belum Ready

# 6. Lewati Ingress sepenuhnya — memisahkan masalah
kubectl -n laravel port-forward svc/laravel-web 8080:80
curl http://localhost:8080/up
```

Bila langkah 6 berhasil tetapi akses lewat Ingress gagal, masalahnya di
lapis Ingress/MetalLB — bukan di aplikasi.

| Gejala | Penyebab | Solusi |
|---|---|---|
| ADDRESS kosong selamanya | tidak ada Ingress Controller | pasang controller |
| 404 dari Nginx bawaan controller | host tidak cocok | periksa header `Host` yang dikirim |
| 503 | Service tanpa endpoint | periksa selector dan status Ready Pod |
| Timeout dari LAN | MetalLB tidak mengumumkan | `L2Advertisement` terlupa |
| Kadang bisa, kadang tidak | IP bentrok | rentang MetalLB masuk kolam DHCP |

### MySQL/MariaDB gagal start

```bash
kubectl -n laravel logs mariadb-0
kubectl -n laravel describe pod mariadb-0
```

| Pesan | Penyebab | Solusi |
|---|---|---|
| `Access denied for user` | **datadir lama dengan password lama** | lihat di bawah |
| `mysqld: Can't create/write to file '/tmp/...'` | `readOnlyRootFilesystem` tanpa emptyDir `/tmp` | sudah ditangani manifest kita |
| `InnoDB: Cannot allocate memory for the buffer pool` | `innodb-buffer-pool-size` > `limits.memory` | turunkan **keduanya** bersama |
| `Table 'mysql.plugin' doesn't exist` | datadir setengah terinisialisasi | reset PVC |
| `[Warning] World-writable config file ... ignored` | ConfigMap ter-mount dengan mode terlalu longgar | set `defaultMode: 0440` |
| Pod Pending | PVC belum Bound | periksa StorageClass |

**Masalah nomor satu: datadir lama.**

Menghapus StatefulSet tidak menghapus PVC-nya. Dan pada provisioner
`hostpath`/`local-path`, menghapus PVC pun belum tentu menghapus direktori di
disk — provisioner memetakan direktori berdasarkan **nama PVC**.

Akibatnya: Anda mengganti `DB_PASSWORD` di Secret, deploy ulang "dari awal",
dan MariaDB tetap menolak login — karena tabel `mysql.user` di datadir lama
masih menyimpan password sebelumnya. `MARIADB_PASSWORD` **hanya berlaku saat
inisialisasi pertama**.

```bash
./scripts/reset-database.sh
```

> **Bila memakai MySQL, jangan beri nama variabel `MYSQL_PWD`.** Klien
> `mysql` membacanya secara otomatis — termasuk selama fase server sementara
> pada entrypoint resmi, ketika root justru belum punya password. Inisialisasi
> berhenti di tengah dan meninggalkan datadir setengah jadi. Pakai nama lain
> seperti `APP_DB_PASSWORD`.

### Redis gagal start

| Pesan | Penyebab | Solusi |
|---|---|---|
| `Can't open the append-only file: Permission denied` | `fsGroup` tidak cocok dengan uid image | `fsGroup: 999` |
| `Read-only file system` | tidak ada volume di `/data` | pasang emptyDir atau PVC |
| `OOM command not allowed when used memory > maxmemory` | `noeviction` + memori penuh | naikkan `maxmemory`, atau periksa antrian yang menumpuk |
| `MISCONF Redis is configured to save RDB snapshots...` | snapshot gagal | periksa ruang disk PVC |

Yang ketiga adalah perilaku **yang diinginkan** pada instance antrian:
`noeviction` menolak penulisan baru alih-alih membuang job yang sudah ada.
Yang perlu diperiksa adalah kenapa antriannya menumpuk — biasanya worker mati
atau kurang.

### Permission storage Laravel / bootstrap/cache

```bash
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-fpm -o name | head -1)
kubectl -n laravel exec $POD -c php-fpm -- id
kubectl -n laravel exec $POD -c php-fpm -- ls -la storage/ bootstrap/cache/
kubectl -n laravel exec $POD -c php-fpm -- touch storage/app/public/.uji
```

| Pesan | Penyebab | Solusi |
|---|---|---|
| `Permission denied` di `storage/app/public` | `fsGroup` tidak cocok dengan `runAsUser` | samakan keduanya (10001) |
| `Read-only file system` | path tidak dipetakan ke volume | tambahkan emptyDir/PVC |
| `Please provide a valid cache path` | `storage/framework/views` tidak ada | entrypoint membuatnya; periksa mount |
| `failed to open stream: Permission denied` di `bootstrap/cache` | emptyDir tanpa `fsGroup` | set `fsGroup` di Pod securityContext |
| Nginx 403 pada `/storage/*` | Nginx (uid 101) tidak bisa membaca berkas milik uid 10001 | lihat di bawah |

**403 pada berkas unggahan.** Nginx berjalan sebagai uid 101, sedangkan
berkas ditulis php-fpm sebagai uid 10001. Bila izinnya `0600`, Nginx tidak
bisa membacanya.

Solusi: pastikan berkas yang ditulis punya bit "other read". Di Laravel:

```php
// config/filesystems.php
'public' => [
    'driver' => 'local',
    'root' => storage_path('app/public'),
    'permissions' => [
        'file' => ['public' => 0644],
        'dir'  => ['public' => 0755],
    ],
],
```

### 502 Bad Gateway

Artinya Nginx **tidak mendapat jawaban yang sah** dari PHP-FPM.

```bash
kubectl -n laravel logs deploy/laravel-nginx | grep 502
kubectl -n laravel get endpointslices -l kubernetes.io/service-name=laravel-fpm
kubectl -n laravel logs deploy/laravel-fpm -c php-fpm --tail=100
```

| Penyebab | Cara memastikan | Solusi |
|---|---|---|
| Pod FPM tidak ada yang Ready | `EndpointSlice` kosong | periksa probe FPM |
| Pool FPM penuh | log FPM: `server reached pm.max_children` | naikkan `pm.max_children`, atau tambah replika |
| Proses PHP mati (segfault, OOM) | log FPM: `child exited on signal 11` | periksa ekstensi PHP dan `memory_limit` |
| Sedang rollout | 502 hanya sesaat | tambah `preStop` sleep |
| Salah alamat upstream | log Nginx: `connect() failed` | periksa `fastcgi_pass` = nama Service |
| NetworkPolicy memblokir | timeout, bukan connection refused | periksa `allow-nginx-to-fpm` |

**Membedakan dua penyebab terbesar:** `connection refused` berarti tidak ada
yang mendengarkan (Pod mati/salah alamat). **Timeout** berarti ada yang
mendengarkan tetapi tidak menjawab (pool penuh, atau NetworkPolicy memblokir
di tengah jalan).

### 504 Gateway Timeout

Artinya PHP menjawab, tetapi **terlalu lambat**.

Rantai timeout harus selaras dari luar ke dalam:

```
Ingress proxy-read-timeout    60s
  >= Nginx fastcgi_read_timeout  60s
     >= PHP max_execution_time   30s
```

Bila urutan ini terbalik, PHP masih bekerja saat proxy sudah menyerah —
gejalanya 504 **tanpa jejak apa pun di log PHP**, karena prosesnya tidak
pernah selesai dan tidak pernah error.

```bash
# Cari request yang lambat; upstream_time memisahkan PHP dari jaringan
kubectl -n laravel logs deploy/laravel-nginx | grep -E '"upstream_time":"[0-9]{2,}'

# slowlog PHP-FPM mencatat stack trace request yang > 5 detik
kubectl -n laravel logs deploy/laravel-fpm -c php-fpm | grep -A20 'slow request'
```

Penyebab tersering pada aplikasi Laravel: query N+1, index yang hilang, atau
panggilan HTTP eksternal tanpa timeout di dalam siklus request. Yang terakhir
sebaiknya dipindahkan ke queue.

### Nginx tidak dapat terhubung ke PHP-FPM

```bash
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-nginx -o name | head -1)

# a. Apakah namanya bisa di-resolve?
kubectl -n laravel exec $POD -- nslookup laravel-fpm

# b. Apakah portnya terbuka?
kubectl -n laravel exec $POD -- nc -zv laravel-fpm 9000

# c. Apakah Service punya endpoint?
kubectl -n laravel describe svc laravel-fpm
```

| Gejala | Penyebab | Solusi |
|---|---|---|
| `nslookup` gagal | CoreDNS bermasalah | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| `nslookup` berhasil, `nc` timeout | NetworkPolicy | periksa `allow-nginx-to-fpm` dan `allow-nginx-egress` |
| `nc` connection refused | tidak ada Pod FPM Ready | periksa probe FPM |
| Endpoint kosong | selector tidak cocok | bandingkan `spec.selector` Service dengan label Pod |

**Catatan penting.** `curl http://laravel-fpm:9000` **tidak akan pernah**
menghasilkan halaman — PHP-FPM berbicara FastCGI, bukan HTTP. Itu bukan tanda
kerusakan. Gunakan `nc -z` untuk menguji konektivitas, atau `cgi-fcgi` untuk
menguji protokolnya.

### Pod Pending

```bash
kubectl -n laravel describe pod <pod> | grep -A15 Events
kubectl get nodes
kubectl describe node <node> | grep -A10 'Allocated resources'
```

| Pesan | Penyebab | Solusi |
|---|---|---|
| `Insufficient cpu/memory` | Node penuh (berdasarkan **requests**, bukan pemakaian) | turunkan requests, atau tambah Node |
| `node(s) had untolerated taint` | taint pada Node | tambahkan toleration, atau cabut taint |
| `didn't match pod topology spread constraints` | `DoNotSchedule` tidak bisa dipenuhi | replika > jumlah Node; pakai `ScheduleAnyway` |
| `pod has unbound immediate PersistentVolumeClaims` | PVC belum Bound | periksa StorageClass |
| `exceeded quota` | ResourceQuota namespace | naikkan kuota, atau kurangi permintaan |

**Yang paling sering membingungkan:** `Insufficient memory` pada Node yang
`kubectl top` menunjukkan pemakaiannya rendah. Scheduler membandingkan
**requests** dengan kapasitas, bukan pemakaian nyata. Node bisa 90% dipesan
tetapi hanya 20% terpakai.

## 9.3 Perintah Diagnosis yang Berguna

```bash
# Semua Event terbaru, terurut waktu — sering langsung menunjukkan penyebab
kubectl -n laravel get events --sort-by=.lastTimestamp | tail -30

# Pod yang tidak sehat saja
kubectl -n laravel get pods --field-selector=status.phase!=Running

# Pod yang sering restart
kubectl -n laravel get pods --sort-by=.status.containerStatuses[0].restartCount

# Ephemeral container: masuk ke Pod berjalan tanpa me-restart-nya,
# membawa perkakas sendiri (image produksi kita tidak punya curl)
kubectl -n laravel debug -it <pod> --image=nicolaka/netshoot --target=php-fpm

# Log semua replika sekaligus, ditandai nama Pod asalnya
kubectl -n laravel logs -l app.kubernetes.io/name=laravel-fpm \
  --all-containers --prefix --tail=50 -f

# Apa yang AKAN berubah bila di-apply
kubectl diff -k kubernetes/overlays/onprem

# Verifikasi hak akses tanpa harus mencobanya
kubectl auth can-i --list -n laravel --as=system:serviceaccount:laravel:laravel
```

---

Berikutnya: [10-verifikasi.md](10-verifikasi.md)
