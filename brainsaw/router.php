<?php
declare(strict_types=1);

/**
 * Router for `php -S`, used only for local testing. PHP's built-in server never reads
 * .htaccess, so this applies the same rules; keep the two in step:
 *  - system_data/, logs/ and .ht* files are never served directly (403);
 *  - an existing file or folder is served as usual;
 *  - every other path goes to view.php (a private view or the one 404 page).
 * Paths outside this folder (when the document root is a parent folder, as in
 * tests/web/check_pages.sh) get a 404, so nothing beside the app is ever served.
 *
 * Usage, from this folder: php -S localhost:8000 router.php
 */

$base = substr(__DIR__, strlen(rtrim((string) realpath($_SERVER['DOCUMENT_ROOT']), '/')));
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

$rel = substr($path, strlen($base));
if (!str_starts_with($path, $base . '/') || preg_match('#(^|/)\.\.(/|$)#', rawurldecode($rel))) {
    http_response_code(404);
    return true;
}

// Any segment, in any case (the local file system may ignore case), with any number of slashes.
if (preg_match('#(^|/)(system_data|logs)(/|$)|(^|/)\.ht#i', rawurldecode($rel))) {
    http_response_code(403);
    header('Content-Type: text/plain');
    echo 'Forbidden';
    return true;
}

if (file_exists(__DIR__ . rawurldecode($rel))) {
    return false; // let the built-in server handle it as normal
}

$_SERVER['SCRIPT_NAME'] = $base . '/view.php';
require __DIR__ . '/view.php';
return true;
