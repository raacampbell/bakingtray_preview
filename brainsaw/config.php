<?php
declare(strict_types=1);

/**
 * Live deployment config. Paths are relative to this file so the same
 * upload.php/index.php work whether run via `php -S` locally or on GoDaddy.
 */
return [
    'tokens_file'                 => __DIR__ . '/tokens.json',
    'system_data_dir'             => __DIR__ . '/system_data',
    'system_data_url_base'        => 'system_data',
    'log_file'                    => __DIR__ . '/logs/upload.log',
    'max_file_size'                => 10 * 1024 * 1024,   // 10 MB — legacy single-JPEG upload
    'max_zip_size'                 => 200 * 1024 * 1024,  // 200 MB — system_data.zip upload
    'max_zip_uncompressed_size'    => 500 * 1024 * 1024,  // reject zip bombs past this
    'max_zip_entries'               => 500,
    'min_upload_interval_seconds'  => 5,
    'stale_after_seconds'          => 15 * 60, // 15 minutes
];
