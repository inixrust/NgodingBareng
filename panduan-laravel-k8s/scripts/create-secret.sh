#!/usr/bin/env bash
# ============================================================================
# create-secret.sh — membuat laravel-secret dengan nilai acak.
#
# Rahasia dibuat DI KLASTER dan tidak pernah menyentuh repositori. Berkas
# kubernetes/base/secret.yaml hanya contoh struktur, bukan sumber nilainya.
#
# APP_KEY yang dihasilkan di sini disimpan juga ke .env.local supaya bisa
# dipakai Docker Compose. Jangan meng-commit berkas itu (.gitignore sudah
# mengecualikannya).
# ============================================================================
set -euo pipefail

NS="${NS:-laravel}"
AKAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

acak() { openssl rand -base64 "${1:-24}" | tr -d '\n/+=' | cut -c1-"${2:-24}"; }

APP_KEY="base64:$(openssl rand -base64 32)"
DB_PASSWORD="$(acak 32 24)"
DB_ROOT_PASSWORD="$(acak 32 24)"

kubectl -n "$NS" create secret generic laravel-secret \
    --from-literal=APP_KEY="$APP_KEY" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    --from-literal=REDIS_PASSWORD="" \
    --dry-run=client -o yaml | kubectl apply -f -

# --dry-run=client | kubectl apply dipakai (bukan `kubectl create` langsung)
# supaya perintah ini idempoten: dijalankan ulang akan memperbarui, bukan
# gagal dengan "already exists".

cat > "$AKAR/.env.local" <<EOF
# Dibuat otomatis oleh scripts/create-secret.sh — JANGAN DI-COMMIT.
APP_KEY=$APP_KEY
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
EOF

echo "laravel-secret dibuat di namespace $NS"
echo "salinan untuk Docker Compose ditulis ke .env.local"
echo
echo "PERINGATAN: mengganti APP_KEY pada aplikasi yang sudah berjalan membuat"
echo "seluruh sesi dan kolom terenkripsi tidak bisa dibaca lagi."
