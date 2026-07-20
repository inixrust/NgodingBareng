#!/usr/bin/env bash
# =============================================================================
# env.sh — variabel bersama + pemeriksaan prasyarat lab (bash / WSL)
#
# Jalankan dengan source agar variabelnya tetap ada di sesi Anda:
#     source lab/env.sh
# =============================================================================

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LAB_ROOT/.." && pwd)"
export LAB_ROOT PROJECT_ROOT
export LAB_STARTER="$LAB_ROOT/starter"
export LAB_SOLUTION="$LAB_ROOT/solution"
export LAB_NS="laravel"
export LAB_NS_STG="laravel-staging"

printf '\n  Lab: Kontainerisasi Laravel 13 hingga Produksi di Kubernetes\n'
printf '  Akar proyek : %s\n\n' "$PROJECT_ROOT"

gagal=0
cek() {
    nama="$1"; hasil="$2"; saran="$3"
    if [ -n "$hasil" ]; then
        printf '  [ OK ] %-22s %s\n' "$nama" "$hasil"
    else
        printf '  [GAGAL] %-22s %s\n' "$nama" "$saran"
        gagal=$((gagal + 1))
    fi
}

cek "Docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    "Jalankan Docker Desktop lebih dulu."
cek "Docker Compose" "$(docker compose version --short 2>/dev/null)" \
    "Perbarui Docker Desktop."
cek "Kubernetes" "$(kubectl config current-context 2>/dev/null)" \
    "Aktifkan Kubernetes di Docker Desktop > Settings > Kubernetes."
cek "Node cluster siap" \
    "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' | grep -v '^0$')" \
    "Tunggu cluster selesai start, lalu ulangi."
cek "Berkas .env proyek" \
    "$([ -f "$PROJECT_ROOT/.env" ] && echo ada)" \
    "Salin .env.example menjadi .env lalu isi APP_KEY dan password."
cek "src/composer.json" \
    "$([ -f "$PROJECT_ROOT/src/composer.json" ] && echo ada)" \
    "Beberapa lab memakai berkas ini sebagai build context."

printf '\n'
if [ "$gagal" -gt 0 ]; then
    printf '  %s prasyarat belum terpenuhi. Perbaiki dulu sebelum mulai.\n\n' "$gagal"
else
    printf '  Seluruh prasyarat terpenuhi. Selamat mengerjakan.\n\n'
fi
