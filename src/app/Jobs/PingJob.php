<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Log;

/**
 * Job contoh untuk memastikan container "queue" benar-benar memproses antrean.
 *
 *   docker compose exec app php artisan tinker --execute="App\Jobs\PingJob::dispatch();"
 *   docker compose logs queue --tail 20
 */
class PingJob implements ShouldQueue
{
    use Queueable;

    public function handle(): void
    {
        Log::info('PingJob diproses oleh queue worker.', [
            'hostname' => gethostname(),
        ]);
    }
}
