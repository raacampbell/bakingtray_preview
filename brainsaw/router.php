<?php
declare(strict_types=1);

/**
 * Router for `php -S`, used only for local testing. PHP's built-in dev
 * server never reads .htaccess, so without this the deny-by-default rule
 * in system_data/.htaccess (only images + meta.json are servable — recipe
 * and acqlog files can contain operator-pasted secrets, e.g. a Slack
 * webhook URL) has no effect locally. This mirrors that same rule so local
 * testing matches production behavior.
 *
 * Usage: php -S localhost:8000 router.php
 */

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?? '';

if (preg_match('#/system_data/[^/]+/([^/]+)$#', $path, $m)) {
    $file = $m[1];
    if ($file !== 'meta.json' && !preg_match('/\.(jpe?g|png)$/i', $file)) {
        http_response_code(403);
        header('Content-Type: text/plain');
        echo 'Forbidden';
        return true;
    }
}

return false; // let the built-in server handle everything else as normal
