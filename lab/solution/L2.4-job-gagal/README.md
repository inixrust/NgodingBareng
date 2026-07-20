# L2.4 — SOLUSI

## Menjalankan

```powershell
Copy-Item lab\solution\L2.4-job-gagal\JobGagal.php src\app\Jobs\ -Force

docker compose exec app php artisan tinker --execute="App\Jobs\JobGagal::dispatch();"

# Amati percobaan ulang — beri jeda, ada backoff antar percobaan
docker compose logs horizon --tail 30

# Daftar job yang gagal permanen
docker compose exec app php artisan queue:failed

# Jalankan ulang
docker compose exec app php artisan queue:retry all
```

## Jawaban

**Berapa kali dicoba.** Tiga kali, sesuai `tries` di `src/config/horizon.php`.
Bila nilainya diubah, jumlah percobaan ikut berubah.

**Di mana catatan kegagalan disimpan.** Di tabel `failed_jobs` pada **database**,
bukan di Redis. Ini titik yang sering keliru: antreannya memang di Redis, tetapi
catatan job yang gagal permanen disimpan di database agar tetap ada walaupun
Redis dikosongkan. Dilihat dengan `queue:failed` atau tab Failed Jobs di Horizon.

**Pesan aslinya.** `RuntimeException: Sengaja gagal untuk latihan L2.4.` beserta
jejak tumpukan yang menunjuk ke `handle()` pada `JobGagal`.

**Menjalankan ulang.** `php artisan queue:retry <uuid>` untuk satu job, atau
`queue:retry all`.

## Kesalahan yang sering terjadi

Peserta menyimpulkan job hanya dicoba **sekali** karena hanya membaca beberapa
baris terakhir log. Percobaan ulang berjarak beberapa detik (`backoff`) — perlu
menunggu sebelum membaca ulang.

## Poin yang layak ditekankan

Job yang gagal permanen **tidak memunculkan error apa pun di sisi pengguna**.
Request web sudah selesai jauh sebelumnya. Inilah alasan pemantauan antrean tidak
bisa diabaikan: kegagalannya senyap.

## Membersihkan

```powershell
docker compose exec app php artisan queue:flush
Remove-Item src\app\Jobs\JobGagal.php
```
