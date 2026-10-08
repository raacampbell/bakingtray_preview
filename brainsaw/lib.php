<?php
declare(strict_types=1);

/**
 * Shared logic for the Brainsaw multi-site upload endpoint and viewer pages.
 * Included by upload.php / index.php / site.php in both the live deployment
 * and test-upload/, each with its own config.php pointing at separate
 * tokens/system_data/logs.
 */

function bs_send_json(int $status, array $body): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body);
    exit;
}

function bs_load_tokens(string $tokensFile): array
{
    if (!is_file($tokensFile)) {
        return [];
    }
    $raw = file_get_contents($tokensFile);
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function bs_log(string $logFile, string $siteId, int $status, string $message = ''): void
{
    $line = sprintf(
        "%s\t%s\t%d\t%s\t%s\n",
        gmdate('c'),
        $siteId !== '' ? $siteId : '-',
        $status,
        $_SERVER['REMOTE_ADDR'] ?? '-',
        $message
    );
    @file_put_contents($logFile, $line, FILE_APPEND | LOCK_EX);
}

/**
 * Atomically write $contents to $finalPath via a tmp file + rename.
 */
function bs_atomic_write(string $finalPath, string $tmpPath, string $contents): bool
{
    if (file_put_contents($tmpPath, $contents, LOCK_EX) === false) {
        return false;
    }
    $ok = rename($tmpPath, $finalPath);
    if (!$ok) {
        @unlink($tmpPath);
    }
    return $ok;
}

/** Newest file matching a glob pattern inside $dir, or null. */
function bs_find_latest(string $dir, string $pattern): ?string
{
    $matches = glob(rtrim($dir, '/') . '/' . $pattern, GLOB_NOSORT) ?: [];
    if (!$matches) {
        return null;
    }
    usort($matches, fn($a, $b) => filemtime($b) <=> filemtime($a));
    return $matches[0];
}

/** All files matching a glob pattern inside $dir, sorted by name. */
function bs_find_all(string $dir, string $pattern): array
{
    $matches = glob(rtrim($dir, '/') . '/' . $pattern, GLOB_NOSORT) ?: [];
    sort($matches);
    return $matches;
}

/**
 * Handle a single upload request. Accepts either:
 *  - a legacy single JPEG in the "image" field (written as latest.jpg), or
 *  - a "data" zip field, extracted (flattened, whitelisted extensions) into
 *    the site's system_data directory.
 * $config must provide: tokens_file, system_data_dir, log_file,
 * max_file_size, max_zip_size, max_zip_uncompressed_size, max_zip_entries,
 * min_upload_interval_seconds.
 */
function bs_handle_upload(array $config): void
{
    $logFile = $config['log_file'];

    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        bs_log($logFile, '', 405, 'method not POST');
        bs_send_json(405, ['status' => 'error', 'message' => 'method not allowed']);
    }

    $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if ($authHeader === '' && function_exists('apache_request_headers')) {
        // Some PHP/Apache setups strip Authorization unless re-read this way.
        foreach (apache_request_headers() as $k => $v) {
            if (strtolower($k) === 'authorization') {
                $authHeader = $v;
                break;
            }
        }
    }
    if (!preg_match('/^Bearer\s+(\S+)$/i', $authHeader, $m)) {
        bs_log($logFile, '', 401, 'missing/malformed Authorization header');
        bs_send_json(401, ['status' => 'error', 'message' => 'missing or malformed Authorization header']);
    }
    $suppliedToken = $m[1];

    $siteId = $_POST['site_id'] ?? '';
    if (!is_string($siteId) || $siteId === '' || !preg_match('/^[a-zA-Z0-9_-]+$/', $siteId)) {
        bs_log($logFile, (string) $siteId, 403, 'missing/invalid site_id');
        bs_send_json(403, ['status' => 'error', 'message' => 'unknown site_id']);
    }

    $tokens = bs_load_tokens($config['tokens_file']);
    if (!isset($tokens[$siteId]['token'])) {
        bs_log($logFile, $siteId, 403, 'unknown site_id');
        bs_send_json(403, ['status' => 'error', 'message' => 'unknown site_id']);
    }

    if (!hash_equals((string) $tokens[$siteId]['token'], $suppliedToken)) {
        bs_log($logFile, $siteId, 403, 'token mismatch');
        bs_send_json(403, ['status' => 'error', 'message' => 'invalid token']);
    }

    $siteDir = rtrim($config['system_data_dir'], '/') . '/' . $siteId;

    // Cheap rate limit: reject if this site uploaded < N seconds ago.
    $minInterval = $config['min_upload_interval_seconds'] ?? 0;
    $metaPath = $siteDir . '/meta.json';
    if ($minInterval > 0 && is_file($metaPath)) {
        $prevMeta = json_decode((string) file_get_contents($metaPath), true);
        if (is_array($prevMeta) && !empty($prevMeta['uploaded_at'])) {
            $prevTs = strtotime($prevMeta['uploaded_at']);
            if ($prevTs !== false && (time() - $prevTs) < $minInterval) {
                bs_log($logFile, $siteId, 429, 'rate limited');
                bs_send_json(429, ['status' => 'error', 'message' => 'uploading too fast']);
            }
        }
    }

    if (!is_dir($siteDir)) {
        if (!mkdir($siteDir, 0755, true) && !is_dir($siteDir)) {
            bs_log($logFile, $siteId, 500, 'could not create site dir');
            bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
        }
    }

    if (isset($_FILES['data'])) {
        bs_handle_zip_upload($config, $siteId, $siteDir, $metaPath);
        return;
    }

    bs_handle_legacy_image_upload($config, $siteId, $siteDir, $metaPath);
}

function bs_handle_legacy_image_upload(array $config, string $siteId, string $siteDir, string $metaPath): void
{
    $logFile = $config['log_file'];

    if (!isset($_FILES['image']) || $_FILES['image']['error'] !== UPLOAD_ERR_OK) {
        $err = $_FILES['image']['error'] ?? 'missing';
        bs_log($logFile, $siteId, 400, "upload error: $err");
        bs_send_json(400, ['status' => 'error', 'message' => 'no valid image uploaded']);
    }

    $maxSize = $config['max_file_size'] ?? (10 * 1024 * 1024);
    if ($_FILES['image']['size'] > $maxSize) {
        bs_log($logFile, $siteId, 413, 'file too large');
        bs_send_json(413, ['status' => 'error', 'message' => 'file too large']);
    }

    $tmpUploadPath = $_FILES['image']['tmp_name'];
    $origName = strtolower($_FILES['image']['name'] ?? '');
    $hasJpegExt = (bool) preg_match('/\.(jpe?g)$/', $origName);

    $imageInfo = @getimagesize($tmpUploadPath);
    $isRealJpeg = $imageInfo !== false && ($imageInfo[2] ?? null) === IMAGETYPE_JPEG;

    if (!$hasJpegExt || !$isRealJpeg) {
        bs_log($logFile, $siteId, 415, 'not a valid JPEG');
        bs_send_json(415, ['status' => 'error', 'message' => 'file is not a valid JPEG']);
    }

    $finalImagePath = $siteDir . '/latest.jpg';
    $tmpImagePath = $siteDir . '/latest.jpg.tmp';

    if (!move_uploaded_file($tmpUploadPath, $tmpImagePath)) {
        // move_uploaded_file fails under the PHP built-in dev server / CLI
        // test harness in some setups; fall back to a plain copy.
        if (!copy($tmpUploadPath, $tmpImagePath)) {
            bs_log($logFile, $siteId, 500, 'failed to stage upload');
            bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
        }
    }

    if (!rename($tmpImagePath, $finalImagePath)) {
        @unlink($tmpImagePath);
        bs_log($logFile, $siteId, 500, 'atomic rename failed');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }

    bs_write_meta($metaPath, $siteDir);
    bs_log($logFile, $siteId, 200, 'ok (legacy image)');
    bs_send_json(200, ['status' => 'ok']);
}

/**
 * Extensions the zip extractor will write to disk. Everything else in the
 * archive is silently skipped. No .php/.htaccess/etc — the images/.htaccess
 * "engine off" rule is defense in depth for real Apache, but the PHP dev
 * server ignores .htaccess entirely, so this whitelist is the real gate.
 */
const BS_ZIP_ALLOWED_EXTENSIONS = ['jpg', 'jpeg', 'png', 'txt', 'yml', 'yaml', 'json', 'csv', 'log'];

function bs_handle_zip_upload(array $config, string $siteId, string $siteDir, string $metaPath): void
{
    $logFile = $config['log_file'];

    if ($_FILES['data']['error'] !== UPLOAD_ERR_OK) {
        bs_log($logFile, $siteId, 400, 'upload error: ' . $_FILES['data']['error']);
        bs_send_json(400, ['status' => 'error', 'message' => 'no valid zip uploaded']);
    }

    $maxZipSize = $config['max_zip_size'] ?? (200 * 1024 * 1024);
    if ($_FILES['data']['size'] > $maxZipSize) {
        bs_log($logFile, $siteId, 413, 'zip too large');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip file too large']);
    }

    $origName = strtolower($_FILES['data']['name'] ?? '');
    if (!preg_match('/\.zip$/', $origName)) {
        bs_log($logFile, $siteId, 415, 'not a .zip filename');
        bs_send_json(415, ['status' => 'error', 'message' => 'file must be a .zip archive']);
    }

    $tmpUploadPath = $_FILES['data']['tmp_name'];

    $zip = new ZipArchive();
    if ($zip->open($tmpUploadPath) !== true) {
        bs_log($logFile, $siteId, 415, 'not a valid zip archive');
        bs_send_json(415, ['status' => 'error', 'message' => 'file is not a valid zip archive']);
    }

    $maxEntries = $config['max_zip_entries'] ?? 500;
    $maxUncompressed = $config['max_zip_uncompressed_size'] ?? (500 * 1024 * 1024);

    if ($zip->numFiles > $maxEntries) {
        $zip->close();
        bs_log($logFile, $siteId, 413, 'too many entries in zip');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip has too many entries']);
    }

    $totalUncompressed = 0;
    $entries = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $stat = $zip->statIndex($i);
        if ($stat === false) {
            continue;
        }
        $name = $stat['name'];
        if (substr($name, -1) === '/') {
            continue; // directory entry
        }
        $base = basename($name);
        if ($base === '' || $base[0] === '.') {
            continue; // skip hidden/dotfiles (never allow a sneaky .htaccess)
        }
        $ext = strtolower(pathinfo($base, PATHINFO_EXTENSION));
        if (!in_array($ext, BS_ZIP_ALLOWED_EXTENSIONS, true)) {
            continue; // extension not on the whitelist
        }
        $totalUncompressed += $stat['size'];
        $entries[$base] = $i;
    }

    if ($totalUncompressed > $maxUncompressed) {
        $zip->close();
        bs_log($logFile, $siteId, 413, 'zip uncompressed size too large');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip contents too large when decompressed']);
    }

    if (!$entries) {
        $zip->close();
        bs_log($logFile, $siteId, 415, 'zip had no recognized files');
        bs_send_json(415, ['status' => 'error', 'message' => 'zip contained no recognized files']);
    }

    // Extract into a per-upload tmp dir first, then atomically rename each
    // file into place — a mid-extraction failure never leaves a half-written
    // file visible under its final name.
    $tmpDir = $siteDir . '/.tmp-' . bin2hex(random_bytes(8));
    if (!mkdir($tmpDir, 0755, true)) {
        $zip->close();
        bs_log($logFile, $siteId, 500, 'could not create tmp extract dir');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }

    foreach ($entries as $base => $index) {
        $contents = $zip->getFromIndex($index);
        if ($contents === false) {
            continue;
        }
        file_put_contents($tmpDir . '/' . $base, $contents, LOCK_EX);
    }
    $zip->close();

    foreach ($entries as $base => $index) {
        $src = $tmpDir . '/' . $base;
        if (is_file($src)) {
            rename($src, $siteDir . '/' . $base);
        }
    }
    @rmdir($tmpDir);

    bs_write_meta($metaPath, $siteDir);
    bs_log($logFile, $siteId, 200, 'ok (zip: ' . implode(',', array_keys($entries)) . ')');
    bs_send_json(200, ['status' => 'ok', 'files' => array_keys($entries)]);
}

function bs_write_meta(string $metaPath, string $siteDir): void
{
    $metaContents = json_encode(['uploaded_at' => gmdate('c')]);
    $metaTmpPath = $siteDir . '/meta.json.tmp';
    bs_atomic_write($metaPath, $metaTmpPath, $metaContents);
}

// Mirrored by humanAgo() in js/autorefresh.js; tests/web/parity.test.js keeps them identical.
function bs_human_ago(int $seconds): string
{
    if ($seconds < 60) {
        return $seconds . 's ago';
    }
    if ($seconds < 3600) {
        return intdiv($seconds, 60) . 'm ago';
    }
    if ($seconds < 86400) {
        return intdiv($seconds, 3600) . 'h ago';
    }
    return intdiv($seconds, 86400) . 'd ago';
}

/**
 * Best-effort extraction of known fields from a BakingTray/ScanImage recipe
 * YAML file. Not a general YAML parser — these recipe files are dumped in a
 * consistent flow-mapping style, so targeted regexes are more robust on
 * shared hosting (no guaranteed yaml extension) than a hand-rolled parser.
 * Add more patterns here as new fields become useful; unmatched fields are
 * simply omitted rather than causing an error.
 */
function bs_parse_recipe(string $path): array
{
    $text = @file_get_contents($path);
    if ($text === false) {
        return [];
    }

    $out = [];

    if (preg_match('/^sample:\s*\{[^}]*\bID:\s*([^,}\s]+)/m', $text, $m)) {
        $out['sample_id'] = $m[1];
    }
    if (preg_match('/^sample:\s*\{[^}]*objectiveName:\s*([^,}]+)/m', $text, $m)) {
        $out['objective'] = trim($m[1]);
    }
    if (preg_match('/^\s*numSections:\s*([\d.]+)/m', $text, $m)) {
        $out['num_sections'] = (int) round((float) $m[1]);
    }
    if (preg_match('/^\s*sectionStartNum:\s*([\d.]+)/m', $text, $m)) {
        $out['section_start_num'] = (int) round((float) $m[1]);
    }
    if (preg_match('/^\s*sliceThickness:\s*([\d.]+)/m', $text, $m)) {
        $out['slice_thickness_mm'] = (float) $m[1];
    }
    if (preg_match('/^\s*numOpticalPlanes:\s*([\d.]+)/m', $text, $m)) {
        $out['num_optical_planes'] = (int) round((float) $m[1]);
    }
    if (preg_match('/^\s*beamPower:\s*([\d.]+)/m', $text, $m)) {
        $out['laser_power_percent'] = (float) $m[1];
    }
    // Top-level VoxelSize (not the nested StitchingParameters one) — anchored
    // to column 0 so it doesn't match indented lookalikes.
    if (preg_match('/^VoxelSize:\s*\{X:\s*([\d.]+),\s*Y:\s*([\d.]+),\s*Z:\s*([\d.]+)/m', $text, $m)) {
        $out['voxel_size_um'] = ['x' => (float) $m[1], 'y' => (float) $m[2], 'z' => (float) $m[3]];
    }
    if (preg_match('/^\s*averageEveryNframes:\s*([\d.]+)/m', $text, $m)) {
        $out['frames_averaged'] = (int) round((float) $m[1]);
    }
    if (preg_match('/^Acquisition:\s*\{acqStartTime:\s*[\'"]?([^,\'"}]+)/m', $text, $m)) {
        $out['acq_start_time'] = trim($m[1]);
    }

    return $out;
}

/**
 * Parse one or more BakingTray acquisition log files into per-section
 * timing data. Merges all matching logs (a site may upload more than one
 * over time) and returns sections sorted by section number.
 *
 * Returns: ['sections' => [{n, timestamp, duration_seconds}, ...],
 *           'current_section' => int|null, 'total_sections' => int|null,
 *           'last_event_at' => string|null]
 */
function bs_parse_acqlogs(array $paths): array
{
    $sections = []; // n => {n, timestamp, duration_seconds}
    $currentSection = null;
    $totalSections = null;
    $lastEventAt = null;

    foreach ($paths as $path) {
        $text = @file_get_contents($path);
        if ($text === false) {
            continue;
        }
        foreach (preg_split('/\r?\n/', $text) as $line) {
            if (preg_match(
                '/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) -- FINISHED section number (\d+), section completed in (\d+) mins? (\d+) secs?/',
                $line,
                $m
            )) {
                $n = (int) $m[2];
                $durationSeconds = ((int) $m[3]) * 60 + (int) $m[4];
                $ts = strtotime($m[1]);
                $sections[$n] = [
                    'n' => $n,
                    'timestamp' => $ts !== false ? gmdate('c', $ts) : null,
                    'duration_seconds' => $durationSeconds,
                ];
                if ($lastEventAt === null || ($ts !== false && $ts > strtotime($lastEventAt))) {
                    $lastEventAt = $ts !== false ? gmdate('c', $ts) : $lastEventAt;
                }
            } elseif (preg_match(
                '/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) -- STARTING section number (\d+) \((\d+) of (\d+)\)/',
                $line,
                $m
            )) {
                $currentSection = (int) $m[2];
                $totalSections = (int) $m[4];
                $ts = strtotime($m[1]);
                if ($lastEventAt === null || ($ts !== false && $ts > strtotime($lastEventAt))) {
                    $lastEventAt = $ts !== false ? gmdate('c', $ts) : $lastEventAt;
                }
            }
        }
    }

    ksort($sections);

    return [
        'sections' => array_values($sections),
        'current_section' => $currentSection,
        'total_sections' => $totalSections,
        'last_event_at' => $lastEventAt,
    ];
}

/** Collect everything renderable about one site's system_data directory. */
function bs_load_site_data(array $config, string $siteId): array
{
    $siteDir = rtrim($config['system_data_dir'], '/') . '/' . $siteId;
    $urlBase = rtrim($config['system_data_url_base'], '/') . '/' . $siteId;

    $mainImage = bs_find_latest($siteDir, 'LastCompleteSection*.jp*g');
    $legacyImage = $siteDir . '/latest.jpg';
    if ($mainImage === null && is_file($legacyImage)) {
        $mainImage = $legacyImage;
    }
    $montageImage = bs_find_latest($siteDir, '*[Mm]ontage*.jp*g');
    $recipePath = bs_find_latest($siteDir, '*ecipe*.y*ml');
    $acqlogPaths = bs_find_all($siteDir, '*cqLog*.txt');

    $recipe = $recipePath !== null ? bs_parse_recipe($recipePath) : [];
    $acq = bs_parse_acqlogs($acqlogPaths);

    $metaPath = $siteDir . '/meta.json';
    $uploadedAt = null;
    if (is_file($metaPath)) {
        $meta = json_decode((string) file_get_contents($metaPath), true);
        if (is_array($meta) && !empty($meta['uploaded_at'])) {
            $uploadedAt = $meta['uploaded_at'];
        }
    }

    return [
        'site_dir' => $siteDir,
        'url_base' => $urlBase,
        'main_image_path' => $mainImage,
        'main_image_url' => $mainImage !== null ? $urlBase . '/' . rawurlencode(basename($mainImage)) : null,
        'montage_image_path' => $montageImage,
        'montage_image_url' => $montageImage !== null ? $urlBase . '/' . rawurlencode(basename($montageImage)) : null,
        'recipe' => $recipe,
        'acquisition' => $acq,
        'uploaded_at' => $uploadedAt,
    ];
}

/**
 * Render an inline SVG line chart of per-section acquisition time. No JS
 * charting library required (keeps the page working with no CDN reachable),
 * and matches the page's dark theme directly.
 */
function bs_render_stats_svg(array $sections, int $width = 900, int $height = 220): string
{
    if (count($sections) < 2) {
        return '<p class="chart-empty">Not enough section-timing data yet to plot.</p>';
    }

    $padL = 46;
    $padR = 16;
    $padT = 16;
    $padB = 30;
    $plotW = $width - $padL - $padR;
    $plotH = $height - $padT - $padB;

    $xs = array_map(fn($s) => $s['n'], $sections);
    $ys = array_map(fn($s) => $s['duration_seconds'] / 60.0, $sections); // minutes

    $minX = min($xs);
    $maxX = max($xs);
    $minY = 0.0;
    $maxY = max($ys) * 1.15;
    if ($maxY <= 0) {
        $maxY = 1.0;
    }
    $spanX = max($maxX - $minX, 1);

    $toPx = function (float $x, float $y) use ($padL, $padT, $plotW, $plotH, $minX, $spanX, $minY, $maxY) {
        $px = $padL + ($x - $minX) / $spanX * $plotW;
        $py = $padT + $plotH - ($y - $minY) / ($maxY - $minY) * $plotH;
        return [$px, $py];
    };

    $points = [];
    foreach ($sections as $s) {
        [$px, $py] = $toPx((float) $s['n'], $s['duration_seconds'] / 60.0);
        $points[] = sprintf('%.1f,%.1f', $px, $py);
    }
    $polyline = implode(' ', $points);

    $avgMinutes = array_sum($ys) / count($ys);
    [, $avgPy] = $toPx($minX, $avgMinutes);

    // Y-axis gridlines/labels (4 bands).
    $yLabels = '';
    for ($i = 0; $i <= 4; $i++) {
        $val = $maxY * $i / 4;
        [, $py] = $toPx($minX, $val);
        $yLabels .= sprintf(
            '<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#2a2a2a" stroke-width="1"/>' .
            '<text x="%d" y="%.1f" fill="#888" font-size="11" text-anchor="end" dominant-baseline="middle">%.1f</text>',
            $padL,
            $py,
            $width - $padR,
            $py,
            $padL - 6,
            $py,
            $val
        );
    }

    // X-axis labels: first, last, and a middle section number.
    $xTicks = [$minX, (int) round(($minX + $maxX) / 2), $maxX];
    $xLabels = '';
    foreach (array_unique($xTicks) as $xt) {
        [$px] = $toPx((float) $xt, 0);
        $xLabels .= sprintf(
            '<text x="%.1f" y="%d" fill="#888" font-size="11" text-anchor="middle">%d</text>',
            $px,
            $height - 8,
            $xt
        );
    }

    $dots = '';
    foreach ($sections as $s) {
        [$px, $py] = $toPx((float) $s['n'], $s['duration_seconds'] / 60.0);
        $dots .= sprintf(
            '<circle cx="%.1f" cy="%.1f" r="2.2" fill="#6cf"><title>section %d: %.1f min</title></circle>',
            $px,
            $py,
            $s['n'],
            $s['duration_seconds'] / 60.0
        );
    }

    return sprintf(
        '<svg viewBox="0 0 %d %d" width="100%%" height="%d" role="img" aria-label="Per-section acquisition time">' .
        '<rect x="0" y="0" width="%d" height="%d" fill="#161616"/>' .
        '%s' .
        '<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#e88" stroke-width="1" stroke-dasharray="4,3"/>' .
        '<polyline points="%s" fill="none" stroke="#6cf" stroke-width="1.6"/>' .
        '%s' .
        '%s' .
        '<text x="%d" y="14" fill="#aaa" font-size="11">minutes / section</text>' .
        '</svg>',
        $width,
        $height,
        $height,
        $width,
        $height,
        $yLabels,
        $padL,
        $avgPy,
        $width - $padR,
        $avgPy,
        $polyline,
        $dots,
        $xLabels,
        $padL
    );
}

const BS_PAGE_STYLE = <<<CSS
  body { font-family: system-ui, sans-serif; background: #111; color: #eee; margin: 0; padding: 24px; }
  a { color: #6cf; }
  h1 { font-size: 1.4rem; margin-bottom: 1rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
  .card { background: #1c1c1c; border-radius: 8px; overflow: hidden; border: 1px solid #2a2a2a; display: block; text-decoration: none; color: inherit; }
  .card img { width: 100%; height: 200px; object-fit: contain; background: #000; display: block; }
  .placeholder { width: 100%; height: 200px; display: flex; align-items: center; justify-content: center; color: #666; background: #000; }
  .meta { padding: 8px 12px; }
  .name { font-weight: 600; }
  .sample { font-size: 0.85rem; color: #ccc; }
  .updated { font-size: 0.85rem; color: #9a9; }
  .stale .updated { color: #e88; }
  .stale { border-color: #833; }
CSS;

/**
 * data-* attributes that tell js/autorefresh.js what to watch for one site:
 * the meta.json URL (from the same url_base as the other site URLs, so the
 * JS never builds paths), the uploaded_at this page was rendered with, and
 * the stale threshold.
 */
function bs_watch_attrs(array $data, int $staleAfter): string
{
    return sprintf(
        'data-meta-url="%s" data-uploaded-at="%s" data-stale-after="%d"',
        htmlspecialchars($data['url_base'] . '/meta.json'),
        htmlspecialchars((string) ($data['uploaded_at'] ?? '')),
        $staleAfter
    );
}

/**
 * Source of the auto-refresh script, or null (and a log line) if it cannot be
 * read, so a missing file degrades to a plain timed page refresh instead of an
 * empty <script>.
 */
function bs_autorefresh_js(): ?string
{
    $js = @file_get_contents(__DIR__ . '/js/autorefresh.js');
    if ($js === false || $js === '') {
        error_log('brainsaw: js/autorefresh.js is missing or unreadable; pages fall back to a meta refresh');
        return null;
    }
    return $js;
}

/** <head> refresh tag: only a no-JS fallback when the script is inlined, unconditional when it is not. */
function bs_autorefresh_head(?string $js): string
{
    $meta = '<meta http-equiv="refresh" content="60">';
    return $js === null ? $meta : '<noscript>' . $meta . '</noscript>';
}

/** The auto-refresh script, inlined so every deployment shares one copy. */
function bs_autorefresh_script(?string $js): string
{
    return $js === null ? '' : '<script>' . $js . '</script>';
}

/**
 * Render the landing page listing every site. $config must provide:
 * tokens_file, system_data_dir, system_data_url_base, stale_after_seconds.
 */
function bs_render_viewer(array $config): void
{
    $tokens = bs_load_tokens($config['tokens_file']);
    $staleAfter = (int) ($config['stale_after_seconds'] ?? 900);

    $sites = [];
    foreach ($tokens as $siteId => $info) {
        $sites[$siteId] = $info['display_name'] ?? $siteId;
    }
    ksort($sites);

    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    $autorefreshJs = bs_autorefresh_js();
    ?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Brainsaw — Live Section Preview</title>
<?= bs_autorefresh_head($autorefreshJs) ?>
<style><?= BS_PAGE_STYLE ?></style>
</head>
<body data-server-now="<?= time() ?>">
<h1>Brainsaw — Live Section Preview</h1>
<div class="grid">
<?php foreach ($sites as $siteId => $displayName):
    $data = bs_load_site_data($config, $siteId);
    $hasImage = $data['main_image_url'] !== null;
    $ago = null;
    $isStale = true;
    if ($data['uploaded_at'] !== null) {
        $ts = strtotime($data['uploaded_at']);
        if ($ts !== false) {
            $ago = bs_human_ago(time() - $ts);
            $isStale = (time() - $ts) > $staleAfter;
        }
    }
    $sampleId = $data['recipe']['sample_id'] ?? null;
    ?>
  <a class="card<?= $isStale ? ' stale' : '' ?>" href="site.php?site=<?= urlencode($siteId) ?>" <?= bs_watch_attrs($data, $staleAfter) ?>>
    <?php if ($hasImage): ?>
      <img src="<?= htmlspecialchars($data['main_image_url']) ?>?t=<?= time() ?>" alt="<?= htmlspecialchars($displayName) ?>">
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>
    <div class="meta">
      <div class="name"><?= htmlspecialchars($displayName) ?></div>
      <?php if ($sampleId): ?><div class="sample">Sample: <?= htmlspecialchars($sampleId) ?></div><?php endif; ?>
      <div class="updated"><?php if ($ago !== null): ?><span data-ago><?= htmlspecialchars($ago) ?></span><?php else: ?>never uploaded<?php endif; ?></div>
    </div>
  </a>
<?php endforeach; ?>
</div>
<?= bs_autorefresh_script($autorefreshJs) ?>
</body>
</html>
<?php
}

/**
 * Render the per-site detail page: full-size main image with a magnifier
 * lens, a link to the monochrome montage image, a metadata table parsed
 * from the recipe file, and a per-section acquisition-time chart parsed
 * from the acquisition log(s).
 */
function bs_render_site_page(array $config, string $siteId): void
{
    $tokens = bs_load_tokens($config['tokens_file']);
    if (!isset($tokens[$siteId])) {
        http_response_code(404);
        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><title>Not found</title><body style="background:#111;color:#eee;font-family:sans-serif;padding:24px">Unknown site.</body>';
        return;
    }

    $displayName = $tokens[$siteId]['display_name'] ?? $siteId;
    $staleAfter = (int) ($config['stale_after_seconds'] ?? 900);
    $data = bs_load_site_data($config, $siteId);
    $recipe = $data['recipe'];
    $acq = $data['acquisition'];

    $ago = null;
    $isStale = true;
    if ($data['uploaded_at'] !== null) {
        $ts = strtotime($data['uploaded_at']);
        if ($ts !== false) {
            $ago = bs_human_ago(time() - $ts);
            $isStale = (time() - $ts) > $staleAfter;
        }
    }

    // Rough ETA estimate from the average per-section duration seen so far —
    // labeled "estimated" since there's no dedicated ETA file yet.
    $etaText = null;
    if ($acq['current_section'] !== null && $acq['total_sections'] !== null && count($acq['sections']) > 0) {
        $avgSeconds = array_sum(array_column($acq['sections'], 'duration_seconds')) / count($acq['sections']);
        $remaining = max($acq['total_sections'] - $acq['current_section'], 0);
        $etaSeconds = (int) round($remaining * $avgSeconds);
        $etaText = gmdate('Y-m-d H:i', time() + $etaSeconds) . ' UTC (estimated)';
    }

    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    $autorefreshJs = bs_autorefresh_js();
    ?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars($displayName) ?> — Brainsaw</title>
<?= bs_autorefresh_head($autorefreshJs) ?>
<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
<script src="js/jquery.imageLens.js"></script>
<style>
<?= BS_PAGE_STYLE ?>
  .back { display: inline-block; margin-bottom: 12px; }
  .layout { display: flex; gap: 24px; flex-wrap: wrap; align-items: flex-start; }
  .main-col { flex: 2 1 640px; min-width: 320px; }
  .side-col { flex: 1 1 280px; min-width: 260px; }
  .image-wrap { position: relative; display: inline-block; max-width: 100%; }
  #main-image { max-width: 100%; height: auto; display: block; border: 1px solid #333; }
  .status.stale { color: #e88; }
  .status { color: #9a9; margin-bottom: 8px; }
  table.meta-table { border-collapse: collapse; width: 100%; margin-top: 8px; }
  table.meta-table td { padding: 4px 8px; border-bottom: 1px solid #2a2a2a; font-size: 0.9rem; }
  table.meta-table td:first-child { color: #999; width: 45%; }
  .chart-box { background: #161616; border: 1px solid #2a2a2a; border-radius: 8px; padding: 12px; margin-top: 20px; }
  .chart-title { font-size: 0.95rem; margin-bottom: 8px; color: #ccc; }
  .chart-empty { color: #666; font-size: 0.9rem; }
  .montage-link { display: inline-block; margin: 10px 0; }
  .placeholder { height: 320px; }
</style>
</head>
<body data-server-now="<?= time() ?>">
<a class="back" href="index.php">&larr; all sites</a>
<h1><?= htmlspecialchars($displayName) ?></h1>

<div class="layout">
  <div class="main-col">
    <div class="status<?= $isStale ? ' stale' : '' ?>" <?= bs_watch_attrs($data, $staleAfter) ?>>
      <?php if ($ago !== null): ?>Last updated <span data-ago><?= htmlspecialchars($ago) ?></span><?php else: ?>No image uploaded yet<?php endif; ?>
      <?php if ($acq['current_section'] !== null && $acq['total_sections'] !== null): ?>
        &mdash; section <?= (int) $acq['current_section'] ?> of <?= (int) $acq['total_sections'] ?>
      <?php endif; ?>
    </div>

    <?php if ($data['main_image_url'] !== null): ?>
      <div class="image-wrap">
        <img id="main-image" src="<?= htmlspecialchars($data['main_image_url']) ?>?t=<?= time() ?>" alt="Last completed section">
      </div>
      <script>
        $(function () { $('#main-image').imageLens({ lensSize: 220 }); });
      </script>
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>

    <?php if ($data['montage_image_url'] !== null): ?>
      <div class="montage-link">
        <a href="<?= htmlspecialchars($data['montage_image_url']) ?>?t=<?= time() ?>" target="_blank" rel="noopener">
          View montage (all optical planes, single channel) &rarr;
        </a>
      </div>
    <?php endif; ?>

    <div class="chart-box">
      <div class="chart-title">Acquisition time per section</div>
      <?= bs_render_stats_svg($acq['sections']) ?>
    </div>
  </div>

  <div class="side-col">
    <table class="meta-table">
      <?php if (!empty($recipe['sample_id'])): ?><tr><td>Sample</td><td><?= htmlspecialchars($recipe['sample_id']) ?></td></tr><?php endif; ?>
      <?php if (!empty($recipe['objective'])): ?><tr><td>Objective</td><td><?= htmlspecialchars($recipe['objective']) ?></td></tr><?php endif; ?>
      <?php if (isset($recipe['laser_power_percent'])): ?><tr><td>Laser power</td><td><?= htmlspecialchars((string) $recipe['laser_power_percent']) ?>%</td></tr><?php endif; ?>
      <?php if (!empty($recipe['voxel_size_um'])): ?>
        <tr><td>Resolution X / Y / Z (&micro;m)</td>
            <td><?= htmlspecialchars(sprintf('%.3f / %.3f / %.3f', $recipe['voxel_size_um']['x'], $recipe['voxel_size_um']['y'], $recipe['voxel_size_um']['z'])) ?></td></tr>
      <?php endif; ?>
      <?php if (isset($recipe['num_optical_planes'])): ?><tr><td>Optical planes / section</td><td><?= (int) $recipe['num_optical_planes'] ?></td></tr><?php endif; ?>
      <?php if (isset($recipe['frames_averaged'])): ?><tr><td>Frames averaged</td><td><?= (int) $recipe['frames_averaged'] ?></td></tr><?php endif; ?>
      <?php if (isset($recipe['num_sections'])): ?><tr><td>Total sections planned</td><td><?= (int) $recipe['num_sections'] ?></td></tr><?php endif; ?>
      <?php if (!empty($recipe['acq_start_time'])): ?><tr><td>Acquisition started</td><td><?= htmlspecialchars($recipe['acq_start_time']) ?></td></tr><?php endif; ?>
      <?php if ($etaText !== null): ?><tr><td>Estimated completion</td><td><?= htmlspecialchars($etaText) ?></td></tr><?php endif; ?>
    </table>
  </div>
</div>
<?= bs_autorefresh_script($autorefreshJs) ?>
</body>
</html>
<?php
}
