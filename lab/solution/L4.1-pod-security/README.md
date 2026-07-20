# L4.1 — SOLUSI

## Pesan penolakan yang harus dibaca peserta

```
Error from server (Forbidden): error when creating "pod.yaml":
pods "latihan-pss" is forbidden: violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "alat" must set
    securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "alat" must set
    securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "alat" must set
    securityContext.runAsNonRoot=true),
  seccompProfile (pod or container "alat" must set
    securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Empat pelanggaran, dan pesannya menyebut persis apa yang kurang. Ini titik ajar
yang penting: **Pod Security memberi tahu dengan tepat apa yang harus diperbaiki** —
peserta tidak perlu menebak.

## Pembagian tingkat

| Setelan | Tingkat | Catatan |
| --- | --- | --- |
| `runAsNonRoot` | pod atau container | Lebih rapi di pod — berlaku untuk semua |
| `seccompProfile` | pod atau container | Lebih rapi di pod |
| `allowPrivilegeEscalation` | **container saja** | Tidak ada di tingkat pod |
| `capabilities.drop` | **container saja** | Tidak ada di tingkat pod |

## Kenapa menurunkan label BUKAN penyelesaian

Yang bermasalah adalah **manifest-nya**, bukan kebijakannya. Menurunkan label
melonggarkan aturan untuk **seluruh** beban kerja di namespace itu — termasuk
yang sudah benar — demi satu pod yang belum disesuaikan.

Dan dalam praktiknya, kebijakan keamanan yang dilonggarkan karena satu kasus
jarang dikembalikan lagi.

## Kesalahan yang sering terjadi

- Menaruh seluruh setelan di tingkat container. Berhasil, tetapi kurang rapi —
  dan akan berulang untuk setiap container bila kelak ada lebih dari satu.
- Menyetel `runAsUser: 0`. Itu tetap root dan tetap ditolak.
- Lupa `resources`. Tidak diwajibkan Pod Security, tetapi praktik yang baik.

## Verifikasi

```powershell
kubectl apply -f lab\solution\L4.1-pod-security\pod.yaml
kubectl get pod latihan-pss -n laravel
kubectl delete pod latihan-pss -n laravel
```
