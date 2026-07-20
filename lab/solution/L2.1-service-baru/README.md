# L2.1 — SOLUSI

## Jawaban atas pertanyaan di starter

**(a) Port mana yang dipublikasikan?** Hanya `8025`. Antarmuka web dibuka manusia
dari browser di Windows, jadi harus dijangkau dari luar container. Port `1025`
(SMTP) dihubungi container `app` dari dalam jaringan `backend` — mempublikasikannya
tidak memberi manfaat dan hanya menambah permukaan yang terbuka.

**(b) Kunci wajib.** `networks: [backend]`. Tanpa itu, Compose menaruh mailpit di
jaringan default-nya sendiri. Service tetap menyala dan `docker compose ps` tampak
normal — tetapi aplikasi gagal me-resolve nama `mailpit`. Ini kesalahan yang
paling sering terjadi pada latihan ini, dan gejalanya menyesatkan karena tidak ada
yang terlihat salah dari daftar service.

**Kenapa MAIL_HOST bukan `localhost`.** Di dalam container, `localhost` menunjuk
ke container **itu sendiri** — bukan mesin host, bukan container lain. Koneksi
ditolak karena tidak ada yang mendengarkan di port 1025 di dalam container aplikasi.

## Menjalankan

```powershell
docker compose -f compose.yaml -f compose.override.yaml `
    -f lab\solution\L2.1-service-baru\compose.lab.yaml up -d
```

Ubah di `.env`:

```dotenv
MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
```

Lalu kirim email percobaan:

```powershell
docker compose exec app php artisan tinker `
  --execute="Mail::raw('uji lab', fn(`$m) => `$m->to('a@b.c')->subject('Uji'));"
```

Buka <http://localhost:8025> — email harus muncul di sana.

## Membersihkan

```powershell
docker compose -f compose.yaml -f compose.override.yaml `
    -f lab\solution\L2.1-service-baru\compose.lab.yaml down
```
