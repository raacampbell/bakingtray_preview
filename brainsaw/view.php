<?php
declare(strict_types=1);

// Every request path that is not an existing file or folder lands here (.htaccess, router.php).
require __DIR__ . '/lib.php';
$config = require __DIR__ . '/config.php';

bs_handle_view($config);
