<?php
declare(strict_types=1);

/**
 * Deployment config. Paths are relative to this file so the same code works under
 * `php -S` locally and on the server.
 */
return [
    // Private settings (sites, microscopes, tokens, view words): keep it outside the web root.
    // Locally it sits next to brainsaw/; stage_server.sh replaces this line with the server path.
    'settings_file'               => dirname(__DIR__) . '/brainsaw_settings.json',
    'system_data_dir'             => __DIR__ . '/system_data',
    'log_file'                    => __DIR__ . '/logs/upload.log',
    'max_zip_size'                => 200 * 1024 * 1024,  // 200 MB — system_data.zip upload
    'max_zip_uncompressed_size'   => 500 * 1024 * 1024,  // reject zip bombs past this
    'max_zip_entries'             => 500,
    'min_upload_interval_seconds' => 5,                  // per site, microscope and source
    'stale_after_seconds'         => 15 * 60,            // 15 minutes
];
