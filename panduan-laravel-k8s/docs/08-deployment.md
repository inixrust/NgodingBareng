# 8. Deployment Lengkap

> **Ingin narasi run yang sesungguhnya?** Bagian 8.1 di bawah adalah jalur
> ideal (happy path). Untuk walkthrough lengkap sebuah run nyata — termasuk
> tiga kegagalan yang benar-benar muncul (LimitRange, Secret tertimpa, exec
> rusak) dan cara memecahkannya sampai `verify.sh` melaporkan 24/24 — lihat
> [docs/12](12-walkthrough-docker-desktop.md).

## 8.1 Docker Desktop (Development)

### Prasyarat

```bash
# Aktifkan Kubernetes: Docker Desktop → Settings → Kubernetes → Enable
kubectl config use-context docker-desktop
kubectl get nodes
# NAME             STATUS   ROLES           AGE   VERSION
# docker-desktop   Ready    control-plane   1d    v1.36.1
```

Alokasikan minimal **4 CPU dan 8 GB** RAM di Settings → Resources. Kurang dari
itu, MariaDB dan Redis akan berebut memori dengan Pod aplikasi.

### Langkah 1 — Ingress Controller (sekali per klaster)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml

kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

kubectl -n ingress-nginx get svc ingress-nginx-controller
# EXTERNAL-IP harus "localhost"
```

### Langkah 2 — Siapkan kode Laravel

```bash
cd panduan-laravel-k8s
composer create-project laravel/laravel src
# atau salin proyek yang sudah ada ke src/
```

### Langkah 3 — Build image

```bash
docker build -f docker/php/Dockerfile --target php   -t laravel-app/php:dev   .
docker build -f docker/php/Dockerfile --target nginx -t laravel-app/nginx:dev .

docker images | grep laravel-app
```

> **Tidak perlu push maupun `kind load`.** Docker Desktop berbagi daemon image
> dengan Kubernetes-nya, jadi image yang baru dibangun langsung terlihat.
> Ini berbeda dari kind dan minikube, yang memakai daemon terpisah.
>
> Tag `dev` dipakai, **bukan** `latest`. Tag `latest` memicu
> `imagePullPolicy: Always` secara implisit, dan Kubernetes akan mencari image
> itu di Docker Hub lalu gagal dengan `ImagePullBackOff` — meskipun image-nya
> ada di daemon lokal.

### Langkah 4 — Deploy

```bash
./scripts/deploy.sh docker-desktop
```

Atau manual, langkah demi langkah:

```bash
kubectl apply -f kubernetes/base/namespace.yaml
./scripts/create-secret.sh
kubectl apply -k kubernetes/overlays/docker-desktop
```

### Langkah 5 — Verifikasi

```bash
kubectl -n laravel get pods -w
```

Yang diharapkan terlihat:

```
NAME                             READY   STATUS      RESTARTS   AGE
db-migrate-x7k2p                 0/1     Completed   0          1m
laravel-fpm-6d9f4b8c7-abcde      1/1     Running     0          2m
laravel-nginx-7c8d5f9a2-fghij    1/1     Running     0          2m
laravel-queue-5b7c9d8e1-klmno    1/1     Running     0          2m
laravel-scheduler-29385720-pqrst 0/1     Completed   0          30s
mariadb-0                        1/1     Running     0          3m
redis-0                          1/1     Running     0          3m
redis-cache-8f9a2b3c4-uvwxy      1/1     Running     0          3m
```

```bash
kubectl -n laravel get svc,ingress,pvc
./scripts/verify.sh
```

### Langkah 6 — Akses aplikasi

```bash
curl -I http://laravel.localhost
```

Buka **http://laravel.localhost** di browser.

`*.localhost` sudah di-resolve ke `127.0.0.1` oleh semua sistem operasi
modern, jadi **tidak perlu mengedit berkas hosts**.

Bila tetap gagal, gunakan port-forward sebagai jalan pintas untuk memisahkan
masalah Ingress dari masalah aplikasi:

```bash
kubectl -n laravel port-forward svc/laravel-web 8080:80
# http://localhost:8080 — bila ini jalan, masalahnya di Ingress, bukan aplikasi
```

## 8.2 Klaster kubeadm (On-Premise)

```
Control plane : 192.168.50.14
Worker        : 192.168.50.15, 192.168.50.16, 192.168.50.17
```

### Langkah 1 — Menghubungkan kubectl

**Dari mesin kerja Anda:**

```bash
# Salin kubeconfig dari control plane
mkdir -p ~/.kube
scp user@192.168.50.14:/etc/kubernetes/admin.conf ~/.kube/config-onprem

# Sertifikat control plane biasanya hanya sah untuk IP internalnya;
# pastikan server-nya menunjuk alamat yang benar
sed -i 's#server: https://.*:6443#server: https://192.168.50.14:6443#' ~/.kube/config-onprem

export KUBECONFIG=~/.kube/config-onprem
kubectl get nodes -o wide
```

**Menggabungkan beberapa kubeconfig** supaya bisa berpindah klaster dengan
satu perintah:

```bash
KUBECONFIG=~/.kube/config:~/.kube/config-onprem kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config

kubectl config get-contexts
kubectl config use-context kubernetes-admin@kubernetes
```

> **Kebiasaan yang menyelamatkan.** Selalu jalankan
> `kubectl config current-context` sebelum `apply`. Menerapkan manifest
> development ke klaster produksi adalah kesalahan yang mudah dilakukan dan
> mahal untuk diperbaiki.

Verifikasi keempat Node:

```bash
kubectl get nodes -o wide
# NAME      STATUS   ROLES           VERSION   INTERNAL-IP
# cp1       Ready    control-plane   v1.35.x   192.168.50.14
# worker1   Ready    <none>          v1.35.x   192.168.50.15
# worker2   Ready    <none>          v1.35.x   192.168.50.16
# worker3   Ready    <none>          v1.35.x   192.168.50.17

# Beri label peran worker (dipakai nodeSelector MetalLB)
for w in worker1 worker2 worker3; do
  kubectl label node $w node-role.kubernetes.io/worker="" --overwrite
done
```

### Langkah 2 — Komponen tingkat klaster (sekali saja)

Urutannya penting: MetalLB harus siap sebelum Ingress Controller meminta IP.

```bash
# --- a. MetalLB ---
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl -n metallb-system rollout status deployment/controller --timeout=180s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=180s

# PERIKSA DULU rentang IP-nya bebas (lihat docs/04 bagian 4.5)
nmap -sn 192.168.50.200-240
kubectl apply -f infra/metallb-config.yaml

# --- b. Storage ---
# Klien NFS di SEMUA worker — sering terlupa, dan gejalanya menyesatkan
for n in 15 16 17; do ssh 192.168.50.$n 'sudo apt install -y nfs-common'; done

helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  -n kube-system \
  --set nfs.server=192.168.50.14 \
  --set nfs.path=/srv/nfs/kubernetes \
  --set storageClass.name=nfs-client \
  --set storageClass.accessModes=ReadWriteMany \
  --set storageClass.reclaimPolicy=Retain

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

# --- c. Ingress Controller ---
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx scale deployment/ingress-nginx-controller --replicas=3
kubectl apply -f infra/metallb-config.yaml   # menjadikan Service-nya LoadBalancer

kubectl -n ingress-nginx get svc ingress-nginx-controller
# EXTERNAL-IP harus 192.168.50.200 (bukan <pending>)

# --- d. metrics-server (dibutuhkan HPA) ---
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Verifikasi seluruh fondasi:

```bash
kubectl get storageclass
kubectl -n metallb-system get pods
kubectl -n ingress-nginx get svc
kubectl top nodes
```

### Langkah 3 — Registry

Node kubeadm **tidak** berbagi daemon Docker dengan mesin Anda, jadi image
wajib berada di registry yang bisa dijangkau ketiga worker.

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

TAG=v1.0.0
REG=ghcr.io/organisasi

docker build -f docker/php/Dockerfile --target php   -t $REG/laravel-php:$TAG   .
docker build -f docker/php/Dockerfile --target nginx -t $REG/laravel-nginx:$TAG .
docker push $REG/laravel-php:$TAG
docker push $REG/laravel-nginx:$TAG

# Kredensial agar Node bisa menarik dari registry privat
kubectl apply -f kubernetes/base/namespace.yaml
kubectl -n laravel create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=USERNAME \
  --docker-password=$GITHUB_TOKEN
```

### Langkah 4 — Sesuaikan overlay

```bash
cd kubernetes/overlays/onprem
kustomize edit set image laravel-app/php=$REG/laravel-php:$TAG
kustomize edit set image laravel-app/nginx=$REG/laravel-nginx:$TAG
cd -
```

### Langkah 5 — Deploy

```bash
./scripts/create-secret.sh

# Selalu lihat dulu apa yang akan berubah
kubectl diff -k kubernetes/overlays/onprem

kubectl apply -k kubernetes/overlays/onprem
```

### Langkah 6 — Verifikasi seluruh resource

```bash
kubectl -n laravel get all
kubectl -n laravel get pvc,ingress,netpol,hpa,pdb

# Pastikan replika benar-benar tersebar ke tiga worker
kubectl -n laravel get pods -o wide \
  --sort-by=.spec.nodeName -l app.kubernetes.io/name=laravel-fpm
```

Yang diharapkan: tiga Pod di tiga Node berbeda. Bila menumpuk di satu Node,
periksa `topologySpreadConstraints` dan taint pada Node.

```bash
# PVC harus Bound, bukan Pending
kubectl -n laravel get pvc
# NAME              STATUS   CAPACITY   STORAGECLASS
# laravel-storage   Bound    5Gi        nfs-client
# data-mariadb-0    Bound    20Gi       local-path
# data-redis-0      Bound    2Gi        local-path

# HPA harus menampilkan angka, bukan <unknown>
kubectl -n laravel get hpa
```

### Langkah 7 — Uji koneksi antar Pod

```bash
# a. DNS Service
kubectl -n laravel run uji-dns --rm -it --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
  -- nslookup laravel-fpm
# harus: laravel-fpm.laravel.svc.cluster.local

# b. Nginx -> PHP-FPM
POD=$(kubectl -n laravel get pod -l app.kubernetes.io/name=laravel-nginx -o name | head -1)
kubectl -n laravel exec $POD -- wget -qO- http://127.0.0.1:8080/up

# c. PHP-FPM -> database
kubectl -n laravel exec deploy/laravel-fpm -c php-fpm -- php artisan db:show

# d. PHP-FPM -> Redis
kubectl -n laravel exec deploy/laravel-fpm -c php-fpm -- \
  php -r '$r=new Redis(); $r->connect("redis",6379); echo $r->ping(), PHP_EOL;'

# e. NetworkPolicy benar-benar menolak yang tidak berhak
kubectl -n laravel run penyusup --rm -it --restart=Never --image=busybox:1.37 \
  --labels='app=penyusup' \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
  -- sh -c 'nc -zv -w3 mariadb 3306; echo "kode keluar: $?"'
# HARUS timeout. Bila berhasil, CNI Anda tidak menegakkan NetworkPolicy.
```

### Langkah 8 — Uji akses Ingress

```bash
# Dari mesin di LAN yang sama
curl -I http://laravel.192.168.50.200.nip.io

# Atau dengan header Host eksplisit, tanpa bergantung DNS
curl -H 'Host: laravel.192.168.50.200.nip.io' http://192.168.50.200/up
```

Buka **http://laravel.192.168.50.200.nip.io** di browser.

Untuk domain sendiri, tambahkan A record `laravel.perusahaan.co.id →
192.168.50.200`, lalu ubah host di overlay.

### Langkah 9 — Rolling update tanpa downtime

```bash
TAG=v1.1.0
docker build -f docker/php/Dockerfile --target php   -t $REG/laravel-php:$TAG   .
docker build -f docker/php/Dockerfile --target nginx -t $REG/laravel-nginx:$TAG .
docker push $REG/laravel-php:$TAG && docker push $REG/laravel-nginx:$TAG

cd kubernetes/overlays/onprem
kustomize edit set image laravel-app/php=$REG/laravel-php:$TAG
kustomize edit set image laravel-app/nginx=$REG/laravel-nginx:$TAG
cd -

# Migrasi lebih dulu, dan TUNGGU sampai selesai
kubectl -n laravel delete job db-migrate --ignore-not-found
kubectl apply -k kubernetes/overlays/onprem
kubectl -n laravel wait --for=condition=complete job/db-migrate --timeout=600s

# Pantau rollout
kubectl -n laravel rollout status deployment/laravel-fpm
kubectl -n laravel rollout status deployment/laravel-nginx
```

**Membuktikan benar-benar tanpa downtime** — jalankan di terminal terpisah
*sebelum* memulai rollout:

```bash
while true; do
  printf '%s %s\n' "$(date +%T)" \
    "$(curl -s -o /dev/null -w '%{http_code}' \
       -H 'Host: laravel.192.168.50.200.nip.io' http://192.168.50.200/up)"
  sleep 0.5
done
```

Seluruh keluaran harus `200`. Satu pun `502` atau `503` berarti ada yang perlu
diperbaiki — biasanya `preStop` yang terlalu pendek atau `readinessProbe` yang
terlalu longgar.

**Yang membuatnya bekerja:**

| Setelan | Perannya |
|---|---|
| `maxUnavailable: 0` | tidak boleh ada Pod hilang sebelum penggantinya siap |
| `maxSurge: 1` | satu Pod ekstra dibuat lebih dulu |
| `readinessProbe` | Pod baru tidak menerima trafik sampai benar-benar siap |
| `preStop: sleep 5` | memberi kube-proxy waktu mencabut Pod lama dari EndpointSlice |
| `terminationGracePeriodSeconds` | request yang sedang berjalan diselesaikan |

### Langkah 10 — Rollback

```bash
kubectl -n laravel rollout history deployment/laravel-fpm

# Mundur satu revisi
kubectl -n laravel rollout undo deployment/laravel-fpm
kubectl -n laravel rollout undo deployment/laravel-nginx

# Atau ke revisi tertentu
kubectl -n laravel rollout undo deployment/laravel-fpm --to-revision=3

kubectl -n laravel rollout status deployment/laravel-fpm
```

Atau: `./scripts/rollback.sh`

> **Rollback tidak mengembalikan skema database.** Bila rilis yang gagal
> sudah menjalankan migrasi yang merusak, kode lama bisa jadi tidak cocok
> lagi dengan skema baru.
>
> Karena itu aturan emasnya: **tulis migrasi yang kompatibel mundur**. Tambah
> kolom baru sebagai nullable; jangan hapus kolom lama di rilis yang sama
> dengan kode yang berhenti memakainya — pisahkan ke rilis berikutnya.

**Menghentikan rollout yang sedang berjalan dan bermasalah:**

```bash
kubectl -n laravel rollout pause deployment/laravel-fpm
# periksa...
kubectl -n laravel rollout resume deployment/laravel-fpm   # lanjutkan
# atau
kubectl -n laravel rollout undo deployment/laravel-fpm     # batalkan
```

---

Berikutnya: [09-troubleshooting.md](09-troubleshooting.md)
