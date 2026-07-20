# L2.4 — Melacak Job yang Gagal

Lengkapi `JobGagal.php`, salin ke proyek, lalu kirim ke antrean:

```powershell
Copy-Item lab\starter\L2.4-job-gagal\JobGagal.php src\app\Jobs\ -Force
docker compose exec app php artisan tinker --execute="App\Jobs\JobGagal::dispatch();"
```

Amati — **beri jeda beberapa detik**, ada backoff antar percobaan:

```powershell
docker compose logs horizon --tail 30
docker compose exec app php artisan queue:failed
```

**Yang harus terlihat:** beberapa baris `JobGagal ... FAIL`, lalu satu entri di
daftar job gagal.

Petunjuk untuk pertanyaan "di mana catatan kegagalan disimpan": antreannya ada
di Redis — tetapi apakah catatan KEGAGALAN juga di sana? Periksa, jangan menebak.

## Membersihkan

```powershell
docker compose exec app php artisan queue:flush
Remove-Item src\app\Jobs\JobGagal.php
```
