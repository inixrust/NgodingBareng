# L1.4 — Menemukan Berkas yang Seharusnya Tidak Ikut

## Yang dikerjakan

Lengkapi `dockerignore.starter` sehingga build context hanya berisi yang
benar-benar dibutuhkan.

## Langkah

Dijalankan dari **akar proyek**.

```powershell
# 1. Cadangkan .dockerignore milik proyek
Copy-Item .dockerignore .dockerignore.asli

# 2. Pasang versi starter dan ukur build context
Copy-Item lab\starter\L1.4-dockerignore\dockerignore.starter .dockerignore
docker build -f docker\php\Dockerfile --target base -t lab-l14 .
#    perhatikan baris "transferring context" di awal keluaran

# 3. Lengkapi .dockerignore, lalu ukur ulang

# 4. Pastikan rahasia tidak ada di dalam image produksi
docker build -f docker\php\Dockerfile --target app -t lab-l14:app .
docker run --rm --entrypoint sh lab-l14:app -c "ls -a /var/www/html | grep -c env"
```

## Yang harus terlihat

Ukuran context turun drastis (ratusan MB menjadi satuan MB), dan pemeriksaan
`.env` mengembalikan angka **0**.

## Membersihkan

```powershell
Move-Item .dockerignore.asli .dockerignore -Force
docker rmi lab-l14 lab-l14:app
```
