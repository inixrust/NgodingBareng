# L1.1 — Mengurutkan Ulang Dockerfile

## Yang dikerjakan

Perbaiki `Dockerfile` di direktori ini sehingga perubahan kode PHP tidak lagi
membatalkan pemasangan dependensi. **Ubah hanya urutan instruksi.**

## Mengukur sebelum dan sesudah

Seluruh perintah dijalankan dari **akar proyek**.

```powershell
# Build pertama (mengisi cache)
docker build -t lab-l11:starter -f lab\starter\L1.1-cache-build\Dockerfile .

# Ubah satu baris kode, lalu ukur build berikutnya
Add-Content src\routes\web.php "// uji cache"
Measure-Command {
  docker build -t lab-l11:starter -f lab\starter\L1.1-cache-build\Dockerfile .
}
```

Catat angkanya. Perbaiki Dockerfile, lalu ulangi pengukuran yang sama.

## Yang harus terlihat

Sesudah perbaikan, baris `composer install` menampilkan **CACHED** dan build
selesai dalam hitungan detik.

## Membersihkan

```powershell
git checkout src\routes\web.php    # buang baris uji
docker rmi lab-l11:starter
```
