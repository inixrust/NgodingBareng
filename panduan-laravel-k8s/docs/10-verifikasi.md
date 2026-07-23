# 10. Daftar Periksa Verifikasi

Jalankan otomatis:

```bash
./scripts/verify.sh                 # namespace laravel
./scripts/verify.sh namespace-lain
```

Skrip keluar dengan kode ≠ 0 bila ada yang gagal, jadi bisa dipakai sebagai
gerbang di pipeline.

Di bawah ini daftar yang sama dalam bentuk manual, lengkap dengan hasil yang
diharapkan.

## 1. Workload

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 1.1 | Semua Pod Running/Completed | `kubectl -n laravel get pods` | tidak ada Error/Pending/CrashLoop |
| 1.2 | Semua container Ready | kolom READY | `1/1` di semua baris |
| 1.3 | php-fpm tersedia | `kubectl -n laravel get deploy laravel-fpm` | `AVAILABLE` = jumlah replika |
| 1.4 | nginx tersedia | `get deploy laravel-nginx` | idem |
| 1.5 | queue tersedia | `get deploy laravel-queue` | idem |
| 1.6 | MariaDB siap | `get sts mariadb` | `READY 1/1` |
| 1.7 | Redis siap | `get sts redis` | `READY 1/1` |
| 1.8 | Redis cache siap | `get deploy redis-cache` | `AVAILABLE 1` |

## 2. Stabilitas

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 2.1 | Tidak ada restart | `kubectl -n laravel get pods` | kolom RESTARTS = 0 |
| 2.2 | Tidak ada OOMKill | `kubectl -n laravel describe pods \| grep -c OOMKilled` | 0 |
| 2.3 | Tidak ada Event Warning | `kubectl -n laravel get events --field-selector type=Warning` | kosong |

> Restart yang menumpuk adalah gejala yang paling sering luput karena Pod-nya
> tetap terlihat `Running`. Penyebabnya hampir selalu probe terlalu ketat atau
> memory limit terlalu kecil.

## 3. Jaringan

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 3.1 | Service laravel-web punya endpoint | `kubectl -n laravel get endpointslices` | ada alamat IP |
| 3.2 | Service laravel-fpm punya endpoint | idem | ada alamat IP |
| 3.3 | Ingress punya ADDRESS | `kubectl -n laravel get ingress` | terisi |
| 3.4 | DNS internal bekerja | `nslookup laravel-fpm` dari dalam Pod | `laravel-fpm.laravel.svc.cluster.local` |
| 3.5 | Nginx menjangkau FPM | `nc -zv laravel-fpm 9000` dari Pod nginx | `open` |
| 3.6 | NetworkPolicy menolak yang tidak berhak | Pod tanpa label ke `mariadb:3306` | **timeout** |

```bash
kubectl -n laravel get endpointslices
kubectl -n laravel get ingress

kubectl -n laravel run uji-dns --rm -it --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
  -- nslookup laravel-fpm
```

> Butir 3.6 **tidak berlaku di Docker Desktop** — CNI bawaannya tidak
> menegakkan NetworkPolicy. Uji ini hanya bermakna di klaster kubeadm dengan
> Calico atau Cilium.

## 4. Penyimpanan

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 4.1 | PVC unggahan Bound | `kubectl -n laravel get pvc laravel-storage` | `Bound` |
| 4.2 | PVC database Bound | `get pvc data-mariadb-0` | `Bound` |
| 4.3 | PVC redis Bound | `get pvc data-redis-0` | `Bound` |
| 4.4 | storage bisa ditulis | `touch storage/app/public/.uji` di Pod | sukses |
| 4.5 | bootstrap/cache bisa ditulis | `touch bootstrap/cache/.uji` | sukses |
| 4.6 | RWX benar-benar bekerja | tulis dari Pod A, baca dari Pod B di Node lain | terbaca |

```bash
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-fpm -o name | head -1)
kubectl -n laravel exec $POD -c php-fpm -- \
  sh -c 'touch storage/app/public/.uji && echo bisa-ditulis && rm storage/app/public/.uji'
```

Butir 4.6 hanya bermakna di klaster multi-node, dan ini yang membuktikan
pilihan NFS benar:

```bash
A=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-fpm -o name | sed -n 1p)
B=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-queue -o name | sed -n 1p)

kubectl -n laravel exec $A -c php-fpm -- sh -c 'echo halo-rwx > storage/app/public/uji-rwx.txt'
kubectl -n laravel exec $B -c queue   -- cat storage/app/public/uji-rwx.txt
# harus mencetak: halo-rwx
kubectl -n laravel exec $A -c php-fpm -- rm storage/app/public/uji-rwx.txt
```

## 5. Aplikasi

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 5.1 | Database terhubung | `php artisan db:show` | menampilkan tabel & jumlah |
| 5.2 | Migrasi sukses semua | `php artisan migrate:status` | semua `Ran` |
| 5.3 | Redis terhubung | `Redis::ping()` | `PONG` |
| 5.4 | Cache berfungsi | `cache()->put/get` | nilai kembali |
| 5.5 | Sesi memakai Redis | `php artisan config:show session.driver` | `redis` |
| 5.6 | Config sudah di-cache | `ls bootstrap/cache/` | ada `config.php` |
| 5.7 | Route sudah di-cache | idem | ada `routes-v7.php` |
| 5.8 | Berjalan non-root | `id` | `uid=10001` |
| 5.9 | Root filesystem read-only | `touch /uji` | `Read-only file system` |
| 5.10 | `APP_DEBUG` mati di produksi | `php artisan config:show app.debug` | `false` |

```bash
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-fpm -o name | head -1)
X="kubectl -n laravel exec $POD -c php-fpm --"

$X php artisan db:show
$X php artisan migrate:status
$X php -r '$r=new Redis(); $r->connect("redis",6379); echo $r->ping(), PHP_EOL;'
$X php artisan tinker --execute 'cache()->put("k","v",10); echo cache()->get("k");'
$X id
$X touch /uji-root         # harus GAGAL — itu tandanya benar
```

> `php artisan tinker` di Pod dengan `readOnlyRootFilesystem` membutuhkan
> `HOME` yang bisa ditulis (PsySH menyimpan riwayat). Bila gagal, jalankan
> dengan `env HOME=/tmp php artisan tinker ...`.

## 6. Antrian dan Scheduler

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 6.1 | Worker berjalan | `get pods -l ...laravel-queue` | Running |
| 6.2 | Worker memproses job | dorong job uji, lihat log | job terproses |
| 6.3 | Tidak ada failed job | `php artisan queue:failed` | kosong |
| 6.4 | CronJob tidak suspend | `get cronjob` | `SUSPEND False` |
| 6.5 | Scheduler pernah jalan | kolom `LAST SCHEDULE` | < 2 menit lalu |
| 6.6 | Job scheduler sukses | `get jobs` | `COMPLETIONS 1/1` |

```bash
# Dorong satu job dan buktikan worker mengambilnya
kubectl -n laravel exec deploy/laravel-fpm -c php-fpm -- \
  php artisan tinker --execute 'dispatch(function () { logger()->info("JOB UJI BERJALAN"); });'

sleep 5
kubectl -n laravel logs -l app.kubernetes.io/name=laravel-queue --tail=20 | grep "JOB UJI"

kubectl -n laravel get cronjob laravel-scheduler
kubectl -n laravel get jobs --sort-by=.metadata.creationTimestamp | tail -5
```

## 7. Akses HTTP

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 7.1 | `/up` dari dalam klaster | `curl http://laravel-web/up` | `200` |
| 7.2 | `/healthz` Nginx | `curl .../healthz` | `200 ok` |
| 7.3 | Halaman utama | `curl -I http://<host>/` | `200` |
| 7.4 | Aset statis dilayani Nginx | `curl -I .../build/assets/*.css` | `200` + `Cache-Control: immutable` |
| 7.5 | `.env` tidak bisa diakses | `curl .../.env` | `403` atau `404` |
| 7.6 | Berkas PHP selain index | `curl .../artisan` | `404` |
| 7.7 | Versi PHP tidak bocor | `curl -I ...` | tanpa header `X-Powered-By` |

```bash
# Docker Desktop
curl -I http://laravel.localhost/
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/up
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.localhost/.env    # 403/404

# On-premise
curl -H 'Host: laravel.192.168.50.200.nip.io' -I http://192.168.50.200/
```

## 8. Keamanan

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 8.1 | PSA restricted aktif | `kubectl get ns laravel -o yaml \| grep pod-security` | `enforce: restricted` |
| 8.2 | Semua Pod non-root | `get pods -o jsonpath` runAsNonRoot | semua `true` |
| 8.3 | SA aplikasi tanpa izin | `auth can-i list pods --as=...:laravel` | `no` |
| 8.4 | SA ops tidak bisa baca Secret | `auth can-i get secrets --as=...:laravel-ops` | `no` |
| 8.5 | Token tidak dipasang | `get pod -o yaml \| grep serviceaccount` | tanpa mount token |
| 8.6 | NetworkPolicy ada | `get netpol` | 7 policy |
| 8.7 | Tidak ada Secret di Git | `git grep -i 'password.*[a-z0-9]\{12\}'` | tidak ada yang asli |

```bash
kubectl get ns laravel -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security

kubectl auth can-i list pods   -n laravel --as=system:serviceaccount:laravel:laravel       # no
kubectl auth can-i get secrets -n laravel --as=system:serviceaccount:laravel:laravel-ops   # no

kubectl -n laravel get pods -o custom-columns=\
NAMA:.metadata.name,NONROOT:.spec.securityContext.runAsNonRoot,UID:.spec.securityContext.runAsUser
```

## 9. Ketahanan (khusus on-premise)

| # | Yang diperiksa | Perintah | Diharapkan |
|---|---|---|---|
| 9.1 | Replika tersebar antar Node | `get pods -o wide` | tiap Pod di Node berbeda |
| 9.2 | HPA membaca metrik | `get hpa` | angka, bukan `<unknown>` |
| 9.3 | PDB terpasang | `get pdb` | `ALLOWED DISRUPTIONS` ≥ 1 |
| 9.4 | Rolling update tanpa downtime | loop curl saat rollout | semua `200` |
| 9.5 | Bertahan saat satu Node di-drain | `kubectl drain <worker>` | aplikasi tetap melayani |

```bash
kubectl -n laravel get pods -o wide --sort-by=.spec.nodeName
kubectl -n laravel get hpa
kubectl -n laravel get pdb

# Uji ketahanan sungguhan — jalankan loop curl di terminal lain lebih dulu
kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data
kubectl -n laravel get pods -o wide      # Pod pindah ke worker lain
kubectl uncordon worker2
```

## 10. Ringkasan Satu Layar

```bash
cat <<'EOF' > /tmp/ringkasan.sh
NS=laravel
echo "=== POD ==="        && kubectl -n $NS get pods
echo "=== SERVICE ==="    && kubectl -n $NS get svc
echo "=== INGRESS ==="    && kubectl -n $NS get ingress
echo "=== PVC ==="        && kubectl -n $NS get pvc
echo "=== HPA ==="        && kubectl -n $NS get hpa
echo "=== CRONJOB ==="    && kubectl -n $NS get cronjob
echo "=== RESTART>0 ==="  && kubectl -n $NS get pods --no-headers | awk '$4>0'
echo "=== WARNING ==="    && kubectl -n $NS get events --field-selector type=Warning | tail -10
EOF
bash /tmp/ringkasan.sh
```

## Kriteria "Deployment Berhasil"

Deployment dinyatakan berhasil bila **semuanya** terpenuhi:

- [ ] Semua Pod `Running` atau `Completed`, semua container `Ready`
- [ ] `RESTARTS` = 0 pada semua Pod
- [ ] Semua PVC `Bound`
- [ ] Ingress punya `ADDRESS`
- [ ] Aplikasi bisa dibuka di browser dan menampilkan halaman
- [ ] `php artisan db:show` berhasil
- [ ] `php artisan migrate:status` menampilkan semua `Ran`
- [ ] Redis menjawab `PONG`
- [ ] Queue worker memproses job uji
- [ ] `LAST SCHEDULE` CronJob < 2 menit lalu
- [ ] `storage/app/public` bisa ditulis
- [ ] Semua Pod berjalan non-root
- [ ] `.env` tidak bisa diakses dari browser
- [ ] `APP_DEBUG` bernilai `false` di produksi
- [ ] Rolling update tidak menghasilkan satu pun respons 5xx

---

Kembali ke [README](../README.md)
