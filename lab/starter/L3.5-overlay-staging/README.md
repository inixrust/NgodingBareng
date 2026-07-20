# L3.5 — Membuat Overlay Staging

Salin direktori ini ke `k8s/overlays/staging/`, lalu kerjakan di sana:

```powershell
Copy-Item lab\starter\L3.5-overlay-staging k8s\overlays\staging -Recurse
```

Buat juga `secrets.env` di dalamnya — contoh isiannya ada di
`k8s/overlays/local/secrets.env.example`.

Periksa hasilnya **tanpa menerapkan**:

```powershell
kubectl kustomize k8s/overlays/staging
kubectl kustomize k8s/overlays/staging | Select-String "namespace:|replicas:|LOG_LEVEL"
```

**Yang harus terlihat:** seluruh objek di namespace `laravel-staging`, Deployment
`app` dengan `replicas: 1`, dan `LOG_LEVEL: debug`.

Syarat mutlak: `k8s/base/` tidak boleh diubah sama sekali. Periksa dengan
`git status` — bila ada berkas di `k8s/base/` yang termodifikasi, latihan belum
selesai dengan benar.

## Membersihkan

```powershell
Remove-Item k8s\overlays\staging -Recurse -Force
```
