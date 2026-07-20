import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import { bunny } from 'laravel-vite-plugin/fonts';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.js'],
            refresh: true,
            // Dipakai direktif @fonts di welcome.blade.php. Breeze menimpa file
            // ini saat scaffolding dan menghapusnya — tanpa opsi ini @fonts
            // tidak menghasilkan apa-apa dan halaman kehilangan font-nya.
            fonts: [
                bunny('Instrument Sans', {
                    weights: [400, 500, 600],
                }),
            ],
        }),
        tailwindcss(),
    ],
    server: {
        // Dengarkan semua interface supaya bisa dijangkau dari luar container
        host: '0.0.0.0',
        port: 5173,
        strictPort: true,

        // Tanpa ini, laravel-vite-plugin menulis "http://0.0.0.0:5173" ke
        // public/hot dan browser gagal memuat asset. `origin` memaksa URL yang
        // benar-benar bisa dibuka dari host Windows.
        origin: 'http://localhost:5173',
        hmr: {
            host: 'localhost',
            protocol: 'ws',
        },

        watch: {
            ignored: ['**/storage/framework/views/**', '**/vendor/**'],
            // inotify tidak menembus bind mount Docker Desktop di Windows,
            // jadi perubahan file hanya terdeteksi lewat polling.
            usePolling: true,
            interval: 300,
        },
    },
});
