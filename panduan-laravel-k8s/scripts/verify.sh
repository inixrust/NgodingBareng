#!/usr/bin/env bash
# ============================================================================
# verify.sh — daftar periksa deployment, dijalankan sebagai pengujian nyata.
#
#   ./scripts/verify.sh [namespace]
#
# Setiap baris benar-benar MENGUJI, bukan sekadar menampilkan. Keluar dengan
# kode != 0 bila ada yang gagal, sehingga bisa dipakai sebagai gerbang CI.
# ============================================================================
set -uo pipefail

NS="${1:-laravel}"
LULUS=0
GAGAL=0

ok()    { printf '  \033[0;32m[ OK ]\033[0m %s\n' "$1"; LULUS=$((LULUS+1)); }
nok()   { printf '  \033[0;31m[GAGAL]\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; GAGAL=$((GAGAL+1)); }
babak() { printf '\n\033[1m%s\033[0m\n' "$1"; }

uji() {  # uji "nama" "perintah" [pola-yang-diharapkan]
    local nama="$1" cmd="$2" pola="${3:-}"
    local out
    out=$(eval "$cmd" 2>&1)
    if [ $? -ne 0 ]; then nok "$nama" "$(echo "$out" | head -1)"; return; fi
    if [ -n "$pola" ] && ! echo "$out" | grep -qE "$pola"; then
        nok "$nama" "diharapkan cocok '$pola', dapat: $(echo "$out" | head -1)"; return
    fi
    ok "$nama"
}

babak "1. Workload"
# awk (bukan grep|wc): dengan pipefail, grep yang TIDAK menemukan apa-apa --
# yaitu keadaan sehat -- keluar dengan kode 1 dan menggagalkan pemeriksaan.
uji "Semua Pod Running atau Completed" \
    "kubectl -n $NS get pods --no-headers | awk '\$3!~/Running|Completed/{n++} END{print n+0}'" '^0$'
uji "Tidak ada container yang belum Ready" \
    "kubectl -n $NS get pods --no-headers --field-selector=status.phase=Running \
     | awk '{split(\$2,a,\"/\"); if(a[1]!=a[2]) print}' | wc -l" '^\s*0$'
uji "Deployment laravel-fpm tersedia" \
    "kubectl -n $NS get deploy laravel-fpm -o jsonpath='{.status.availableReplicas}'" '^[1-9]'
uji "Deployment laravel-nginx tersedia" \
    "kubectl -n $NS get deploy laravel-nginx -o jsonpath='{.status.availableReplicas}'" '^[1-9]'
uji "Deployment laravel-queue tersedia" \
    "kubectl -n $NS get deploy laravel-queue -o jsonpath='{.status.availableReplicas}'" '^[1-9]'
uji "StatefulSet mariadb siap" \
    "kubectl -n $NS get sts mariadb -o jsonpath='{.status.readyReplicas}'" '^[1-9]'
uji "StatefulSet redis siap" \
    "kubectl -n $NS get sts redis -o jsonpath='{.status.readyReplicas}'" '^[1-9]'

babak "2. Stabilitas (tidak ada restart TAK NORMAL)"
# Jumlah restart mentah MENYESATKAN untuk stack ini: queue worker sengaja
# keluar bersih (exit 0) tiap jam karena --max-time=3600, lalu dihidupkan
# ulang oleh restartPolicy Always. Itu daur-ulang yang sehat, bukan crash.
#
# Yang benar-benar gejala buruk adalah terminasi TAK NORMAL: OOMKilled atau
# Error (exit != 0) — itulah tanda probe terlalu ketat, memory limit
# kekecilan, atau aplikasi crash. Kita periksa lastState.terminated.reason
# tiap container, bukan angka restart.
# awk (bukan grep|wc): dengan pipefail, grep yang TIDAK menemukan apa-apa --
# yaitu keadaan SEHAT di sini -- keluar kode 1 dan menggagalkan pemeriksaan.
# awk menghitung sendiri dan selalu exit 0.
uji "Tidak ada container yang mati OOMKilled/Error" \
    "kubectl -n $NS get pods -o jsonpath='{range .items[*].status.containerStatuses[*]}{.lastState.terminated.reason}{\"\n\"}{end}' \
     | awk '/OOMKilled|Error/{n++} END{print n+0}'" '^0$'

babak "3. Jaringan"
uji "Service laravel-web punya endpoint" \
    "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=laravel-web \
     -o jsonpath='{.items[*].endpoints[*].addresses[*]}'" '[0-9]+\.[0-9]+'
uji "Service laravel-fpm punya endpoint" \
    "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=laravel-fpm \
     -o jsonpath='{.items[*].endpoints[*].addresses[*]}'" '[0-9]+\.[0-9]+'
uji "Ingress sudah punya ADDRESS" \
    "kubectl -n $NS get ingress laravel -o jsonpath='{.status.loadBalancer.ingress[0]}'" '.'

babak "4. Penyimpanan"
uji "PVC laravel-storage Bound" \
    "kubectl -n $NS get pvc laravel-storage -o jsonpath='{.status.phase}'" '^Bound$'
uji "PVC database Bound" \
    "kubectl -n $NS get pvc data-mariadb-0 -o jsonpath='{.status.phase}'" '^Bound$'

POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=laravel-fpm \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# `kubectl exec` bisa rusak di level infrastruktur sementara klaster sehat
# (bug streaming CRI pada Docker Desktop tertentu; gejala: "http: server gave
# HTTP response to HTTPS client", padahal `kubectl logs` normal). Deteksi itu
# di sini, lalu jalankan pemeriksaan yang sama lewat Job + baca log.
EXEC_OK=true
if [ -n "$POD" ]; then
    kubectl -n "$NS" exec "$POD" -c php-fpm -- true >/dev/null 2>&1 || EXEC_OK=false
fi

if [ -n "$POD" ] && [ "$EXEC_OK" = "false" ]; then
    babak "5. Aplikasi (exec rusak — memakai fallback Job uji-dalam)"
    AKAR_SKRIP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IMG=$(kubectl -n "$NS" get deploy laravel-fpm \
          -o jsonpath='{.spec.template.spec.containers[0].image}')
    kubectl -n "$NS" delete job uji-dalam --ignore-not-found >/dev/null 2>&1
    sed "s|image: laravel-app/php:dev .*|image: $IMG|" \
        "$AKAR_SKRIP/uji-dalam-job.yaml" | kubectl apply -f - >/dev/null
    if kubectl -n "$NS" wait --for=condition=complete job/uji-dalam --timeout=180s >/dev/null 2>&1; then
        LOGJOB=$(kubectl -n "$NS" logs job/uji-dalam 2>/dev/null)
        cek_tanda() {  # cek_tanda "label" TANDA
            if echo "$LOGJOB" | grep -q "TANDA-$2=OK"; then ok "$1"
            else nok "$1" "$(echo "$LOGJOB" | grep "TANDA-$2" | head -1)"; fi
        }
        cek_tanda "storage/app/public bisa ditulis"  TULIS-STORAGE
        cek_tanda "bootstrap/cache bisa ditulis"     TULIS-BOOTSTRAP
        cek_tanda "Koneksi database berhasil"        DATABASE
        cek_tanda "Migrasi sudah dijalankan semua"   MIGRASI
        cek_tanda "Koneksi Redis berhasil"           REDIS
        cek_tanda "Cache Laravel berfungsi"          CACHE
        cek_tanda "Root filesystem read-only"        ROOTFS-RO
    else
        nok "Job uji-dalam tidak selesai" \
            "$(kubectl -n "$NS" logs job/uji-dalam 2>/dev/null | tail -1)"
    fi
elif [ -n "$POD" ]; then
    babak "5. Aplikasi (dijalankan di dalam Pod $POD)"
    uji "storage/app/public bisa ditulis" \
        "kubectl -n $NS exec $POD -c php-fpm -- sh -c \
         'touch storage/app/public/.uji-tulis && rm storage/app/public/.uji-tulis && echo bisa'" '^bisa$'
    uji "bootstrap/cache bisa ditulis" \
        "kubectl -n $NS exec $POD -c php-fpm -- sh -c \
         'touch bootstrap/cache/.uji && rm bootstrap/cache/.uji && echo bisa'" '^bisa$'
    uji "Koneksi database berhasil" \
        "kubectl -n $NS exec $POD -c php-fpm -- php artisan db:show" 'MariaDB|MySQL'
    uji "Migrasi sudah dijalankan semua" \
        "kubectl -n $NS exec $POD -c php-fpm -- php artisan migrate:status" 'Ran'
    uji "Koneksi Redis berhasil" \
        "kubectl -n $NS exec $POD -c php-fpm -- php -r \
         '\$r=new Redis();\$r->connect(getenv(\"REDIS_HOST\"),6379);echo \$r->ping();'" 'PONG|1'
    uji "Cache Laravel berfungsi" \
        "kubectl -n $NS exec $POD -c php-fpm -- php artisan tinker --execute \
         'cache()->put(\"uji\",\"nilai\",10); echo cache()->get(\"uji\");'" 'nilai'
    uji "Config sudah di-cache" \
        "kubectl -n $NS exec $POD -c php-fpm -- ls bootstrap/cache/" 'config.php'
else
    babak "5. Aplikasi"
    nok "Tidak ada Pod laravel-fpm untuk diuji"
fi

babak "6. Antrian dan scheduler"
uji "Queue worker berjalan" \
    "kubectl -n $NS get pods -l app.kubernetes.io/name=laravel-queue \
     --field-selector=status.phase=Running --no-headers | wc -l" '^\s*[1-9]'
uji "CronJob scheduler terjadwal" \
    "kubectl -n $NS get cronjob laravel-scheduler -o jsonpath='{.spec.suspend}'" '^false$|^$'
uji "Scheduler sudah pernah jalan" \
    "kubectl -n $NS get cronjob laravel-scheduler -o jsonpath='{.status.lastScheduleTime}'" '.'

babak "7. HTTP dari dalam klaster"
uji "Endpoint /up menjawab 200" \
    "kubectl -n $NS run uji-http-\$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.11.1 \
     --overrides='{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":1000,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"c\",\"image\":\"curlimages/curl:8.11.1\",\"command\":[\"curl\",\"-s\",\"-o\",\"/dev/null\",\"-w\",\"%{http_code}\",\"http://laravel-web/up\"],\"resources\":{\"requests\":{\"cpu\":\"50m\",\"memory\":\"64Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"128Mi\"}},\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}' \
     -- true" '200'
# ^ resources ditulis eksplisit: tanpa itu Pod memakai default LimitRange,
#   dan default yang tidak konsisten dengan maxLimitRequestRatio membuat
#   Pod uji ini ditolak admission.

printf '\n\033[1mHASIL: %d lulus, %d gagal\033[0m\n' "$LULUS" "$GAGAL"
[ "$GAGAL" -eq 0 ] || exit 1
