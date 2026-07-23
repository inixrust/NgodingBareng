#!/usr/bin/env bash
# ============================================================================
# rollback.sh — kembalikan aplikasi ke revisi sebelumnya.
#
#   ./scripts/rollback.sh                 # mundur satu revisi
#   ./scripts/rollback.sh 3               # ke revisi tertentu
#
# CATATAN PENTING TENTANG MIGRASI
# Rollback ini hanya mengembalikan KODE, bukan SKEMA DATABASE. Bila rilis
# yang gagal sudah menjalankan migrasi yang merusak (drop kolom, ubah tipe),
# kode lama bisa saja tidak cocok lagi dengan skema baru.
#
# Karena itu aturan emasnya: tulis migrasi yang KOMPATIBEL MUNDUR.
# Tambah kolom baru sebagai nullable; jangan hapus kolom lama di rilis yang
# sama dengan kode yang berhenti memakainya -- pisahkan ke rilis berikutnya.
# ============================================================================
set -euo pipefail
NS="${NS:-laravel}"
REV="${1:-}"

for d in laravel-fpm laravel-nginx laravel-queue; do
    echo "== $d =="
    kubectl -n "$NS" rollout history deployment/"$d"
done

echo
if [ -n "$REV" ]; then
    read -r -p "Kembalikan ke revisi $REV? [y/N] " j
else
    read -r -p "Kembalikan ke revisi SEBELUMNYA? [y/N] " j
fi
[ "$j" = "y" ] || { echo "dibatalkan"; exit 1; }

for d in laravel-fpm laravel-nginx laravel-queue; do
    if [ -n "$REV" ]; then
        kubectl -n "$NS" rollout undo deployment/"$d" --to-revision="$REV"
    else
        kubectl -n "$NS" rollout undo deployment/"$d"
    fi
done

for d in laravel-fpm laravel-nginx laravel-queue; do
    kubectl -n "$NS" rollout status deployment/"$d" --timeout=300s
done

echo "rollback selesai; image sekarang:"
kubectl -n "$NS" get deploy -o custom-columns=NAMA:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
