<?php
declare(strict_types=1);

require __DIR__ . '/lib.php';
$config = require __DIR__ . '/config.php';

$siteId = $_GET['site'] ?? '';
if (!is_string($siteId) || !preg_match('/^[a-zA-Z0-9_-]+$/', $siteId)) {
    http_response_code(400);
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><title>Bad request</title><body style="background:#111;color:#eee;font-family:sans-serif;padding:24px">Invalid site.</body>';
    exit;
}

bs_render_site_page($config, $siteId);
