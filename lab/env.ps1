# =============================================================================
# env.ps1 — variabel bersama + pemeriksaan prasyarat lab (PowerShell)
#
# Jalankan dengan titik di depan agar variabelnya tetap ada di sesi Anda:
#     . .\lab\env.ps1
# =============================================================================

$ErrorActionPreference = "Continue"

# --- Variabel bersama --------------------------------------------------------
$env:LAB_ROOT     = (Resolve-Path "$PSScriptRoot").Path
$env:PROJECT_ROOT = (Resolve-Path "$PSScriptRoot\..").Path
$env:LAB_STARTER  = Join-Path $env:LAB_ROOT "starter"
$env:LAB_SOLUTION = Join-Path $env:LAB_ROOT "solution"
$env:LAB_NS       = "laravel"
$env:LAB_NS_STG   = "laravel-staging"

Write-Host ""
Write-Host "  Lab: Kontainerisasi Laravel 13 hingga Produksi di Kubernetes" -ForegroundColor White
Write-Host "  Akar proyek : $env:PROJECT_ROOT" -ForegroundColor DarkGray
Write-Host ""

# --- Pemeriksaan prasyarat ---------------------------------------------------
$gagal = 0

function Cek($nama, $blok, $saran) {
    try {
        $hasil = & $blok
        if ($hasil) {
            Write-Host ("  [ OK ] {0,-22} {1}" -f $nama, $hasil) -ForegroundColor Green
            return
        }
    } catch { }
    Write-Host ("  [GAGAL] {0,-22} {1}" -f $nama, $saran) -ForegroundColor Red
    $script:gagal++
}

Cek "Docker" { (docker version --format '{{.Server.Version}}' 2>$null) } `
    "Jalankan Docker Desktop lebih dulu."

Cek "Docker Compose" { (docker compose version --short 2>$null) } `
    "Perbarui Docker Desktop."

Cek "Kubernetes" { (kubectl config current-context 2>$null) } `
    "Aktifkan Kubernetes di Docker Desktop > Settings > Kubernetes."

Cek "Node cluster siap" {
    $s = kubectl get nodes --no-headers 2>$null
    if ($s -match "Ready") { "siap" }
} "Tunggu cluster selesai start, lalu ulangi."

Cek "Berkas .env proyek" {
    if (Test-Path (Join-Path $env:PROJECT_ROOT ".env")) { "ada" }
} "Salin .env.example menjadi .env lalu isi APP_KEY dan password."

Cek "src/composer.json" {
    if (Test-Path (Join-Path $env:PROJECT_ROOT "src\composer.json")) { "ada" }
} "Beberapa lab memakai berkas ini sebagai build context."

Write-Host ""
if ($gagal -gt 0) {
    Write-Host "  $gagal prasyarat belum terpenuhi. Perbaiki dulu sebelum mulai." -ForegroundColor Yellow
} else {
    Write-Host "  Seluruh prasyarat terpenuhi. Selamat mengerjakan." -ForegroundColor Green
}
Write-Host ""
