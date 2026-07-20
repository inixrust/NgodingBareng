# L2.1 — Menambah Service Baru ke Stack

Lengkapi `compose.lab.yaml`, lalu jalankan dari **akar proyek**:

```powershell
docker compose -f compose.yaml -f compose.override.yaml `
    -f lab\starter\L2.1-service-baru\compose.lab.yaml up -d
docker compose ps
```

Ubah tiga variabel di `.env` (MAIL_MAILER, MAIL_HOST, MAIL_PORT), lalu kirim
email percobaan lewat tinker.

**Yang harus terlihat:** email muncul di <http://localhost:8025>.

Bila aplikasi gagal menyambung, periksa satu hal lebih dulu: apakah service Anda
berada di jaringan yang sama dengan `app`? Service bisa menyala normal dan tetap
tidak dapat dihubungi bila jaringannya berbeda.

## Membersihkan

```powershell
docker compose -f compose.yaml -f compose.override.yaml `
    -f lab\starter\L2.1-service-baru\compose.lab.yaml down
```
