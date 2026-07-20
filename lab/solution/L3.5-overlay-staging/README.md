# L3.5 — SOLUSI

Base tidak disentuh sama sekali. Seluruh perbedaan lingkungan hidup di overlay.

## Menjalankan

```powershell
Copy-Item lab\solution\L3.5-overlay-staging k8s\overlays\staging -Recurse
Copy-Item k8s\overlays\staging\secrets.env.example k8s\overlays\staging\secrets.env
kubectl kustomize k8s/overlays/staging | Select-String "namespace:|replicas:|LOG_LEVEL"
```

## Tiga keputusan yang dinilai

**`behavior: merge` pada configMapGenerator.** Menimpa hanya kunci yang disebut;
kunci lain tetap diambil dari base. Tanpa itu, peserta cenderung menyalin ulang
seluruh `app-config.env` — berfungsi, tetapi setiap perbaikan di base harus
dikerjakan dua kali.

**`secrets.env` sendiri untuk staging.** Berbagi rahasia antar lingkungan berarti
kebocoran di satu lingkungan langsung menjadi kebocoran di lingkungan lain.

**Base tidak diubah.** Periksa dengan `git status` — bila ada berkas di
`k8s/base/` yang termodifikasi, latihan belum selesai dengan benar.

## Diterima juga

Memakai kunci `replicas:` bawaan Kustomize sebagai ganti patch JSON. Keduanya benar.

## Membersihkan

```powershell
Remove-Item k8s\overlays\staging -Recurse -Force
```
