# L2.5 — SOLUSI

## Cara membuktikannya

Kunci latihan ini bukan menemukan barisnya — itu mudah setelah tahu. Kuncinya
adalah **membuktikan** dengan pengukuran.

```powershell
# Bangun versi bermasalah dan versi solusi
docker build -t lab-l25:bermasalah -f lab\starter\L2.5-config-cache\Dockerfile.bermasalah .
docker build -t lab-l25:solution   -f lab\solution\L2.5-config-cache\Dockerfile .

# Jalankan KEDUANYA dengan DB_HOST yang sengaja dibuat berbeda,
# lalu bandingkan nilai config yang benar-benar dipakai aplikasi.
#
# PENTING soal tanda kutip: pakai kutip TUNGGAL di dalam kode PHP dan kutip
# GANDA untuk variabel PowerShell. Terbalik, PowerShell akan menelan kutipnya
# dan PHP gagal dengan "Undefined constant".
$k    = "base64:bGFiLWNvbmZpZy1jYWNoZS1kdW1teS1rZXktMzJieXRlcw=="
$cek  = "echo config('database.connections.mysql.host'), PHP_EOL;"

docker run --rm -e DB_HOST=host-yang-berbeda -e APP_KEY=$k `
    --entrypoint php lab-l25:bermasalah artisan tinker --execute=$cek

docker run --rm -e DB_HOST=host-yang-berbeda -e APP_KEY=$k `
    --entrypoint php lab-l25:solution artisan tinker --execute=$cek
```

## Yang harus terlihat

Diverifikasi pada stack acuan:

| Image | Keluaran | Artinya |
| --- | --- | --- |
| `bermasalah` | `127.0.0.1` — nilai saat build | environment container **DIABAIKAN** |
| `solution` | `host-yang-berbeda` | environment container **dipakai** |

Selisih itulah buktinya.

## Jawaban

**Apa yang disimpan `config:cache`.** Seluruh hasil evaluasi berkas `config/` —
termasuk setiap pemanggilan `env()` — dibekukan menjadi satu berkas PHP di
`bootstrap/cache/config.php`. Setelah cache itu ada, `env()` **tidak lagi dibaca**
saat aplikasi berjalan.

**Kenapa nilai server tidak terpakai.** Perintah dijalankan saat `docker build`,
sehingga yang terbaca adalah environment mesin build. Tidak ada pesan error apa
pun — gejalanya senyap, dan aplikasi hanya memakai nilai yang salah.

**Kapan seharusnya dijalankan.** Saat runtime, di entrypoint, setelah environment
container tersedia.

## Kesalahan yang sering terjadi

- **Menyalahkan `.env` yang tidak ikut ke image.** Justru sebaliknya — `.env`
  memang tidak boleh ikut. Masalahnya pada waktu eksekusi `config:cache`.
- **Menambahkan `config:clear` di entrypoint sebagai perbaikan.** Gejalanya
  hilang, tetapi manfaat cache-nya ikut hilang. Yang benar adalah memindahkan
  waktu pembuatannya, bukan menghapusnya.

## Membersihkan

```powershell
docker rmi lab-l25:bermasalah lab-l25:solution
```
