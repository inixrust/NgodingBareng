# =============================================================================
# cek.ps1 — verifikasi otomatis seluruh solusi lab
#
# Untuk FASILITATOR. Jalankan sebelum kelas dimulai, dan setiap kali ada
# perubahan pada proyek, untuk memastikan seluruh solusi masih berjalan.
#
#     .\lab\cek.ps1
#     .\lab\cek.ps1 -Lewati L1.1,L2.5      # lewati yang lama (build image)
# =============================================================================
param([string[]]$Lewati = @())

$ErrorActionPreference = "Continue"
$root = (Resolve-Path "$PSScriptRoot\..").Path
Push-Location $root

$hasil = [ordered]@{}

function Uji($kode, $nama, $blok) {
    if ($Lewati -contains $kode) {
        Write-Host ("  [LEWAT] {0,-22} {1}" -f $kode, $nama) -ForegroundColor DarkGray
        $hasil[$kode] = "LEWAT"; return
    }
    Write-Host ("  [ .. ] {0,-22} {1}" -f $kode, $nama) -NoNewline
    try {
        $ok = & $blok
        if ($ok) {
            Write-Host "`r  [LULUS] $kode".PadRight(70) -ForegroundColor Green
            $hasil[$kode] = "LULUS"
        } else {
            Write-Host "`r  [GAGAL] $kode  $nama".PadRight(70) -ForegroundColor Red
            $hasil[$kode] = "GAGAL"
        }
    } catch {
        Write-Host "`r  [GAGAL] $kode  $($_.Exception.Message)".PadRight(70) -ForegroundColor Red
        $hasil[$kode] = "GAGAL"
    }
}

Write-Host "`n  Verifikasi solusi lab`n" -ForegroundColor White

# --- Hari 1 ------------------------------------------------------------------
Uji "L1.1" "Dockerfile urutan benar" {
    docker build -q -t lab-cek-l11 -f lab/solution/L1.1-cache-build/Dockerfile . 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    # bangun lagi: seluruh langkah harus CACHED
    $log = docker build -t lab-cek-l11 -f lab/solution/L1.1-cache-build/Dockerfile . 2>&1
    ($log | Select-String "CACHED").Count -ge 3
}

Uji "L1.4" "dockerignore lengkap" {
    $isi = Get-Content lab/solution/L1.4-dockerignore/dockerignore.solution -Raw
    $wajib = @(".env", "src/vendor", "src/node_modules", "src/public/hot")
    ($wajib | Where-Object { $isi -notmatch [regex]::Escape($_) }).Count -eq 0
}

# --- Hari 2 ------------------------------------------------------------------
Uji "L2.1" "compose mailpit sah" {
    $out = docker compose -f compose.yaml -f compose.override.yaml `
        -f lab/solution/L2.1-service-baru/compose.lab.yaml config 2>&1 | Out-String
    ($out -match "mailpit") -and ($out -match "backend")
}

Uji "L2.4" "JobGagal sintaksis sah" {
    docker run --rm -v "${root}/lab/solution/L2.4-job-gagal:/w" -w /w `
        php:8.4-cli-alpine php -l JobGagal.php 2>&1 | Out-Null
    $LASTEXITCODE -eq 0
}

Uji "L2.5" "Dockerfile tanpa config:cache" {
    $isi = Get-Content lab/solution/L2.5-config-cache/Dockerfile -Raw
    if ($isi -match "RUN php artisan config:cache") { return $false }
    $ep = Get-Content lab/solution/L2.5-config-cache/entrypoint.sh -Raw
    $ep -match "config:cache"
}

# --- Hari 3 ------------------------------------------------------------------
Uji "L3.5" "overlay staging ter-render" {
    $tmp = Join-Path $env:TEMP "lab-l35"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path "k8s\overlays\staging" -Force | Out-Null
    Copy-Item lab/solution/L3.5-overlay-staging/* k8s/overlays/staging/ -Force
    Copy-Item k8s/overlays/staging/secrets.env.example k8s/overlays/staging/secrets.env -Force
    $out = kubectl kustomize k8s/overlays/staging 2>&1 | Out-String
    Remove-Item k8s/overlays/staging -Recurse -Force -ErrorAction SilentlyContinue
    ($out -match "namespace: laravel-staging") -and `
    ($out -match "LOG_LEVEL: debug") -and ($out -match "replicas: 1")
}

# --- Hari 4 ------------------------------------------------------------------
Uji "L4.1" "pod lolos Pod Security" {
    $out = kubectl apply -f lab/solution/L4.1-pod-security/pod.yaml --dry-run=server 2>&1 | Out-String
    $out -notmatch "forbidden"
}

Uji "L4.1n" "starter memang DITOLAK" {
    $out = kubectl apply -f lab/starter/L4.1-pod-security/pod.yaml --dry-run=server 2>&1 | Out-String
    $out -match "violates PodSecurity"
}

Uji "L4.2" "deployment read-only sah" {
    $out = kubectl apply -f lab/solution/L4.2-readonly-rootfs/deployment.yaml --dry-run=server 2>&1 | Out-String
    $isi = Get-Content lab/solution/L4.2-readonly-rootfs/deployment.yaml -Raw
    ($out -notmatch "forbidden") -and ($isi -match "readOnlyRootFilesystem: true") -and `
    ($isi -match "name: HOME")
}

# --- Ringkasan ---------------------------------------------------------------
docker rmi lab-cek-l11 -f 2>&1 | Out-Null
Pop-Location

$lulus = ($hasil.Values | Where-Object { $_ -eq "LULUS" }).Count
$gagal = ($hasil.Values | Where-Object { $_ -eq "GAGAL" }).Count
Write-Host "`n  Ringkasan: $lulus lulus, $gagal gagal, $($hasil.Count) diperiksa" -ForegroundColor White
if ($gagal -gt 0) { Write-Host "  Perbaiki dulu sebelum kelas dimulai.`n" -ForegroundColor Yellow; exit 1 }
Write-Host "  Seluruh solusi berjalan.`n" -ForegroundColor Green
