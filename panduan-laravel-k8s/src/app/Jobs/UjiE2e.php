<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Log;

/**
 * Job penanda untuk verifikasi end-to-end antrian.
 *
 * Dipakai skrip verifikasi: dispatch dari satu Pod, lalu buktikan worker di
 * Pod LAIN memprosesnya dengan mencari penanda ini di lognya. Closure dari
 * tinker tidak bisa dipakai untuk ini — closure hasil eval tidak bisa
 * di-unserialize di proses lain.
 */
class UjiE2e implements ShouldQueue
{
    use Queueable;

    public function __construct(public string $penanda = 'JOB-E2E-BERJALAN')
    {
    }

    public function handle(): void
    {
        Log::info($this->penanda, ['pod' => gethostname()]);
    }
}
