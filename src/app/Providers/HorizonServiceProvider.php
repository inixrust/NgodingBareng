<?php

namespace App\Providers;

use Illuminate\Support\Facades\Gate;
use Laravel\Horizon\Horizon;
use Laravel\Horizon\HorizonApplicationServiceProvider;

class HorizonServiceProvider extends HorizonApplicationServiceProvider
{
    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        parent::boot();

        // Horizon::routeSmsNotificationsTo('15556667777');
        // Horizon::routeMailNotificationsTo('example@example.com');
        // Horizon::routeSlackNotificationsTo('slack-webhook-url', '#channel');
    }

    /**
     * Register the Horizon gate.
     *
     * This gate determines who can access Horizon in non-local environments.
     */
    protected function gate(): void
    {
        Gate::define('viewHorizon', function ($user = null) {
            // Daftar email diambil dari env agar tidak perlu deploy ulang hanya
            // untuk menambah orang. Kosong = tidak ada yang bisa membuka Horizon
            // di luar environment local, yang merupakan default paling aman.
            $allowed = array_filter(array_map(
                'trim',
                explode(',', (string) env('HORIZON_ALLOWED_EMAILS', ''))
            ));

            return $user !== null
                && $allowed !== []
                && in_array($user->email, $allowed, true);
        });
    }
}
