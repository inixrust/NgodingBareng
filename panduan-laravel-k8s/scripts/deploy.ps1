# ============================================================================
# deploy.ps1 — versi PowerShell dari deploy.sh, untuk Windows tanpa Git Bash.
#
#   .\scripts\deploy.ps1 -Environment docker-desktop
#   .\scripts\deploy.ps1 -Environment onprem -Registry ghcr.io/organisasi -Tag v1.2.3
# ============================================================================
[CmdletBinding()]
param(
    [ValidateSet('docker-desktop', 'onprem')]
    [string]$Environment = 'docker-desktop',
    [string]$Registry,
    [string]$Tag,
    [string]$Namespace = 'laravel'
)

$ErrorActionPreference = 'Stop'
$Akar    = Split-Path -Parent $PSScriptRoot
$Overlay = Join-Path $Akar "kubernetes/overlays/$Environment"

function Langkah($teks) { Write-Host "`n==> $teks" -ForegroundColor Cyan }

if (-not (Test-Path $Overlay)) { throw "Overlay tidak ada: $Overlay" }

# --------------------------------------------------------------- 1. Build
if ($Environment -eq 'docker-desktop') {
    if (-not $Tag) { $Tag = 'dev' }
    Langkah "Build image lokal (tag: $Tag)"
    # Docker Desktop berbagi daemon image dengan Kubernetes-nya, jadi build
    # saja sudah cukup — tidak perlu push ke registry mana pun.
    docker build -f "$Akar/docker/php/Dockerfile" --target php   -t "laravel-app/php:$Tag"   $Akar
    if (-not $?) { throw 'build image php gagal' }
    docker build -f "$Akar/docker/php/Dockerfile" --target nginx -t "laravel-app/nginx:$Tag" $Akar
    if (-not $?) { throw 'build image nginx gagal' }
}
else {
    if (-not $Registry -or -not $Tag) {
        throw 'Untuk onprem wajib memberi -Registry dan -Tag'
    }
    Langkah "Build dan push ke $Registry (tag: $Tag)"
    docker build -f "$Akar/docker/php/Dockerfile" --target php   -t "$Registry/laravel-php:$Tag"   $Akar
    docker build -f "$Akar/docker/php/Dockerfile" --target nginx -t "$Registry/laravel-nginx:$Tag" $Akar
    docker push "$Registry/laravel-php:$Tag"
    docker push "$Registry/laravel-nginx:$Tag"

    Langkah 'Menetapkan tag image di overlay'
    Push-Location $Overlay
    try {
        kustomize edit set image "laravel-app/php=$Registry/laravel-php:$Tag"
        kustomize edit set image "laravel-app/nginx=$Registry/laravel-nginx:$Tag"
    } finally { Pop-Location }
}

# ----------------------------------------------------------- 2. Namespace
Langkah 'Menyiapkan namespace'
kubectl apply -f (Join-Path $Akar 'kubernetes/base/namespace.yaml')

# -------------------------------------------------------------- 3. Secret
kubectl -n $Namespace get secret laravel-secret 2>$null | Out-Null
if (-not $?) {
    Langkah 'Membuat laravel-secret dengan nilai acak'

    # APP_KEY Laravel = 32 byte acak dalam base64.
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $AppKey = 'base64:' + [Convert]::ToBase64String($bytes)

    function SandiAcak {
        $b = New-Object byte[] 24
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
        ([Convert]::ToBase64String($b) -replace '[/+=]', '').Substring(0, 20)
    }
    $DbPass     = SandiAcak
    $DbRootPass = SandiAcak

    kubectl -n $Namespace create secret generic laravel-secret `
        --from-literal=APP_KEY=$AppKey `
        --from-literal=DB_PASSWORD=$DbPass `
        --from-literal=DB_ROOT_PASSWORD=$DbRootPass `
        --from-literal=REDIS_PASSWORD=''

    Set-Content -Path (Join-Path $Akar '.env.local') -Encoding utf8 -Value @"
# Dibuat otomatis oleh scripts/deploy.ps1 — JANGAN DI-COMMIT.
APP_KEY=$AppKey
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=$DbPass
DB_ROOT_PASSWORD=$DbRootPass
"@
    Write-Host '    Salinan untuk Docker Compose ditulis ke .env.local'
}
else {
    Write-Host '    laravel-secret sudah ada, dilewati'
}

# ------------------------------------------------------- 4. Job lama dihapus
# spec Job bersifat immutable; apply kedua kalinya gagal tanpa langkah ini.
kubectl -n $Namespace delete job db-migrate --ignore-not-found | Out-Null

# --------------------------------------------------------------- 5. Apply
Langkah "Menerapkan overlay: $Environment"
kubectl apply -k $Overlay
if (-not $?) { throw 'kubectl apply gagal' }

# --------------------------------------------- 6. Pemicu rollout konfigurasi
Langkah 'Menyinkronkan checksum konfigurasi'
$konfig = kubectl -n $Namespace get configmap laravel-config -o yaml | Out-String
$sha = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($konfig))
$hash = ([BitConverter]::ToString($sha) -replace '-', '').Substring(0, 16).ToLower()
foreach ($d in 'laravel-fpm', 'laravel-queue') {
    kubectl -n $Namespace patch deployment $d `
        -p "{`"spec`":{`"template`":{`"metadata`":{`"annotations`":{`"checksum/config`":`"$hash`"}}}}}" | Out-Null
}

# --------------------------------------------------- 7. Tunggu dan verifikasi
Langkah 'Menunggu database dan cache siap'
kubectl -n $Namespace rollout status statefulset/mariadb --timeout=300s
kubectl -n $Namespace rollout status statefulset/redis   --timeout=120s

Langkah 'Menunggu migrasi selesai'
kubectl -n $Namespace wait --for=condition=complete job/db-migrate --timeout=300s
if (-not $?) {
    Write-Host 'MIGRASI GAGAL:' -ForegroundColor Red
    kubectl -n $Namespace logs job/db-migrate --tail=50
    throw 'migrasi gagal'
}

Langkah 'Menunggu aplikasi siap'
foreach ($d in 'laravel-fpm', 'laravel-nginx', 'laravel-queue') {
    kubectl -n $Namespace rollout status deployment/$d --timeout=300s
}

Langkah 'Selesai'
kubectl -n $Namespace get pods,svc,ingress
