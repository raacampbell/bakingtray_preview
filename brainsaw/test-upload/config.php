<?php
declare(strict_types=1);

/**
 * Throwaway canary deployment (spec §9 Layer 2/3, §10 step 3). Separate
 * tokens/images/log from the live deployment so external groups can test
 * their client script without touching production data.
 */
return [
    'tokens_file'                 => __DIR__ . '/tokens.json',
    'system_data_dir'             => __DIR__ . '/system_data',
    'system_data_url_base'        => 'system_data',
    'log_file'                    => __DIR__ . '/logs/upload.log',
    'max_file_size'                => 10 * 1024 * 1024,
    'max_zip_size'                 => 200 * 1024 * 1024,
    'max_zip_uncompressed_size'    => 500 * 1024 * 1024,
    'max_zip_entries'               => 500,
    'min_upload_interval_seconds'  => 5,
    'stale_after_seconds'          => 15 * 60,
];
