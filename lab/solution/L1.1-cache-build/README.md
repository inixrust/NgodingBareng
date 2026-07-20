# L1.1 — SOLUSI

Perubahannya **hanya urutan**: manifest dependensi disalin dan dipasang lebih
dulu, kode aplikasi menyusul.

## Kenapa berhasil

Cache sebuah layer batal bila instruksinya berubah **atau** ada layer di bawahnya
yang berubah. Dengan `COPY src/ ./` berada di BAWAH `composer install`, perubahan
kode tidak lagi menyentuh layer composer.

## Hasil pengukuran

Diverifikasi pada stack acuan, setelah mengubah satu baris di `src/routes/web.php`:

| Versi | Waktu build |
| --- | --- |
| starter (urutan salah) | 9,6 detik |
| solution (urutan benar) | 1,2 detik |

Angka pastinya berbeda tiap mesin; yang dinilai adalah **selisih besarannya**.

## Kesalahan yang sering terjadi

- Memindahkan `COPY src/ ./` ke bawah tetapi lupa menyalin `composer.json` dan
  `composer.lock` lebih dulu — build gagal karena manifest tidak ditemukan.
- Menambahkan `--no-cache` "supaya bersih". Itu justru mematikan satu-satunya
  mekanisme yang mempercepat build.

**Diterima juga:** menambahkan cache mount BuildKit (`RUN --mount=type=cache,...`).
Bahkan lebih baik — asalkan urutan instruksinya tetap dibetulkan lebih dulu.
