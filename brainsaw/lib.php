<?php
declare(strict_types=1);

/**
 * Shared logic for the Brainsaw upload endpoint (upload.php) and the private views (view.php),
 * driven by the $config array from config.php. Sites, microscopes, tokens and the view words
 * live only in the private settings file named by $config['settings_file'].
 */

function bs_send_json(int $status, array $body): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body);
    exit;
}

// Site IDs, microscope IDs and the panopticon word. A leading letter keeps every ID a string
// key after json_decode (an all-digit key would become an int); \z rejects a trailing newline.
const BS_ID_PATTERN = '/^[A-Za-z][A-Za-z0-9_-]*\z/';

const BS_EMPTY_SETTINGS = ['panopticon' => null, 'sites' => []];

/** Names in the app folder (lower case): a view word equal to one would be shadowed by a real file or folder. */
function bs_reserved_names(): array
{
    return array_map('strtolower', array_values(array_diff(scandir(__DIR__) ?: [], ['.', '..'])));
}

function bs_valid_id(mixed $id): bool
{
    return is_string($id) && preg_match(BS_ID_PATTERN, $id) === 1;
}

/** True if two of $ids differ only in case (a case-insensitive file system would merge their folders). */
function bs_has_case_duplicates(array $ids): bool
{
    $lower = array_map('strtolower', $ids);
    return count(array_unique($lower)) !== count($lower);
}

/**
 * Why $data is not a valid settings structure, or null if it is. IDs and the panopticon word
 * must match BS_ID_PATTERN; the panopticon word and the site IDs must differ from each other
 * and from $reserved, and microscope IDs within a site from each other, all ignoring case.
 * Messages name no word or token, so they are safe for the server log.
 */
function bs_validate_settings(mixed $data, array $reserved): ?string
{
    $idRule = 'start with a letter, then letters, digits, _ or -';
    if (!is_array($data) || !is_array($data['sites'] ?? null)) {
        return 'expected an object with a "sites" object';
    }
    $words = array_keys($data['sites']);
    if (array_key_exists('panopticon', $data)) {
        $words[] = $data['panopticon'];
    }
    foreach ($words as $word) {
        if (!bs_valid_id($word)) {
            return "site IDs and the panopticon word must $idRule";
        }
    }
    foreach ($data['sites'] as $site) {
        if (!is_array($site)) {
            return 'each site must be an object';
        }
        if (!is_string($site['token'] ?? null) || $site['token'] === '') {
            return 'each site needs a non-empty "token"';
        }
        $mics = $site['microscopes'] ?? null;
        if (!is_array($mics) || !$mics) {
            return 'each site needs a non-empty "microscopes" object';
        }
        foreach ($mics as $micId => $mic) {
            if (!bs_valid_id($micId)) {
                return "microscope IDs must $idRule";
            }
            if (!is_array($mic)) {
                return 'each microscope must be an object';
            }
            if (array_key_exists('token', $mic)) {
                return 'a microscope must not have a "token": the token belongs to the site';
            }
        }
        if (bs_has_case_duplicates(array_keys($mics))) {
            return 'microscope IDs within a site must differ by more than case';
        }
    }
    if (bs_has_case_duplicates($words) || array_intersect(array_map('strtolower', $words), $reserved)) {
        return 'the panopticon word and site IDs must differ (ignoring case) from each other and from file or folder names in the app';
    }
    return null;
}

/**
 * The settings file as ['panopticon' => ?string, 'sites' => [...]]. A missing, unreadable or
 * invalid file is logged (without details that could reveal a word) and treated as empty,
 * so every view 404s and every upload is refused.
 */
function bs_load_settings(string $file): array
{
    $raw = is_file($file) ? @file_get_contents($file) : false;
    if ($raw === false) {
        error_log('brainsaw: invalid settings file: missing or unreadable');
        return BS_EMPTY_SETTINGS;
    }
    $data = json_decode($raw, true);
    $problem = bs_validate_settings($data, bs_reserved_names());
    if ($problem !== null) {
        error_log('brainsaw: invalid settings file: ' . $problem);
        return BS_EMPTY_SETTINGS;
    }
    return $data + ['panopticon' => null];
}

/** One microscope's data folder; each upload source has a sub-folder of its own. */
function bs_mic_dir(array $config, string $siteId, string $micId): string
{
    return $config['system_data_dir'] . '/' . $siteId . '/' . $micId;
}

/** Where a source's files for one microscope live. */
function bs_source_dir(array $config, string $siteId, string $micId, string $source): string
{
    return bs_mic_dir($config, $siteId, $micId) . '/' . $source;
}

/** The raw Authorization header: from $_SERVER, under the name a rewrite copy may give it, or from Apache. */
function bs_authorization_header(array $server): string
{
    foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $key) {
        if (is_string($server[$key] ?? null) && $server[$key] !== '') {
            return $server[$key];
        }
    }
    if (function_exists('apache_request_headers')) {
        foreach (apache_request_headers() as $k => $v) {
            if (strtolower($k) === 'authorization') {
                return $v;
            }
        }
    }
    return '';
}

/** One tab-separated line per request. Control characters become '?' and fields are cut to 300 bytes, so no client-supplied text (e.g. zip entry names) can forge or flood lines. */
function bs_log(string $logFile, string $label, int $status, string $message = ''): void
{
    $clean = fn(string $s) => substr(preg_replace('/[\x00-\x1f\x7f]/', '?', $s), 0, 300);
    $line = sprintf(
        "%s\t%s\t%d\t%s\t%s\n",
        gmdate('c'),
        $label !== '' ? $clean($label) : '-',
        $status,
        $_SERVER['REMOTE_ADDR'] ?? '-',
        $clean($message)
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

/** Where an upload comes from: BakingTray's acquisition data, or the analysis run on it. Each has its own folder. */
const BS_SOURCES = ['acq', 'analysis'];

/**
 * Handle one upload: a "data" zip from one source (acq or analysis) of one microscope, named by
 * the site_id, microscope_id and source fields and authorised by the site's bearer token. The
 * zip is checked on a temporary extraction, then installed (flattened, whitelisted names) into
 * system_data/<site_id>/<microscope_id>/<source>/. An unknown site, an unlisted microscope and
 * a wrong token all get the same 403 reply, so probing the endpoint cannot reveal which IDs (and
 * therefore which view words) exist; the log tells them apart. The source is only looked at
 * once the client is authenticated.
 */
function bs_handle_upload(array $config): void
{
    $logFile = $config['log_file'];

    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        bs_log($logFile, '', 405, 'method not POST');
        bs_send_json(405, ['status' => 'error', 'message' => 'method not allowed']);
    }

    if (!preg_match('/^Bearer\s+(\S+)$/i', bs_authorization_header($_SERVER), $m)) {
        bs_log($logFile, '', 401, 'missing/malformed Authorization header');
        bs_send_json(401, ['status' => 'error', 'message' => 'missing or malformed Authorization header']);
    }
    $suppliedToken = $m[1];

    $siteId = $_POST['site_id'] ?? null;
    $micId = $_POST['microscope_id'] ?? null;
    $refuse = function (string $label, string $why) use ($logFile): never {
        bs_log($logFile, $label, 403, $why);
        bs_send_json(403, ['status' => 'error', 'message' => 'unknown site_id, microscope_id or token']);
    };
    if (!bs_valid_id($siteId) || !bs_valid_id($micId)) {
        $refuse('?', 'missing/invalid site_id or microscope_id'); // raw values never reach the log
    }
    $label = $siteId . '/' . $micId;
    $site = bs_load_settings($config['settings_file'])['sites'][$siteId] ?? null;
    if ($site === null || !isset($site['microscopes'][$micId])) {
        $refuse($label, 'unknown site_id or microscope_id');
    }
    if (!hash_equals($site['token'], $suppliedToken)) {
        $refuse($label, 'token mismatch');
    }

    $source = $_POST['source'] ?? null;
    if (!in_array($source, BS_SOURCES, true)) {
        bs_log($logFile, $label, 400, 'bad source');
        bs_send_json(400, ['status' => 'error', 'message' => 'source must be one of: ' . implode(', ', BS_SOURCES)]);
    }
    $label .= '/' . $source;
    $sourceDir = bs_source_dir($config, $siteId, $micId, $source);

    // Cheap rate limit: reject if this source of this microscope uploaded < N seconds ago.
    // Two uploads arriving together can both pass; acceptable, since this only guards against floods.
    $minInterval = $config['min_upload_interval_seconds'] ?? 0;
    $uploadedAt = bs_read_uploaded_at($sourceDir);
    if ($minInterval > 0 && $uploadedAt !== null) {
        $prevTs = strtotime($uploadedAt);
        if ($prevTs !== false && (time() - $prevTs) < $minInterval) {
            bs_log($logFile, $label, 429, 'rate limited');
            bs_send_json(429, ['status' => 'error', 'message' => 'uploading too fast']);
        }
    }

    if (!isset($_FILES['data'])) {
        bs_log($logFile, $label, 400, 'no data field');
        bs_send_json(400, ['status' => 'error', 'message' => 'no valid zip uploaded']);
    }

    bs_handle_zip_upload($config, $label, bs_mic_dir($config, $siteId, $micId), $sourceDir, $micId);
}

/**
 * The exact base names the zip extractor will write to disk. Everything else in the archive
 * is silently skipped. No .php/.htaccess/etc: system_data/ is never served directly, but this
 * whitelist is what keeps executable files off disk. The MATLAB client mirrors it
 * (webupload.allowedNames); a test keeps the two in step.
 */
const BS_ZIP_ALLOWED_NAMES = ['LastCompleteSection.jpg', 'montage.jpg', 'recipe.yml', 'acqLog.txt', 'status.json'];

/** Names every upload must contain. */
const BS_ZIP_REQUIRED_NAMES = ['recipe.yml', 'status.json'];

/**
 * Validate a zip and install it into $sourceDir. $micDir (the parent of the source folders)
 * holds the temporary extraction, on the same file system so the final renames are atomic.
 * Every check runs on the temporary copy; $sourceDir is not touched until all have passed.
 */
function bs_handle_zip_upload(array $config, string $label, string $micDir, string $sourceDir, string $micId): void
{
    $logFile = $config['log_file'];

    if ($_FILES['data']['error'] !== UPLOAD_ERR_OK) {
        bs_log($logFile, $label, 400, 'upload error: ' . $_FILES['data']['error']);
        bs_send_json(400, ['status' => 'error', 'message' => 'no valid zip uploaded']);
    }

    $maxZipSize = $config['max_zip_size'] ?? (200 * 1024 * 1024);
    if ($_FILES['data']['size'] > $maxZipSize) {
        bs_log($logFile, $label, 413, 'zip too large');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip file too large']);
    }

    $origName = strtolower($_FILES['data']['name'] ?? '');
    if (!preg_match('/\.zip$/', $origName)) {
        bs_log($logFile, $label, 415, 'not a .zip filename');
        bs_send_json(415, ['status' => 'error', 'message' => 'file must be a .zip archive']);
    }

    $tmpUploadPath = $_FILES['data']['tmp_name'];

    $zip = new ZipArchive();
    if ($zip->open($tmpUploadPath) !== true) {
        bs_log($logFile, $label, 415, 'not a valid zip archive');
        bs_send_json(415, ['status' => 'error', 'message' => 'file is not a valid zip archive']);
    }

    $maxEntries = $config['max_zip_entries'] ?? 500;
    $maxUncompressed = $config['max_zip_uncompressed_size'] ?? (500 * 1024 * 1024);

    if ($zip->numFiles > $maxEntries) {
        $zip->close();
        bs_log($logFile, $label, 413, 'too many entries in zip');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip has too many entries']);
    }

    $totalUncompressed = 0;
    $entries = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $stat = $zip->statIndex($i);
        if ($stat === false) {
            continue;
        }
        $base = basename($stat['name']);
        if (!in_array($base, BS_ZIP_ALLOWED_NAMES, true)) {
            continue; // directory entries, dotfiles and everything else not on the whitelist
        }
        $totalUncompressed += $stat['size'];
        $entries[$base] = $i;
    }

    if ($totalUncompressed > $maxUncompressed) {
        $zip->close();
        bs_log($logFile, $label, 413, 'zip uncompressed size too large');
        bs_send_json(413, ['status' => 'error', 'message' => 'zip contents too large when decompressed']);
    }

    // Extract into a per-upload tmp dir first. Nothing reaches the source folder until the
    // upload has passed every check, and then each file is renamed into place, so a failure
    // never leaves a half-written file visible under its final name.
    $tmpDir = $micDir . '/.tmp-' . bin2hex(random_bytes(8));
    if (!mkdir($tmpDir, 0755, true)) {
        $zip->close();
        bs_log($logFile, $label, 500, 'could not create tmp extract dir');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }
    $dropTmp = function () use ($tmpDir): void {
        array_map('unlink', glob($tmpDir . '/*') ?: []);
        @rmdir($tmpDir);
    };

    $ok = true;
    foreach ($entries as $base => $index) {
        $contents = $zip->getFromIndex($index);
        $ok = $ok && $contents !== false && file_put_contents($tmpDir . '/' . $base, $contents, LOCK_EX) !== false;
    }
    $zip->close();
    if (!$ok) {
        $dropTmp();
        error_log('brainsaw: could not extract an upload into ' . $tmpDir);
        bs_log($logFile, $label, 500, 'extracting the zip failed');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }

    $problem = bs_upload_problem($tmpDir, $micId);
    if ($problem !== null) {
        $dropTmp();
        bs_log($logFile, $label, 400, $problem);
        bs_send_json(400, ['status' => 'error', 'message' => $problem]);
    }

    $installed = bs_install_upload($tmpDir, $sourceDir, array_keys($entries), bs_parse_recipe($tmpDir . '/recipe.yml')['sample_id']);
    $dropTmp();
    if (!$installed) {
        error_log('brainsaw: could not install an upload into ' . $sourceDir);
        bs_log($logFile, $label, 500, 'installing the upload failed');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }
    bs_log($logFile, $label, 200, 'ok (zip: ' . implode(',', array_keys($entries)) . ')');
    bs_send_json(200, ['status' => 'ok', 'files' => array_keys($entries)]);
}

/**
 * Why the extracted upload in $dir must be refused, or null if it is acceptable: it needs
 * recipe.yml and status.json; status.json must be an object whose "finished" is a boolean;
 * the recipe's SYSTEM.ID must be $micId once normalised; and the recipe needs a sample.ID.
 * The messages reach only an authenticated client.
 */
function bs_upload_problem(string $dir, string $micId): ?string
{
    foreach (BS_ZIP_REQUIRED_NAMES as $name) {
        if (!is_file($dir . '/' . $name)) {
            return "the zip must contain $name";
        }
    }
    $status = json_decode((string) file_get_contents($dir . '/status.json'), true);
    if (!is_array($status) || !is_bool($status['finished'] ?? null)) {
        return 'status.json must be a JSON object with a boolean "finished"';
    }
    if (bs_recipe_microscope_id($dir . '/recipe.yml') !== $micId) {
        return 'SYSTEM.ID in recipe.yml does not match microscope_id';
    }
    if (!isset(bs_parse_recipe($dir . '/recipe.yml')['sample_id'])) {
        return 'recipe.yml has no sample ID';
    }
    return null;
}

/**
 * The microscope ID a recipe declares: SYSTEM.ID trimmed, with spaces replaced by '_'. The
 * MATLAB client normalises it the same way. Null if the recipe has none. Like bs_parse_recipe(),
 * this reads the dumped YAML with regexes: ID is the key at the first indent level of the
 * SYSTEM block, which ends at the first line that is not indented.
 */
function bs_recipe_microscope_id(string $path): ?string
{
    $text = @file_get_contents($path);
    if ($text === false || !preg_match('/^SYSTEM:[ \t]*\r?\n((?:[ \t]+\S[^\n]*\n?)+)/m', $text, $block)) {
        return null;
    }
    $indent = substr($block[1], 0, strspn($block[1], " \t"));
    if (!preg_match('/^' . preg_quote($indent, '/') . 'ID:[ \t]*([^\n]*)/m', $block[1], $m)) {
        return null;
    }
    $id = str_replace(' ', '_', trim(trim($m[1]), '\'"'));
    return $id !== '' ? $id : null;
}

/**
 * Move the files $names from $tmpDir into $dir and write its meta.json. If $sampleId differs
 * from the folder's stored sample ID (or none is stored) the folder is emptied first; the same
 * sample merges, keeping files this upload does not contain. False if any step fails.
 */
function bs_install_upload(string $tmpDir, string $dir, array $names, string $sampleId): bool
{
    if (!is_dir($dir) && !mkdir($dir, 0755, true) && !is_dir($dir)) {
        return false;
    }
    $ok = true;
    if (bs_read_meta_field($dir, 'sample_id') !== $sampleId) {
        foreach (array_diff(scandir($dir), ['.', '..']) as $old) {
            $ok = $ok && (!is_file($dir . '/' . $old) || unlink($dir . '/' . $old));
        }
    }
    foreach ($names as $name) {
        $ok = $ok && rename($tmpDir . '/' . $name, $dir . '/' . $name);
    }
    $meta = json_encode(['uploaded_at' => gmdate('c'), 'sample_id' => $sampleId]);
    return $ok && bs_atomic_write($dir . '/meta.json', $dir . '/meta.json.tmp', $meta);
}

/** A string field of a folder's meta.json, or null if there is none. */
function bs_read_meta_field(string $dir, string $field): ?string
{
    $meta = json_decode((string) @file_get_contents($dir . '/meta.json'), true);
    return is_array($meta) && is_string($meta[$field] ?? null) && $meta[$field] !== '' ? $meta[$field] : null;
}

/** uploaded_at from a folder's meta.json, or null if there is none. */
function bs_read_uploaded_at(string $dir): ?string
{
    return bs_read_meta_field($dir, 'uploaded_at');
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

/**
 * The only files a view serves from a microscope folder, by the name used in ?f=, with
 * their Content-Type. Recipes and logs are never served: a recipe can hold pasted secrets
 * (e.g. a Slack webhook URL); they are only parsed server-side.
 */
const BS_ASSETS = [
    'main' => ['LastCompleteSection*.jp*g', 'image/jpeg'],
    'montage' => ['*[Mm]ontage*.jp*g', 'image/jpeg'],
    'meta' => ['meta.json', 'application/json'],
];

/** Collect everything renderable about one microscope folder; asset URLs hang off $micUrl. */
function bs_load_mic_data(string $micDir, string $micUrl): array
{
    $url = fn(string $kind) => bs_find_latest($micDir, BS_ASSETS[$kind][0]) !== null ? $micUrl . '?f=' . $kind : null;
    $recipePath = bs_find_latest($micDir, '*ecipe*.y*ml');

    return [
        'main_image_url' => $url('main'),
        'montage_image_url' => $url('montage'),
        'meta_url' => $micUrl . '?f=meta',
        'recipe' => $recipePath !== null ? bs_parse_recipe($recipePath) : [],
        'acquisition' => bs_parse_acqlogs(bs_find_all($micDir, '*cqLog*.txt')),
        'uploaded_at' => bs_read_uploaded_at($micDir),
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

// Keep equal to DEFAULT_STALE_AFTER in js/autorefresh.js.
const BS_DEFAULT_STALE_AFTER_SECONDS = 900;

/**
 * stale_after_seconds from config as a positive int. A missing key means the
 * default; a present value that is non-numeric or below 1 after int conversion
 * is logged and also replaced by the default, so a config typo degrades the
 * page instead of breaking it.
 */
function bs_stale_after_seconds(array $config): int
{
    if (!array_key_exists('stale_after_seconds', $config)) {
        return BS_DEFAULT_STALE_AFTER_SECONDS;
    }
    $value = $config['stale_after_seconds'];
    if (is_numeric($value) && (int) $value >= 1) {
        return (int) $value;
    }
    error_log('brainsaw: invalid stale_after_seconds in config (' . var_export($value, true) . '); using ' . BS_DEFAULT_STALE_AFTER_SECONDS);
    return BS_DEFAULT_STALE_AFTER_SECONDS;
}

/**
 * data-* attributes that tell js/autorefresh.js what to watch for one microscope:
 * its meta URL (built here, so the JS never builds paths), the uploaded_at this
 * page was rendered with, and the stale threshold.
 */
function bs_watch_attrs(array $data, int $staleAfter): string
{
    return sprintf(
        'data-meta-url="%s" data-uploaded-at="%s" data-stale-after="%d"',
        htmlspecialchars($data['meta_url']),
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
 * The deployment's base URL path ('' at the web root, '/testserver' in a sub-folder): where
 * this folder sits below DOCUMENT_ROOT. Not taken from SCRIPT_NAME, whose value after a
 * rewrite varies between servers; a wrong base would shift every path segment by one. Null
 * (and a log line) if this folder is not under DOCUMENT_ROOT, so the caller fails closed.
 */
function bs_base_path(): ?string
{
    $doc = $_SERVER['DOCUMENT_ROOT'] ?? '';
    $root = $doc === '' ? false : realpath($doc); // realpath('') would be the working directory
    $dir = realpath(__DIR__);
    if ($root === false || !str_starts_with($dir . '/', rtrim($root, '/') . '/')) {
        error_log('brainsaw: the app folder is not under DOCUMENT_ROOT; every view returns 404');
        return null;
    }
    return substr($dir, strlen(rtrim($root, '/')));
}

/**
 * What a request path shows, or null if it must get the 404 page. $segments is the path
 * below the deployment base split on '/'. Shapes: [word] is a card grid; [site, mic] is a
 * microscope page through a site's own word; [panopticon, site, mic] is the same page
 * through the panopticon word. Returns ['word', 'panopticon' => bool, 'sites' => the sites
 * the word may see, 'site' => ?id, 'mic' => ?id].
 */
function bs_resolve_view(array $settings, array $segments): ?array
{
    $n = count($segments);
    if ($n < 1 || $n > 3 || count(preg_grep(BS_ID_PATTERN, $segments)) !== $n) {
        return null;
    }
    $word = $segments[0];
    $isPanopticon = $settings['panopticon'] !== null && $word === $settings['panopticon'];
    if ($isPanopticon) {
        $sites = $settings['sites'];
        $rest = array_slice($segments, 1);
    } elseif (isset($settings['sites'][$word])) {
        $sites = [$word => $settings['sites'][$word]];
        $rest = $n > 1 ? $segments : [];
    } else {
        return null;
    }
    if (count($rest) !== 0 && count($rest) !== 2) {
        return null;
    }
    [$site, $mic] = $rest + [null, null];
    if ($mic !== null && !isset($sites[$site]['microscopes'][$mic])) {
        return null;
    }
    return ['word' => $word, 'panopticon' => $isPanopticon, 'sites' => $sites, 'site' => $site, 'mic' => $mic];
}

/** URL of a microscope page within $view: <base>/<word>/<mic>, or <base>/<word>/<site>/<mic> for the panopticon. */
function bs_mic_url(string $base, array $view, string $siteId, string $micId): string
{
    return $base . '/' . $view['word'] . ($view['panopticon'] ? '/' . $siteId : '') . '/' . $micId;
}

/** display_name of a settings entry, or its ID. */
function bs_name(array $entry, string $id): string
{
    return is_string($entry['display_name'] ?? null) ? $entry['display_name'] : $id;
}

/**
 * The one response for every path that is not a view: unknown words, unknown or other-site
 * microscopes, missing assets and any other missing page all look exactly alike, so probing
 * cannot tell a real word from a made-up one.
 */
function bs_not_found(): never
{
    http_response_code(404);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="robots" content="noindex, nofollow"><title>Not found</title></head>',
        '<body><h1>Not found</h1></body></html>';
    exit;
}

/**
 * Entry point for every request path that is not an existing file (see .htaccess and
 * router.php): a card grid, a microscope page, one of its BS_ASSETS (?f=main|montage|meta),
 * or the 404 page. The headers keep view URLs out of Referer headers and search engines.
 */
function bs_handle_view(array $config): never
{
    header('Referrer-Policy: no-referrer');
    header('X-Robots-Tag: noindex, nofollow');
    $base = bs_base_path();
    $path = (string) parse_url($_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH);
    if ($base === null || !str_starts_with($path, $base . '/')) {
        bs_not_found();
    }
    $view = bs_resolve_view(bs_load_settings($config['settings_file']), explode('/', substr($path, strlen($base) + 1)));
    if ($view === null) {
        bs_not_found();
    }
    $kind = $_GET['f'] ?? null;
    if ($view['mic'] === null) {
        if ($kind !== null) {
            bs_not_found();
        }
        bs_render_grid($config, $view, $base);
        exit;
    }
    $micDir = bs_source_dir($config, $view['site'], $view['mic'], 'acq');
    if ($kind === null) {
        bs_render_mic_page($config, $view, $base, $micDir);
        exit;
    }
    if (!is_string($kind) || !isset(BS_ASSETS[$kind])) {
        bs_not_found();
    }
    bs_serve_asset(bs_find_latest($micDir, BS_ASSETS[$kind][0]), BS_ASSETS[$kind][1]);
}

/** Send one file, or the 404 page if it is missing. One open handle, so size and bytes always match. */
function bs_serve_asset(?string $path, string $contentType): never
{
    $fh = $path !== null ? @fopen($path, 'rb') : false;
    if ($fh === false) {
        bs_not_found();
    }
    header('Content-Type: ' . $contentType);
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    header('Content-Length: ' . fstat($fh)['size']);
    fpassthru($fh);
    exit;
}

/** ["Xs ago" or null, stale?] for an uploaded_at value; never uploaded counts as stale. */
function bs_freshness(?string $uploadedAt, int $staleAfter): array
{
    $ts = $uploadedAt !== null ? strtotime($uploadedAt) : false;
    if ($ts === false) {
        return [null, true];
    }
    return [bs_human_ago(time() - $ts), (time() - $ts) > $staleAfter];
}

/** <head> lines shared by every view page. */
function bs_page_head(string $title, ?string $autorefreshJs): string
{
    return '<meta charset="utf-8">'
        . '<meta name="viewport" content="width=device-width, initial-scale=1">'
        . '<meta name="robots" content="noindex, nofollow">'
        . '<title>' . htmlspecialchars($title) . ' — Brainsaw</title>'
        . bs_autorefresh_head($autorefreshJs);
}

/** Card grid of every microscope the view's word may see, grouped by site for the panopticon. */
function bs_render_grid(array $config, array $view, string $base): void
{
    $staleAfter = bs_stale_after_seconds($config);
    $title = $view['panopticon'] ? 'All sites' : bs_name($view['sites'][$view['word']], $view['word']);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    $autorefreshJs = bs_autorefresh_js();
    ?>
<!doctype html>
<html lang="en">
<head>
<?= bs_page_head($title, $autorefreshJs) ?>
<style><?= BS_PAGE_STYLE ?>  h2 { font-size: 1.1rem; margin: 1.5rem 0 0.75rem; }</style>
</head>
<body data-server-now="<?= time() ?>">
<h1><?= htmlspecialchars($title) ?></h1>
<?php foreach ($view['sites'] as $siteId => $site): ?>
<?php if ($view['panopticon']): ?><h2><?= htmlspecialchars(bs_name($site, $siteId)) ?></h2><?php endif; ?>
<div class="grid">
<?php foreach ($site['microscopes'] as $micId => $mic):
    $micUrl = bs_mic_url($base, $view, $siteId, $micId);
    $data = bs_load_mic_data(bs_source_dir($config, $siteId, $micId, 'acq'), $micUrl);
    [$ago, $isStale] = bs_freshness($data['uploaded_at'], $staleAfter);
    $name = bs_name($mic, $micId);
    $sampleId = $data['recipe']['sample_id'] ?? null;
    ?>
  <a class="card<?= $isStale ? ' stale' : '' ?>" href="<?= htmlspecialchars($micUrl) ?>" <?= bs_watch_attrs($data, $staleAfter) ?>>
    <?php if ($data['main_image_url'] !== null): ?>
      <img src="<?= htmlspecialchars($data['main_image_url'] . '&t=' . time()) ?>" alt="<?= htmlspecialchars($name) ?>">
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>
    <div class="meta">
      <div class="name"><?= htmlspecialchars($name) ?></div>
      <?php if ($sampleId): ?><div class="sample">Sample: <?= htmlspecialchars($sampleId) ?></div><?php endif; ?>
      <div class="updated"><?php if ($ago !== null): ?><span data-ago><?= htmlspecialchars($ago) ?></span><?php else: ?>never uploaded<?php endif; ?></div>
    </div>
  </a>
<?php endforeach; ?>
</div>
<?php endforeach; ?>
<?= bs_autorefresh_script($autorefreshJs) ?>
</body>
</html>
<?php
}

/**
 * Render one microscope's page: full-size main image with a magnifier lens, a link to the
 * montage image, a metadata table parsed from the recipe file, and a per-section
 * acquisition-time chart parsed from the acquisition log(s).
 */
function bs_render_mic_page(array $config, array $view, string $base, string $micDir): void
{
    $site = $view['sites'][$view['site']];
    $micName = bs_name($site['microscopes'][$view['mic']], $view['mic']);
    $title = $micName . ' — ' . bs_name($site, $view['site']);
    $staleAfter = bs_stale_after_seconds($config);
    $data = bs_load_mic_data($micDir, bs_mic_url($base, $view, $view['site'], $view['mic']));
    $recipe = $data['recipe'];
    $acq = $data['acquisition'];
    [$ago, $isStale] = bs_freshness($data['uploaded_at'], $staleAfter);

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
<?= bs_page_head($title, $autorefreshJs) ?>
<script src="<?= htmlspecialchars($base) ?>/js/jquery-3.7.1.min.js"></script>
<script src="<?= htmlspecialchars($base) ?>/js/jquery.imageLens.js"></script>
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
<a class="back" href="<?= htmlspecialchars($base . '/' . $view['word']) ?>">&larr; all microscopes</a>
<h1><?= htmlspecialchars($title) ?></h1>

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
        <img id="main-image" src="<?= htmlspecialchars($data['main_image_url'] . '&t=' . time()) ?>" alt="Last completed section">
      </div>
      <script>
        $(function () { $('#main-image').imageLens({ lensSize: 220 }); });
      </script>
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>

    <?php if ($data['montage_image_url'] !== null): ?>
      <div class="montage-link">
        <a href="<?= htmlspecialchars($data['montage_image_url'] . '&t=' . time()) ?>" target="_blank" rel="noopener noreferrer">
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
