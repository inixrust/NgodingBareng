# L1.4 — SOLUSI

Lihat `dockerignore.solution` — setiap entri disertai alasannya.

## Tiga kategori

1. **Rahasia** — `.env` dan turunannya. Image dikirim ke registry; siapa pun yang
   bisa menariknya dapat membaca password database dan `APP_KEY`. Mengganti
   password setelah bocor tidak menghapus image lama yang sudah beredar.
2. **Dependensi yang dibangun ulang** — `vendor/` dan `node_modules/`. Dipasang
   ulang di stage vendor dan assets; mengirimkannya hanya memperlambat build.
3. **Artefak runtime dan mode pengembangan** — terutama `public/hot`.

## Yang paling sering terlewat: public/hot

Berkas itu dibuat Vite saat mode pengembangan dan berisi alamat dev server
(`http://localhost:5173`). Bila ikut ke produksi, Laravel menganggap dev server
sedang berjalan dan memuat **seluruh** aset dari alamat itu — di server, semua
CSS dan JavaScript gagal dimuat dan tampilan rusak total.

## Cara menilai

Peserta yang hanya menyebut `vendor` dan `node_modules` berfokus pada **ukuran**
dan melewatkan `.env`. Ukuran hanyalah efek samping; kebocoran rahasia adalah
risiko utamanya.
