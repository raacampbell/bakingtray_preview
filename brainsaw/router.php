<?php
declare(strict_types=1);

/**
 * Router for `php -S`, used only for local testing. PHP's built-in server never reads
 * .htaccess, so this applies the same rules; keep the two in step:
 *  - system_data/ and logs/ (as the first path segment), .ht* files, any *.json and any
 *    .php other than index.php, upload.php and view.php are never served directly (403);
 *  - an existing file or folder is served as usual;
 *  - every other path goes to view.php (a private view or the one 404 page).
 * Paths outside this folder (when the document root is a parent folder, as in
 * tests/web/check_pages.sh) and paths with '..' get a 404, so nothing beside the app is served.
 *
 * Usage, from this folder: php -S localhost:8000 router.php
 */

$base = substr(__DIR__, strlen(rtrim((string) realpath($_SERVER['DOCUMENT_ROOT']), '/')));
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
// Decoded, with repeated slashes collapsed, as the file system will see it.
$rel = preg_replace('#/+#', '/', rawurldecode(substr($path, strlen($base))));

if (!str_starts_with($path, $base . '/') || preg_match('#(^|/)\.\.(/|$)#', $rel)) {
    http_response_code(404);
    return true;
}

// Case-insensitive because the local file system may ignore case.
$denied = '#^/(system_data|logs)(/|$)|(^|/)\.ht|\.json$|\.php$#i';
if (preg_match($denied, $rel) && !preg_match('#/(index|upload|view)\.php$#', $rel)) {
    http_response_code(403);
    header('Content-Type: text/plain');
    echo 'Forbidden';
    return true;
}

if (file_exists(__DIR__ . $rel)) {
    return false; // let the built-in server handle it as normal
}

require __DIR__ . '/view.php';
return true;
