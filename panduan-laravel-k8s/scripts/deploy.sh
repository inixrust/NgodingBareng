#!/usr/bin/env bash
# ============================================================================
# deploy.sh — build, push (bila perlu), lalu terapkan overlay.
#
#   ./scripts/deploy.sh docker-desktop
#   ./scripts/deploy.sh onprem ghcr.io/organisasi v1.2.3
# ============================================================================
set -euo pipefail

ENV="${1:-docker-desktop}"
REGISTRY="${2:-}"
TAG="${3:-}"

AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$AKAR/kubernetes/overlays/$ENV"
NS=laravel

[ -d "$OVERLAY" ] || { echo "overlay tidak ada: $OVERLAY"; exit 1; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# 1. Build image
# --------------------------------------------------------------------------
if [ "$ENV" = "docker-desktop" ]; then
    TAG="${TAG:-dev}"
    log "build image lokal (tag: $TAG)"
    # Docker Desktop berbagi daemon image dengan Kubernetes-nya, jadi build
    # saja sudah cukup. Tidak perlu push maupun `kind load`.
    docker build -f "$AKAR/docker/php/Dockerfile" --target php \
        -t "laravel-app/php:$TAG" "$AKAR"
    docker build -f "$AKAR/docker/php/Dockerfile" --target nginx \
        -t "laravel-app/nginx:$TAG" "$AKAR"
else
    [ -n "$REGISTRY" ] && [ -n "$TAG" ] || {
        echo "untuk $ENV wajib: ./scripts/deploy.sh $ENV <registry> <tag>"; exit 1; }

    log "build dan push ke $REGISTRY (tag: $TAG)"
    # Node kubeadm TIDAK berbagi daemon Docker dengan mesin ini, jadi image
    # harus ada di registry yang bisa dijangkau ketiga worker.
    docker build -f "$AKAR/docker/php/Dockerfile" --target php \
        -t "$REGISTRY/laravel-php:$TAG" "$AKAR"
    docker build -f "$AKAR/docker/php/Dockerfile" --target nginx \
        -t "$REGISTRY/laravel-nginx:$TAG" "$AKAR"
    docker push "$REGISTRY/laravel-php:$TAG"
    docker push "$REGISTRY/laravel-nginx:$TAG"

    log "menetapkan tag image di overlay"
    (cd "$OVERLAY" \
        && kustomize edit set image "laravel-app/php=$REGISTRY/laravel-php:$TAG" \
        && kustomize edit set image "laravel-app/nginx=$REGISTRY/laravel-nginx:$TAG")
fi

# --------------------------------------------------------------------------
# 2. Namespace lebih dulu
# --------------------------------------------------------------------------
# Namespace harus ada sebelum objek lain, kalau tidak apply pertama gagal
# dengan "namespaces laravel not found" untuk setiap objek.
log "menyiapkan namespace"
kubectl apply -f "$AKAR/kubernetes/base/namespace.yaml"

# --------------------------------------------------------------------------
# 3. Secret
# --------------------------------------------------------------------------
# Secret dibuat dari perintah, bukan dari berkas di repositori.
if ! kubectl -n "$NS" get secret laravel-secret >/dev/null 2>&1; then
    log "laravel-secret belum ada — membuat dengan nilai acak"
    "$AKAR/scripts/create-secret.sh"
else
    echo "    laravel-secret sudah ada, dilewati"
fi

# --------------------------------------------------------------------------
# 4. Job migrasi lama dihapus
# --------------------------------------------------------------------------
# spec sebuah Job bersifat immutable; apply kedua kalinya akan gagal dengan
# "field is immutable". Menghapusnya lebih dulu membuat deploy idempoten.
kubectl -n "$NS" delete job db-migrate --ignore-not-found >/dev/null

# --------------------------------------------------------------------------
# 5. Apply
# --------------------------------------------------------------------------
log "menerapkan overlay: $ENV"
kubectl apply -k "$OVERLAY"

# --------------------------------------------------------------------------
# 6. Pemicu rollout saat konfigurasi berubah
# --------------------------------------------------------------------------
# ConfigMap yang diubah TIDAK membuat Pod membaca ulang konfigurasinya --
# variabel lingkungan hanya dibaca saat container start. Anotasi ber-hash di
# bawah memaksa template Pod berubah, sehingga Deployment melakukan rollout.
log "menyinkronkan checksum konfigurasi"
# Dua perintah get terpisah lalu digabung — kubectl menolak mengambil
# ConfigMap dan Secret bernama spesifik dalam satu perintah (baik bentuk
# "cm x secret y" maupun "cm/x secret/y" tidak sah).
HASH=$( { kubectl -n "$NS" get configmap laravel-config -o yaml 2>/dev/null
          kubectl -n "$NS" get secret    laravel-secret -o yaml 2>/dev/null
        } | sha256sum | cut -c1-16)
for d in laravel-fpm laravel-queue; do
    kubectl -n "$NS" patch deployment "$d" \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$HASH\"}}}}}" \
        >/dev/null
done

# --------------------------------------------------------------------------
# 7. Tunggu dan verifikasi
# --------------------------------------------------------------------------
log "menunggu database dan cache siap"
kubectl -n "$NS" rollout status statefulset/mariadb --timeout=300s
kubectl -n "$NS" rollout status statefulset/redis --timeout=120s

log "menunggu migrasi selesai"
# Job harus SUKSES sebelum aplikasi menerima trafik: aplikasi versi baru bisa
# saja mengandalkan kolom yang belum ada.
kubectl -n "$NS" wait --for=condition=complete job/db-migrate --timeout=300s \
    || { echo "MIGRASI GAGAL:"; kubectl -n "$NS" logs job/db-migrate --tail=50; exit 1; }

log "menunggu aplikasi siap"
kubectl -n "$NS" rollout status deployment/laravel-fpm --timeout=300s
kubectl -n "$NS" rollout status deployment/laravel-nginx --timeout=300s
kubectl -n "$NS" rollout status deployment/laravel-queue --timeout=300s

log "selesai"
kubectl -n "$NS" get pods,svc,ingress
echo
echo "Jalankan ./scripts/verify.sh untuk daftar periksa lengkap."
