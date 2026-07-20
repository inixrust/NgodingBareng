# L4.2 — Menemukan Direktori yang Perlu Writable

## Yang dikerjakan

Perbaiki `deployment.yaml` sampai pod mencapai **Ready** — tanpa mematikan
`readOnlyRootFilesystem`.

## Cara menguji direktori satu per satu

Setelah pod berjalan (walau belum Ready), uji dari dalam container:

```powershell
$pod = kubectl get pod -n laravel -l app.kubernetes.io/name=latihan-ro `
       -o jsonpath="{.items[0].metadata.name}"

# Buktikan rootfs memang read-only
kubectl exec -n laravel $pod -- sh -c "touch /coba"

# Uji tiap direktori yang dicurigai
kubectl exec -n laravel $pod -- sh -c "touch /var/www/html/storage/uji         && echo BISA || echo TIDAK BISA"
kubectl exec -n laravel $pod -- sh -c "touch /var/www/html/bootstrap/cache/uji && echo BISA || echo TIDAK BISA"
kubectl exec -n laravel $pod -- sh -c "touch /tmp/uji                          && echo BISA || echo TIDAK BISA"
```

Bila pod terus gagal start sehingga tidak sempat di-`exec`, baca lognya:

```powershell
kubectl logs -n laravel -l app.kubernetes.io/name=latihan-ro
```

Pesan kegagalan biasanya menyebut path yang gagal ditulis.

## Setelah pod Ready

Masih ada satu perkakas yang gagal:

```powershell
kubectl exec -n laravel deploy/latihan-ro -- php artisan tinker --execute="echo 1;"
```

Baca pesan errornya — ia menunjuk ke sebuah direktori yang belum terpikirkan.

## Membersihkan

```powershell
kubectl delete -f lab\starter\L4.2-readonly-rootfs\deployment.yaml
```
