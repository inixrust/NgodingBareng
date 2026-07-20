# L4.2 — SOLUSI

`readOnlyRootFilesystem` tetap **true**. Yang ditambahkan hanya tiga direktori
yang memang harus writable.

## Tiga direktori dan jenis volumenya

| Direktori | Volume | Alasan |
| --- | --- | --- |
| `/var/www/html/storage` | PVC | Unggahan pengguna, log, sesi — harus bertahan |
| `/var/www/html/bootstrap/cache` | emptyDir | Cache config/route/view, dibangun ulang tiap start |
| `/tmp` | emptyDir | Berkas sementara PHP dan perkakas |

## Diverifikasi end-to-end

| Uji | Hasil |
| --- | --- |
| Starter diterapkan | CrashLoopBackOff — `mkdir: can't create directory 'storage/app/private': Read-only file system` |
| Solusi diterapkan | `successfully rolled out` |
| `php artisan tinker` | berjalan, berkat `HOME=/tmp` |
| `touch /coba` | ditolak — rootfs tetap read-only |

## Jebakan tersembunyi: HOME

Setelah pod Ready, `php artisan tinker` **masih** gagal:
`Writing to directory /home/www-data/.config/psysh is not allowed`.

Home bawaan `www-data` ada di rootfs yang read-only. Solusinya menyetel
`HOME=/tmp` — `/tmp` sudah tersedia sebagai emptyDir writable, jadi tidak perlu
melonggarkan apa pun.

## Kesalahan yang sering terjadi

- Memasang seluruh `/var/www/html` sebagai emptyDir. Kode aplikasi tertimpa
  direktori kosong dan aplikasi tidak jalan sama sekali.
- Memakai PVC untuk `bootstrap/cache`. Tidak perlu — isinya dibangun ulang tiap
  start, dan PVC hanya menambah ketergantungan tanpa manfaat.
- Menyerah lalu mematikan `readOnlyRootFilesystem`. Itu membuang lapisan
  pertahanan demi kenyamanan.

## Membersihkan

```powershell
kubectl delete -f lab\solution\L4.2-readonly-rootfs\deployment.yaml --ignore-not-found
```
