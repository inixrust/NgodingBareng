<?php

/*
 * L2.4 — Melacak Job yang Gagal
 *
 * Salin berkas ini ke src/app/Jobs/JobGagal.php lalu lengkapi.
 *
 *     Copy-Item lab\starter\L2.4-job-gagal\JobGagal.php src\app\Jobs\
 */

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

class JobGagal implements ShouldQueue
{
    use Queueable;

    public function handle(): void
    {
        // TODO [1] — Buat job ini SELALU gagal.
        //
        //   Bagaimana cara memberi tahu queue worker bahwa sebuah job gagal?
        //   Pesannya harus cukup khas agar mudah Anda temukan kembali di log
        //   maupun di daftar job gagal.
        //
        //   Setelah itu, jawab lewat pengamatan — bukan lewat menebak:
        //     - Berapa kali job ini dicoba sebelum dinyatakan gagal permanen?
        //       Di berkas konfigurasi mana angka itu ditentukan?
        //     - Di mana catatan job gagal disimpan? Perhatikan: antreannya ada
        //       di Redis, tetapi apakah catatan KEGAGALAN juga di sana?
        //     - Bagaimana menjalankan ulang job yang sudah gagal?
    }
}
