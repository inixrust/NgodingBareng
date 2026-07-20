<?php

/*
 * L2.4 — SOLUSI
 *
 * Salin ke src/app/Jobs/JobGagal.php:
 *     Copy-Item lab\solution\L2.4-job-gagal\JobGagal.php src\app\Jobs\
 */

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

class JobGagal implements ShouldQueue
{
    use Queueable;

    public function handle(): void
    {
        // [1] Exception yang tidak ditangkap = job dianggap gagal oleh worker.
        //     Pesannya sengaja khas agar mudah ditemukan kembali di log dan di
        //     tabel failed_jobs.
        throw new \RuntimeException('Sengaja gagal untuk latihan L2.4.');
    }
}
