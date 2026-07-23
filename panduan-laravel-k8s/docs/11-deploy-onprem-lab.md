# 11. Deploy Laravel ke Klaster On-Premise (Lab, Tanpa Registry)

Langkah demi langkah men-deploy aplikasi Laravel dari project ini ke
klaster kubeadm yang baru dibangun:

```
cp       192.168.50.14   control plane (juga jadi server NFS di lab ini)
worker1  192.168.50.15
worker2  192.168.50.16   CNI: Cilium · Kubernetes v1.35.6
worker3  192.168.50.17
```

Semua perintah dijalankan **dari komputer kerja Anda (Windows, Git Bash)**
di direktori `panduan-laravel-k8s/`, kecuali disebut lain.

Bedanya dengan [docs/08](08-deployment.md) bagian kubeadm: dokumen ini
memakai overlay **`onprem-lab`** — image dimuat langsung ke worker lewat
SSH (`ctr images import`), tanpa registry. Jalur registry (GHCR + overlay
`onprem`) tetap menjadi jalur produksi yang benar.

**Peta langkah:**

| # | Tahap | Sekali/berulang |
|---|-------|-----------------|
| 1 | Hubungkan kubectl dari komputer kerja | sekali |
| 2 | Label worker | sekali |
| 3 | MetalLB (LoadBalancer untuk LAN) | sekali |
| 4 | Ingress Controller | sekali |
| 5 | Storage: NFS + local-path | sekali |
| 6 | metrics-server (untuk HPA) | sekali |
| 7 | Build image + muat ke worker | tiap rilis |
| 8 | Namespace + Secret | sekali |
| 9 | Deploy overlay `onprem-lab` | tiap rilis |
| 10 | Verifikasi + akses browser | tiap rilis |
| 11 | Uji NetworkPolicy (kini benar-benar ditegakkan!) | sekali |

---

## Langkah 1 — Hubungkan kubectl dari Komputer Kerja

Salin kubeconfig dari control plane, simpan sebagai context terpisah:

```bash
scp student@192.168.50.14:/etc/kubernetes/admin.conf ~/.kube/config-onprem
# admin.conf milik root; bila scp ditolak, di cp jalankan dulu:
#   sudo cp /etc/kubernetes/admin.conf /tmp/ && sudo chown student /tmp/admin.conf
# lalu scp dari /tmp/admin.conf

export KUBECONFIG=~/.kube/config-onprem
kubectl get nodes
```

Yang diharapkan:

```
NAME      STATUS   ROLES           AGE   VERSION
cp        Ready    control-plane   1h    v1.35.6
worker1   Ready    <none>          1h    v1.35.6
worker2   Ready    <none>          1h    v1.35.6
worker3   Ready    <none>          1h    v1.35.6
```

> **Catatan sertifikat.** `admin.conf` menunjuk `https://k8scp:6443` —
> nama itu harus bisa di-resolve dari komputer kerja Anda juga. Dua
> pilihan: tambahkan `192.168.50.14 k8scp` ke
> `C:\Windows\System32\drivers\etc\hosts` (jalankan Notepad sebagai
> Administrator), ATAU ganti server di kubeconfig menjadi IP:
>
> ```bash
> sed -i 's#server: https://k8scp:6443#server: https://192.168.50.14:6443#' ~/.kube/config-onprem
> ```
>
> Mengganti ke IP aman karena sertifikat API server juga memuat
> `192.168.50.14` (terlihat saat `kubeadm init`: `...and IPs [10.96.0.1
> 192.168.50.14]`).

> **Kebiasaan yang menyelamatkan:** `kubectl config current-context`
> sebelum setiap `apply`. Anda kini punya dua klaster (docker-desktop dan
> onprem) — menerapkan manifest ke klaster yang salah adalah kesalahan
> yang mudah dilakukan dan mahal diperbaiki. Sesi dengan
> `export KUBECONFIG=~/.kube/config-onprem` hanya melihat klaster onprem.

## Langkah 2 — Label Worker

Dipakai `nodeSelector` MetalLB (hanya worker yang mengumumkan IP) dan
memperjelas keluaran `get nodes`:

```bash
for w in worker1 worker2 worker3; do
  kubectl label node $w node-role.kubernetes.io/worker="" --overwrite
done
```

## Langkah 3 — MetalLB

**Kenapa:** Service `LoadBalancer` meminta IP eksternal ke penyedia cloud.
Di klaster on-premise tidak ada yang menjawab — `EXTERNAL-IP` akan
`<pending>` selamanya. MetalLB mengisinya: dalam mode L2, satu worker
menjawab ARP untuk IP tersebut sehingga perangkat LAN tahu ke mana
mengirim paket.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl -n metallb-system rollout status deployment/controller --timeout=180s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=180s
```

**SEBELUM menerapkan kolam IP** — dua pemeriksaan wajib
(lihat [docs/04 §4.5](04-storage-jaringan.md) untuk alasannya):

```bash
# 1. Pastikan 192.168.50.200-240 tidak dipakai perangkat lain:
nmap -sn 192.168.50.200-240
# 2. Keluarkan rentang itu dari kolam DHCP router Anda (lewat admin router).
```

Terapkan kolam + Service LoadBalancer untuk ingress:

```bash
kubectl apply -f infra/metallb-config.yaml
```

> Berkas ini juga membuat Service `ingress-nginx-controller` di namespace
> `ingress-nginx` yang belum ada — bila ada galat "namespace not found",
> jalankan lagi perintah ini SETELAH Langkah 4. Urutan mana pun berakhir
> sama.

## Langkah 4 — Ingress Controller

Varian **baremetal** (bukan cloud), diskalakan ke 3 replika supaya
`externalTrafficPolicy: Local` pada Service MetalLB selalu punya Pod di
Node yang menerima trafik:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx scale deployment/ingress-nginx-controller --replicas=3
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

# pastikan Service-nya versi MetalLB (LoadBalancer, IP tetap .200)
kubectl apply -f infra/metallb-config.yaml
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

Yang diharapkan — `EXTERNAL-IP` terisi, bukan `<pending>`:

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
ingress-nginx-controller   LoadBalancer   10.x.x.x       192.168.50.200   80:...,443:...
```

Uji dari komputer kerja (belum ada aplikasi — 404 dari controller justru
bukti rantai LAN → MetalLB → controller sudah hidup):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.200/
# 404  <- benar untuk saat ini
```

## Langkah 5 — Storage

Dua StorageClass untuk dua kebutuhan berbeda
([alasannya di docs/04 §4.3](04-storage-jaringan.md)): unggahan butuh
**RWX** (dibaca-tulis Pod di tiga worker) → NFS; database butuh IO cepat →
disk lokal.

**5a. Server NFS di cp** (SSH ke `student@192.168.50.14`):

```bash
sudo apt update && sudo apt install -y nfs-kernel-server
sudo mkdir -p /srv/nfs/kubernetes
sudo chown nobody:nogroup /srv/nfs/kubernetes
sudo chmod 777 /srv/nfs/kubernetes
echo '/srv/nfs/kubernetes 192.168.50.0/24(rw,sync,no_subtree_check,no_root_squash)' \
  | sudo tee -a /etc/exports
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server
showmount -e localhost     # harus menampilkan /srv/nfs/kubernetes
```

**5b. Klien NFS di SEMUA worker** — paling sering terlupa; tanpa ini Pod
macet `ContainerCreating` dengan pesan mount helper yang membingungkan:

```bash
# dari komputer kerja:
for n in 15 16 17; do
  ssh student@192.168.50.$n 'sudo apt-get install -y nfs-common'
done
```

**5c. Provisioner** (dari komputer kerja; butuh `helm` — di Git Bash bisa
pakai `winget install Helm.Helm` sekali):

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update
helm install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace kube-system \
  --set nfs.server=192.168.50.14 \
  --set nfs.path=/srv/nfs/kubernetes \
  --set storageClass.name=nfs-client \
  --set storageClass.accessModes=ReadWriteMany \
  --set storageClass.reclaimPolicy=Retain \
  --set storageClass.archiveOnDelete=true

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
```

Verifikasi:

```bash
kubectl get storageclass
# nfs-client    cluster.local/nfs-provisioner-...   Retain   ...
# local-path    rancher.io/local-path               Delete   ...
```

## Langkah 6 — metrics-server

HPA di overlay ini aktif; tanpa metrics-server, `kubectl get hpa`
menampilkan `<unknown>/70%` dan tidak ada penskalaan:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# sertifikat kubelet kubeadm self-signed -> flag ini wajib, kalau tidak
# metrics-server CrashLoopBackOff:
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl top nodes    # harus menampilkan angka
```

## Langkah 7 — Build Image + Muat ke Worker

Build di komputer kerja dengan **tag versi** (bukan `latest` — tag unik
itulah yang membuat rollback bermakna):

```bash
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:v1   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:v1 .
```

Muat ke ketiga worker lewat SSH — `docker save` di sini, `ctr images
import` di sana (worker **tidak** berbagi daemon image dengan laptop Anda,
dan lab ini tidak memakai registry):

```bash
./scripts/muat-image-onprem.sh v1
```

Skrip mengimpor ke namespace containerd `k8s.io` — satu-satunya namespace
yang dibaca kubelet — lalu menampilkan verifikasi per worker. Yang
diharapkan di tiap worker:

```
      docker.io/laravel-app/nginx:v1
      docker.io/laravel-app/php:v1
```

> Untuk produksi sungguhan, jalur yang benar tetap registry (GHCR/Harbor)
> dengan overlay `onprem` — impor manual tidak terskala dan tidak punya
> jejak audit. Lab ini sengaja memilih jalan yang tidak butuh akun apa pun.

## Langkah 8 — Namespace + Secret

```bash
kubectl apply -f kubernetes/base/namespace.yaml
./scripts/create-secret.sh
```

`create-secret.sh` membuat `APP_KEY` dan password database **acak**
langsung di klaster — tidak ada rahasia yang menyentuh Git. Salinannya
ditulis ke `.env.local` (ter-gitignore).

> Ingat pelajaran dari verifikasi Docker Desktop: Secret ini **tidak**
> dikelola `kubectl apply -k` (secret.yaml sengaja tidak terdaftar di
> kustomization), jadi apply berikutnya tidak akan menimpanya dengan
> placeholder.

## Langkah 9 — Deploy

Lihat dulu apa yang akan dibuat (36 objek), baru terapkan:

```bash
kubectl kustomize kubernetes/overlays/onprem-lab | grep -c '^apiVersion'
kubectl apply -k kubernetes/overlays/onprem-lab
```

Tunggu berlapis — data dulu, lalu migrasi, lalu aplikasi:

```bash
kubectl -n laravel rollout status statefulset/mariadb --timeout=300s
kubectl -n laravel rollout status statefulset/redis   --timeout=180s
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=300s
kubectl -n laravel rollout status deployment/laravel-fpm   --timeout=300s
kubectl -n laravel rollout status deployment/laravel-nginx --timeout=180s
kubectl -n laravel rollout status deployment/laravel-queue --timeout=180s
```

Pastikan replika benar-benar tersebar ke tiga worker (overlay ini memakai
`DoNotSchedule`):

```bash
kubectl -n laravel get pods -o wide --sort-by=.spec.nodeName \
  -l 'app.kubernetes.io/name in (laravel-fpm,laravel-nginx)'
# 3 Pod fpm di 3 node berbeda; 3 Pod nginx juga.
```

## Langkah 10 — Verifikasi + Akses Browser

Checklist otomatis (24 pemeriksaan — di klaster ini `kubectl exec` normal,
jadi bagian aplikasi berjalan langsung, bukan lewat fallback Job):

```bash
./scripts/verify.sh
```

Akses dari browser komputer mana pun di LAN:

```
http://laravel.192.168.50.200.nip.io
```

> `nip.io` adalah DNS wildcard publik: nama
> `laravel.192.168.50.200.nip.io` otomatis me-resolve ke
> `192.168.50.200` — tidak perlu menyiapkan DNS internal. Syaratnya
> komputer Anda bisa mengakses internet untuk resolusi DNS. Alternatif
> tanpa internet: tambahkan baris
> `192.168.50.200 laravel.lab` ke berkas hosts, lalu ganti host di
> overlay menjadi `laravel.lab`.

Uji cepat dari terminal:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.192.168.50.200.nip.io/up   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://laravel.192.168.50.200.nip.io/.env # 403
```

## Langkah 11 — Uji NetworkPolicy (bonus Cilium)

Di Docker Desktop, NetworkPolicy tersimpan tetapi **tidak ditegakkan**.
Klaster ini memakai Cilium — sekarang kebijakan itu nyata. Buktikan:

```bash
# Pod TANPA label yang diizinkan -> HARUS timeout (kode keluar != 0)
kubectl -n laravel run penyusup --rm -it --restart=Never \
  --image=busybox:1.37 --labels='app=penyusup' \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"penyusup","image":"busybox:1.37","command":["sh","-c","nc -zv -w3 mariadb 3306; echo kode=$?"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"32Mi"}}}]}}'
# diharapkan: nc timeout, kode=1  <- database TIDAK bisa dijangkau Pod liar
```

Bila uji ini **berhasil menghubungi** mariadb, berarti kebijakan tidak
ditegakkan — periksa `kubectl get netpol -n laravel` (harus 7 objek) dan
kesehatan Pod Cilium.

---

## Rilis Berikutnya (v2, v3, ...)

```bash
# 1. build + muat dengan tag baru
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:v2   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:v2 .
./scripts/muat-image-onprem.sh v2

# 2. naikkan tag di overlay
cd kubernetes/overlays/onprem-lab
kustomize edit set image laravel-app/php=laravel-app/php:v2 \
                          laravel-app/nginx=laravel-app/nginx:v2
cd -

# 3. migrasi dulu (Job immutable -> hapus yang lama), lalu rollout
kubectl -n laravel delete job db-migrate --ignore-not-found
kubectl apply -k kubernetes/overlays/onprem-lab
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=300s
kubectl -n laravel rollout status deployment/laravel-fpm --timeout=300s
```

Rollback: `./scripts/rollback.sh` — image `v1` masih ada di containerd
worker, jadi kembali seketika. (Itulah kenapa tag `latest` dilarang: tanpa
tag unik, "versi sebelumnya" tidak punya nama.)

## Masalah yang Khas Jalur Tanpa-Registry

| Gejala | Penyebab | Solusi |
|---|---|---|
| `ImagePullBackOff` / `ErrImagePull` | image belum diimpor ke worker itu, ATAU diimpor ke namespace containerd yang salah | `./scripts/muat-image-onprem.sh <tag>`; verifikasi `sudo ctr -n k8s.io images ls` (harus `-n k8s.io`) |
| Pod baru `ImagePullBackOff` hanya di satu node | worker baru bergabung setelah impor terakhir | jalankan skrip lagi dengan daftar IP node barunya |
| Rilis baru "tidak berubah" | tag lama dipakai ulang untuk isi baru; kubelet melihat tag sudah ada, tidak memuat ulang | selalu naikkan tag (v2, v3, ...) — jangan menimpa tag |
| `exec format error` saat start | image dibangun untuk arsitektur berbeda (mis. laptop ARM, worker amd64) | build dengan `--platform linux/amd64` |
