# L2.5 — Cache Konfigurasi di Waktu yang Salah

Temukan penyebabnya di `Dockerfile.bermasalah`, **buktikan** dengan pengukuran,
lalu perbaiki.

```powershell
docker build -t lab-l25:bermasalah -f lab\starter\L2.5-config-cache\Dockerfile.bermasalah .
```

Untuk membuktikan: jalankan container dari image itu dengan `DB_HOST` yang
sengaja dibuat berbeda, lalu bandingkan nilai config yang benar-benar dipakai
aplikasi dengan nilai environment yang Anda berikan.

**Perhatikan tanda kutip.** Pakai kutip tunggal di dalam kode PHP dan kutip
ganda untuk variabel PowerShell. Terbalik, PowerShell menelan kutipnya dan PHP
gagal dengan "Undefined constant".

```powershell
$k   = "base64:bGFiLWNvbmZpZy1jYWNoZS1kdW1teS1rZXktMzJieXRlcw=="
$cek = "echo config('database.connections.mysql.host'), PHP_EOL;"
docker run --rm -e DB_HOST=host-yang-berbeda -e APP_KEY=$k `
    --entrypoint php lab-l25:bermasalah artisan tinker --execute=$cek
```

**Yang harus terlihat:** keluarannya BUKAN `host-yang-berbeda`. Itu buktinya.

## Membersihkan

```powershell
docker rmi lab-l25:bermasalah
```
