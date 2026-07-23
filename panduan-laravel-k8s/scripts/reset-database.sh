#!/usr/bin/env bash
# ============================================================================
# reset-database.sh — benar-benar menghapus data database dan mulai dari nol.
#
# KENAPA SKRIP INI DIBUTUHKAN
# Menghapus StatefulSet TIDAK menghapus PVC-nya (itu memang disengaja, untuk
# melindungi data). Dan pada provisioner hostpath/local-path, menghapus PVC
# pun belum tentu menghapus direktori di disk: provisioner memetakan
# direktori berdasarkan NAMA PVC, sehingga PVC baru dengan nama sama akan
# MEMAKAI KEMBALI data lama.
#
# Akibatnya sangat membingungkan: Anda mengganti DB_PASSWORD di Secret,
# deploy ulang, dan MariaDB tetap menolak login -- karena tabel mysql.user
# di datadir lama masih menyimpan password sebelumnya.
# ============================================================================
set -euo pipefail
NS="${1:-laravel}"

echo "Ini akan MENGHAPUS SELURUH DATA database di namespace $NS."
read -r -p "Ketik 'HAPUS' untuk melanjutkan: " jawab
[ "$jawab" = "HAPUS" ] || { echo "dibatalkan"; exit 1; }

kubectl -n "$NS" delete statefulset mariadb --ignore-not-found
kubectl -n "$NS" wait --for=delete pod/mariadb-0 --timeout=120s 2>/dev/null || true
kubectl -n "$NS" delete pvc data-mariadb-0 --ignore-not-found

echo
echo "PVC dihapus. Bila provisioner Anda memakai reclaimPolicy Retain,"
echo "direktori datanya masih ada di disk dan harus dibersihkan manual:"
echo "  kubectl get pv | grep Released"
echo
echo "Deploy ulang dengan: ./scripts/deploy.sh <environment>"
