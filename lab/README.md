# Starter Kit & Solusi Lab

Berkas kerja untuk latihan mandiri pada Panduan Peserta.

Dari 21 latihan, **8 di antaranya punya berkas untuk dikerjakan** — itulah yang
disediakan di sini. Tiga belas latihan sisanya bersifat investigasi (menjalankan
perintah, membaca keluaran, menyimpulkan) dan tidak memerlukan berkas starter.

## Struktur

```
lab/
├── README.md
├── env.ps1              # PowerShell — pemeriksaan prasyarat + variabel bersama
├── env.sh               # bash/WSL — setara env.ps1
├── cek.ps1              # verifikasi otomatis seluruh solusi (untuk fasilitator)
├── starter/             # DIKERJAKAN PESERTA — berisi penanda TODO
│   ├── L1.1-cache-build/
│   ├── L1.4-dockerignore/
│   ├── L2.1-service-baru/
│   ├── L2.4-job-gagal/
│   ├── L2.5-config-cache/
│   ├── L3.5-overlay-staging/
│   ├── L4.1-pod-security/
│   └── L4.2-readonly-rootfs/
└── solution/            # ACUAN FASILITATOR — siap jalan, sudah diuji
    └── (struktur sama persis)
```

## Cara memakai

**Peserta** — kerjakan di dalam `starter/`. Setiap berkas memuat penanda:

```
# TODO [3] — Pindahkan baris ini agar cache composer tidak ikut batal
```

Nomor dalam kurung siku **cocok dengan nomor langkah** di bagian Langkah
Penyelesaian pada Solusi Acuan. Jadi bila peserta buntu di TODO [3], fasilitator
langsung tahu langkah mana yang perlu dibahas.

**Fasilitator** — `solution/` berisi versi yang sudah jalan. Jangan dibagikan
sebelum latihan selesai.

## Menjalankan

Seluruh perintah dijalankan dari **akar proyek** (`NgodingBarengAI/`), bukan dari
dalam `lab/`. Beberapa lab memakai `src/composer.json` milik proyek sebagai
build context.

```powershell
# 1. Muat variabel dan periksa prasyarat
. .\lab\env.ps1

# 2. Kerjakan satu lab, mis. L1.1
Get-Content lab\starter\L1.1-cache-build\README.md
```

## Verifikasi

Fasilitator dapat memastikan seluruh solusi masih berjalan setelah ada perubahan
pada proyek:

```powershell
.\lab\cek.ps1
```

Skrip itu membangun ulang setiap solusi dan memvalidasi setiap manifest, lalu
melaporkan LULUS atau GAGAL per lab. Jalankan sebelum kelas dimulai.

## Daftar lab dan latihan pasangannya

| Lab | Latihan | Yang dikerjakan |
| --- | --- | --- |
| L1.1-cache-build | L1.1 | Mengurutkan ulang instruksi Dockerfile |
| L1.4-dockerignore | L1.4 | Menyusun `.dockerignore` |
| L2.1-service-baru | L2.1 | Menambah service Mailpit ke Compose |
| L2.4-job-gagal | L2.4 | Membuat job yang gagal, melacak penyebabnya |
| L2.5-config-cache | L2.5 | Menemukan `config:cache` di waktu yang salah |
| L3.5-overlay-staging | L3.5 | Membuat overlay Kustomize baru |
| L4.1-pod-security | L4.1 | Memperbaiki manifest yang ditolak Pod Security |
| L4.2-readonly-rootfs | L4.2 | Menemukan direktori yang perlu writable |

Latihan tanpa berkas starter: L1.2, L1.3, L2.2, L2.3, L2.6, L2.7, L3.1, L3.2,
L3.3, L3.4, L4.3, L4.4, L4.5.
