#!/usr/bin/env bash
# Melihat log seluruh komponen sekaligus.
#   ./scripts/logs.sh          -> semua Pod aplikasi
#   ./scripts/logs.sh queue    -> hanya queue worker
set -euo pipefail
NS="${NS:-laravel}"
KOMPONEN="${1:-}"

case "$KOMPONEN" in
    fpm)       SEL="app.kubernetes.io/name=laravel-fpm" ;;
    nginx)     SEL="app.kubernetes.io/name=laravel-nginx" ;;
    queue)     SEL="app.kubernetes.io/name=laravel-queue" ;;
    scheduler) SEL="app.kubernetes.io/name=laravel-scheduler" ;;
    db)        SEL="app.kubernetes.io/name=mariadb" ;;
    *)         SEL="app.kubernetes.io/part-of=laravel-stack" ;;
esac

# --prefix menandai baris dengan nama Pod asalnya; wajib saat menonton
# beberapa replika sekaligus.
kubectl -n "$NS" logs -l "$SEL" --all-containers --prefix --tail=100 -f
