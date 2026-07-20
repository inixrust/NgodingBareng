# L4.1 — Memperbaiki Manifest yang Ditolak

```powershell
kubectl apply -f lab\starter\L4.1-pod-security\pod.yaml
```

**Baca pesan penolakannya dengan teliti.** Pod Security menyebut persis apa yang
kurang — Anda tidak perlu menebak. Ada empat pelanggaran.

Perbaiki `pod.yaml`, lalu terapkan ulang sampai pod berstatus Running:

```powershell
kubectl get pod latihan-pss -n laravel
```

Petunjuk: sebagian setelan hanya ada di tingkat **container**, sebagian boleh di
tingkat **pod**. Tentukan mana yang mana dari pesan penolakannya sendiri.

## Membersihkan

```powershell
kubectl delete pod latihan-pss -n laravel --ignore-not-found
```
