#!/usr/bin/env bash
# ============================================================================
# muat-image-onprem.sh — kirim image lokal ke containerd setiap worker,
# TANPA registry.
#
#   ./scripts/muat-image-onprem.sh v1
#   ./scripts/muat-image-onprem.sh v2 "192.168.50.15 192.168.50.16"
#
# Cara kerjanya:
#   docker save  -> arsip tar image di mesin build (Windows/laptop)
#   ssh + ctr    -> arsip dialirkan lewat ssh dan diimpor ke containerd
#                   worker, ke namespace "k8s.io" (namespace image yang
#                   dibaca kubelet — impor ke namespace default TIDAK
#                   terlihat oleh Kubernetes)
#
# Kenapa cara ini untuk lab: worker kubeadm tidak berbagi daemon image
# dengan mesin build, dan lab tidak selalu punya registry. Untuk produksi
# sungguhan tetap pakai registry (overlay "onprem") — impor manual tidak
# terskala dan tidak punya jejak audit.
# ============================================================================
set -euo pipefail

TAG="${1:?pakai: $0 <tag> [\"ip-worker ...\"]}"
WORKERS="${2:-192.168.50.15 192.168.50.16 192.168.50.17}"
SSH_USER="${SSH_USER:-student}"

for IMG in "laravel-app/php:$TAG" "laravel-app/nginx:$TAG"; do
    docker image inspect "$IMG" >/dev/null 2>&1 \
        || { echo "image $IMG belum ada — build dulu"; exit 1; }
done

for W in $WORKERS; do
    echo "==> $W"
    for IMG in "laravel-app/php:$TAG" "laravel-app/nginx:$TAG"; do
        echo "    kirim $IMG ..."
        # -n k8s.io: namespace containerd yang dipakai kubelet.
        # sudo di sisi remote karena soket containerd milik root.
        docker save "$IMG" | ssh "$SSH_USER@$W" "sudo ctr -n k8s.io images import -"
    done
    echo "    verifikasi:"
    ssh "$SSH_USER@$W" "sudo ctr -n k8s.io images ls | grep laravel-app | awk '{print \"      \" \$1}'"
done

echo
echo "Selesai. Pastikan tag di overlay cocok:"
echo "  cd kubernetes/overlays/onprem-lab && kustomize edit set image \\"
echo "    laravel-app/php=laravel-app/php:$TAG laravel-app/nginx=laravel-app/nginx:$TAG"
