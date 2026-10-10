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
        if (!is_string($site['token'] ?? null) || preg_match('/^\S{32,}\z/', $site['token']) !== 1) {
            return 'each site needs a "token" of at least 32 characters without white space';
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

    // Cheap early rate limit, before any zip work. bs_handle_zip_upload() checks again under
    // the folder lock, which is what stops two uploads arriving together from both passing.
    $minInterval = $config['min_upload_interval_seconds'] ?? 0;
    if (bs_rate_limited($sourceDir, $minInterval)) {
        bs_log($logFile, $label, 429, 'rate limited');
        bs_send_json(429, ['status' => 'error', 'message' => 'uploading too fast']);
    }

    if (!isset($_FILES['data'])) {
        bs_log($logFile, $label, 400, 'no data field');
        bs_send_json(400, ['status' => 'error', 'message' => 'no valid zip uploaded']);
    }

    bs_handle_zip_upload($config, $label, bs_mic_dir($config, $siteId, $micId), $sourceDir, $micId);
}

/** True if the source folder's meta.json says it was uploaded to less than $minInterval seconds ago. */
function bs_rate_limited(string $sourceDir, int $minInterval): bool
{
    $uploadedAt = bs_read_meta_field($sourceDir, 'uploaded_at');
    $prevTs = $uploadedAt === null ? false : strtotime($uploadedAt);
    return $minInterval > 0 && $prevTs !== false && (time() - $prevTs) < $minInterval;
}

/**
 * The exact base names the zip extractor will write to disk. Everything else in the archive
 * is silently skipped. No .php/.htaccess/etc: system_data/ is never served directly, but this
 * whitelist is what keeps executable files off disk. It must equal allowedNames in the shared
 * contract (tests/web/upload_contract.json); check_pages.sh checks that.
 */
const BS_ZIP_ALLOWED_NAMES = ['LastCompleteSection.jpg', 'tile_thumbnail.jpg', 'montage.jpg', 'montage_thumbnail.jpg', 'recipe.yml', 'acqLog.txt', 'status.json'];

/** Names every upload must contain. They are parsed in memory, so they are size-capped (BS_ZIP_MAX_TEXT_BYTES). */
const BS_ZIP_REQUIRED_NAMES = ['recipe.yml', 'status.json'];

/** Largest recipe.yml or status.json accepted: far above a real one, far below the memory limit. */
const BS_ZIP_MAX_TEXT_BYTES = 1024 * 1024;

/** Delete a temporary extraction folder (flat: only files). Also the shutdown hook, so no exit path leaves one behind. */
function bs_remove_tmp(string $dir): void
{
    array_map('unlink', glob($dir . '/*') ?: []);
    @rmdir($dir);
}

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
        if ($stat === false || str_ends_with($stat['name'], '/')) {
            continue; // unreadable entry or directory
        }
        $base = basename($stat['name']);
        if (!in_array($base, BS_ZIP_ALLOWED_NAMES, true)) {
            continue; // dotfiles and everything else not on the whitelist
        }
        if (isset($entries[$base])) {
            $zip->close();
            bs_log($logFile, $label, 400, "two entries named $base");
            bs_send_json(400, ['status' => 'error', 'message' => "the zip has more than one entry named $base"]);
        }
        if (in_array($base, BS_ZIP_REQUIRED_NAMES, true) && $stat['size'] > BS_ZIP_MAX_TEXT_BYTES) {
            $zip->close();
            bs_log($logFile, $label, 413, "$base too large");
            bs_send_json(413, ['status' => 'error', 'message' => "$base is too large"]);
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
    // never leaves a half-written file visible under its final name. Folders left by a process
    // that was killed outright are swept when they are an hour old.
    foreach (glob($micDir . '/.tmp-*', GLOB_ONLYDIR) ?: [] as $stale) {
        if (filemtime($stale) < time() - 3600) {
            bs_remove_tmp($stale);
        }
    }
    $tmpDir = $micDir . '/.tmp-' . bin2hex(random_bytes(8));
    if (!mkdir($tmpDir, 0755, true)) {
        $zip->close();
        bs_log($logFile, $label, 500, 'could not create tmp extract dir');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }
    register_shutdown_function('bs_remove_tmp', $tmpDir);

    $ok = true;
    foreach ($entries as $base => $index) {
        // The cap is re-applied to the bytes actually read: the size in the zip header can lie.
        $capped = in_array($base, BS_ZIP_REQUIRED_NAMES, true);
        $contents = $zip->getFromIndex($index, $capped ? BS_ZIP_MAX_TEXT_BYTES + 1 : 0);
        if ($capped && $contents !== false && strlen($contents) > BS_ZIP_MAX_TEXT_BYTES) {
            $zip->close();
            bs_log($logFile, $label, 413, "$base too large");
            bs_send_json(413, ['status' => 'error', 'message' => "$base is too large"]);
        }
        $ok = $ok && $contents !== false && file_put_contents($tmpDir . '/' . $base, $contents, LOCK_EX) !== false;
    }
    $zip->close();
    if (!$ok) {
        error_log('brainsaw: could not extract an upload into ' . $tmpDir);
        bs_log($logFile, $label, 500, 'extracting the zip failed');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }

    $checked = bs_check_upload($tmpDir, $micId);
    if (is_string($checked)) {
        bs_log($logFile, $label, 400, $checked);
        bs_send_json(400, ['status' => 'error', 'message' => $checked]);
    }

    // Installing empties, moves and then writes meta.json; two uploads of the same source
    // running those steps together could leave one upload's meta.json describing the other's
    // files. The lock serialises them (a dotfile in the microscope folder, never served), and
    // the rate limit is re-checked under it so the loser of a race gets a 429.
    $lock = fopen($micDir . '/.lock-' . basename($sourceDir), 'c');
    if ($lock === false || !flock($lock, LOCK_EX)) {
        bs_log($logFile, $label, 500, 'could not lock the source folder');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }
    if (bs_rate_limited($sourceDir, $config['min_upload_interval_seconds'] ?? 0)) {
        bs_log($logFile, $label, 429, 'rate limited');
        bs_send_json(429, ['status' => 'error', 'message' => 'uploading too fast']);
    }
    $installed = bs_install_upload($tmpDir, $sourceDir, array_keys($entries), $checked['sampleID']);
    flock($lock, LOCK_UN);
    fclose($lock);
    if (!$installed) {
        error_log('brainsaw: could not install an upload into ' . $sourceDir);
        bs_log($logFile, $label, 500, 'installing the upload failed');
        bs_send_json(500, ['status' => 'error', 'message' => 'server error']);
    }
    bs_log($logFile, $label, 200, 'ok (zip: ' . implode(',', array_keys($entries)) . ')');
    bs_send_json(200, ['status' => 'ok', 'files' => array_keys($entries)]);
}

/**
 * Check the extracted upload in $dir. Returns the reason to refuse it (a string), or the
 * recipe's IDs from bs_recipe_ids() when it is acceptable. It needs recipe.yml and
 * status.json; status.json must be an object whose "finished" is a boolean; the recipe's
 * SYSTEM.ID must equal $micId; and the recipe needs a sample.ID, which is only stored,
 * compared and escaped, so it must just be non-empty valid UTF-8. The messages reach only
 * an authenticated client.
 */
function bs_check_upload(string $dir, string $micId): string|array
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
    $ids = bs_recipe_ids((string) file_get_contents($dir . '/recipe.yml'));
    if ($ids['micID'] !== $micId) {
        return 'SYSTEM.ID in recipe.yml does not match microscope_id';
    }
    if ($ids['sampleID'] === '') {
        return 'recipe.yml has no sample ID';
    }
    if (preg_match('//u', $ids['sampleID']) !== 1) {
        return 'the sample ID in recipe.yml is not valid UTF-8';
    }
    return $ids;
}

/**
 * The IDs a recipe declares, as ['micID' => ..., 'sampleID' => ...] ('' when not found). The
 * rule is the "rule" in tests/web/upload_contract.json, and its cases are run against this
 * function by check_pages.sh.
 */
function bs_recipe_ids(string $text): array
{
    return [
        'micID' => str_replace(' ', '_', bs_recipe_value($text, 'SYSTEM', 'ID')),
        'sampleID' => bs_recipe_value($text, 'sample', 'ID'),
    ];
}

/**
 * The value of $key directly under the top-level key $section, in block or flow style, or ''.
 * A leading UTF-8 BOM is ignored. Recipes are dumped YAML, so this reads them with string
 * scans rather than a YAML library (which shared hosting may not have).
 */
function bs_recipe_value(string $text, string $section, string $key): string
{
    $lines = preg_split('/\r?\n/', preg_replace('/^\xEF\xBB\xBF/', '', $text));
    foreach ($lines as $i => $line) {
        if (preg_match('/^' . preg_quote($section, '/') . ':[ \t]*(.*)$/', $line, $m)) {
            $rest = trim($m[1], " \t");
            if ($rest !== '' && $rest[0] === '{') {
                return bs_flow_value(substr($rest, 1), $key);
            }
            if ($rest === '' || $rest[0] === '#') {
                return bs_block_value(array_slice($lines, $i + 1), $key);
            }
            return '';
        }
    }
    return '';
}

/** $key from the indented lines after a block-style key: the key at the block's first indent level; the block ends at the first unindented line. */
function bs_block_value(array $lines, string $key): string
{
    $indent = null;
    foreach ($lines as $line) {
        if (trim($line, " \t") === '') {
            continue;
        }
        if ($line[0] !== ' ' && $line[0] !== "\t") {
            break;
        }
        $indent ??= substr($line, 0, strspn($line, " \t"));
        if (preg_match('/^' . preg_quote($indent . $key, '/') . ':[ \t]*(.*)$/', $line, $m)) {
            return bs_clean_yaml_value($m[1]);
        }
    }
    return '';
}

/** $key from the text after the opening '{' of a one-line flow mapping: entries end at a comma or the closing brace outside quotes. One pass, however long the line. */
function bs_flow_value(string $body, string $key): string
{
    $n = strlen($body);
    $pos = 0;
    $entryStart = 0;
    while (true) {
        $pos += strcspn($body, ",}'\"", $pos);
        $c = $pos < $n ? $body[$pos] : '}';
        if ($c === '"' || $c === "'") {
            $close = strpos($body, $c, $pos + 1);
            if ($close === false) {
                return '';
            }
            $pos = $close + 1;
            continue;
        }
        $entry = substr($body, $entryStart, $pos - $entryStart);
        if (preg_match('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*:(.*)$/s', $entry, $m)) {
            return bs_clean_yaml_value($m[1]);
        }
        if ($c === '}') {
            return '';
        }
        $entryStart = ++$pos;
    }
}

/** A scalar as written after "key:": a trailing ' #' comment dropped, one pair of matching quotes stripped, surrounding white space trimmed. */
function bs_clean_yaml_value(string $raw): string
{
    $v = trim($raw, " \t\r\n");
    if ($v !== '' && ($v[0] === '"' || $v[0] === "'")) {
        $close = strpos($v, $v[0], 1);
        if ($close !== false) {
            $after = ltrim(substr($v, $close + 1), " \t");
            if ($after === '' || $after[0] === '#') {
                return trim(substr($v, 1, $close - 1), " \t\r\n");
            }
        }
    }
    for ($p = strpos($v, '#'); $p !== false; $p = strpos($v, '#', $p + 1)) {
        if ($p > 0 && ($v[$p - 1] === ' ' || $v[$p - 1] === "\t")) {
            $v = substr($v, 0, $p);
            break;
        }
    }
    return trim($v, " \t\r\n");
}

/**
 * Move the files $names from $tmpDir into $dir and write its meta.json. If $sampleId differs
 * from the folder's stored sample ID (or none is stored) the folder is emptied first; the same
 * sample merges, keeping files this upload does not contain. On failure the files moved so far
 * and meta.json are removed, so the folder reads as never uploaded rather than half new.
 */
function bs_install_upload(string $tmpDir, string $dir, array $names, string $sampleId): bool
{
    $meta = json_encode(['uploaded_at' => gmdate('c'), 'sample_id' => $sampleId]);
    if ($meta === false || (!is_dir($dir) && !mkdir($dir, 0755, true) && !is_dir($dir))) {
        return false;
    }
    $existing = scandir($dir);
    if ($existing === false) {
        return false;
    }
    if (bs_read_meta_field($dir, 'sample_id') !== $sampleId) {
        @unlink($dir . '/meta.json'); // a half-emptied folder must not claim an upload
        foreach (array_diff($existing, ['.', '..']) as $old) {
            if (is_file($dir . '/' . $old) && !unlink($dir . '/' . $old)) {
                return false;
            }
        }
    }
    // A new section image without a thumbnail leaves the old thumbnail stale: remove it, so the
    // card falls back to the full image rather than showing an older section.
    if (in_array('LastCompleteSection.jpg', $names, true) && !in_array('tile_thumbnail.jpg', $names, true)) {
        @unlink($dir . '/tile_thumbnail.jpg');
    }
    if (in_array('montage.jpg', $names, true) && !in_array('montage_thumbnail.jpg', $names, true)) {
        @unlink($dir . '/montage_thumbnail.jpg'); // likewise for the montage
    }
    $moved = [];
    foreach ($names as $name) {
        if (!rename($tmpDir . '/' . $name, $dir . '/' . $name)) {
            array_map('unlink', $moved);
            @unlink($dir . '/meta.json');
            return false;
        }
        $moved[] = $dir . '/' . $name;
    }
    if (!bs_atomic_write($dir . '/meta.json', $dir . '/meta.json.tmp', $meta)) {
        array_map('unlink', $moved);
        @unlink($dir . '/meta.json');
        return false;
    }
    return true;
}

/** A JSON file's top-level object, or null if there is no such file. A file that exists but is not a JSON object is logged. */
function bs_read_json_file(string $path): ?array
{
    if (!is_file($path)) {
        return null;
    }
    $data = json_decode((string) @file_get_contents($path), true);
    if (!is_array($data)) {
        error_log('brainsaw: ' . $path . ' is not a JSON object');
        return null;
    }
    return $data;
}

/** A non-empty string field of a decoded meta.json, or null. */
function bs_meta_string(array $meta, string $field): ?string
{
    return is_string($meta[$field] ?? null) && $meta[$field] !== '' ? $meta[$field] : null;
}

/** A string field of a folder's meta.json, or null if there is none. */
function bs_read_meta_field(string $dir, string $field): ?string
{
    return bs_meta_string(bs_read_json_file($dir . '/meta.json') ?? [], $field);
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
 * consistent style, so targeted regexes are more robust on shared hosting
 * (no guaranteed yaml extension) than a hand-rolled parser. The sample ID comes from
 * bs_recipe_value(), which reads block and flow style alike.
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

    $sampleId = bs_recipe_value($text, 'sample', 'ID');
    if ($sampleId !== '') {
        $out['sample_id'] = $sampleId;
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
 * Parse the text of a BakingTray acquisition log into per-section timing data. Empty text
 * gives an empty result.
 *
 * Returns: ['sections' => [{n, timestamp, duration_seconds}, ...] sorted by section number,
 *           'current_section' => int|null, 'total_sections' => int|null,
 *           'last_event_at' => string|null]
 */
function bs_parse_acqlog(string $text): array
{
    $sections = []; // n => {n, timestamp, duration_seconds}
    $currentSection = null;
    $totalSections = null;
    $lastEventAt = null;

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

    ksort($sections);

    return [
        'sections' => array_values($sections),
        'current_section' => $currentSection,
        'total_sections' => $totalSections,
        'last_event_at' => $lastEventAt,
    ];
}

/**
 * The sources a view shows for one microscope, ground truth first. Each maps to
 * ['dir' => folder, 'meta' => its meta.json as an array, read once]. acq/ is the ground truth
 * as soon as its folder exists (an install in progress or a damaged meta.json must not let
 * analysis/ take its place); analysis/ is added only when both folders store the same
 * non-empty sample_id, and shown alone when there is no acq/ folder and it holds an upload
 * (a meta.json with uploaded_at). An empty array means nothing to show.
 */
function bs_displayed_sources(array $config, string $siteId, string $micId): array
{
    $source = function (string $name) use ($config, $siteId, $micId): ?array {
        $dir = bs_source_dir($config, $siteId, $micId, $name);
        return is_dir($dir) ? ['dir' => $dir, 'meta' => bs_read_json_file($dir . '/meta.json') ?? []] : null;
    };
    $acq = $source('acq');
    $analysis = $source('analysis');
    if ($analysis !== null && bs_meta_string($analysis['meta'], 'uploaded_at') === null) {
        $analysis = null; // a folder that holds no upload yet
    }
    if ($acq === null) {
        return $analysis !== null ? ['analysis' => $analysis] : [];
    }
    $sample = bs_meta_string($acq['meta'], 'sample_id');
    if ($analysis !== null && $sample !== null && $sample === bs_meta_string($analysis['meta'], 'sample_id')) {
        return ['acq' => $acq, 'analysis' => $analysis];
    }
    return ['acq' => $acq];
}

/**
 * The files a view serves, by the name used in ?f=, for the sources from bs_displayed_sources().
 * Only existing files appear: 'main' (the StitchIt image if there is one, else the BakingTray
 * image), 'bakingtray' (the BakingTray image), 'montage' (the StitchIt montage) 'tile' (the
 * client-made thumbnail of the card image, from the same folder and only beside it) and 'montage_tile'
 * (the client-made thumbnail of the montage, likewise). Recipes and
 * logs are never served: a recipe can hold pasted secrets (e.g. a Slack webhook URL); they are
 * only parsed server-side.
 */
function bs_asset_paths(array $sources): array
{
    $file = fn(string $name, string $fileName) => isset($sources[$name]) && is_file($sources[$name]['dir'] . '/' . $fileName)
        ? $sources[$name]['dir'] . '/' . $fileName : null;
    $bakingtray = $file('acq', 'LastCompleteSection.jpg');
    $cardSource = isset($sources['acq']) ? 'acq' : 'analysis'; // the card shows this folder's image
    return array_filter([
        'main' => $file('analysis', 'LastCompleteSection.jpg') ?? $bakingtray,
        'bakingtray' => $bakingtray,
        'montage' => $file('analysis', 'montage.jpg'),
        'montage_tile' => $file('analysis', 'montage.jpg') !== null ? $file('analysis', 'montage_thumbnail.jpg') : null,
        'tile' => $file($cardSource, 'LastCompleteSection.jpg') !== null ? $file($cardSource, 'tile_thumbnail.jpg') : null,
    ]);
}

/**
 * True if the ground-truth source's status.json says the acquisition is finished (the first
 * source: acq, or analysis when it is shown alone). The other source never sets or clears it,
 * so a later analysis upload changes the images but not this state; only a new acq upload with
 * finished false (a resume) clears it. A missing status.json counts as not finished; one that
 * exists but is not a JSON object with a boolean "finished" is logged.
 */
function bs_is_finished(array $sources): bool
{
    if (!$sources) {
        return false;
    }
    $dir = reset($sources)['dir'];
    $status = bs_read_json_file($dir . '/status.json');
    if ($status !== null && !is_bool($status['finished'] ?? null)) {
        error_log('brainsaw: ' . $dir . '/status.json has no boolean "finished"');
    }
    return ($status['finished'] ?? null) === true;
}

/**
 * Version tag of one served file: changes whenever the file is replaced (an upload renames a new
 * file into place, so its mtime changes) or the kind now resolves to another file. Used as the
 * ?v= of image URLs and as the ETag, so a browser may cache an image forever under its versioned
 * URL and still sees a new one at once: a new upload gives the page a new URL.
 */
function bs_file_version(string $path, array $stat): string
{
    return substr(md5($path . '|' . $stat['mtime'] . '|' . $stat['size']), 0, 16);
}

/** A string that changes whenever a displayed source is uploaded to, or the set of sources changes. */
function bs_version(array $sources): string
{
    $parts = [];
    foreach ($sources as $name => $source) {
        $parts[] = $name . '=' . bs_meta_string($source['meta'], 'uploaded_at');
    }
    return implode(';', $parts);
}

/**
 * Collect everything renderable about one microscope; asset URLs hang off $micUrl. The sources'
 * meta.json files (written last on install) are read first and the version taken from them, so
 * the content read afterwards is at least as new as the version it is labelled with.
 */
function bs_load_mic_data(array $config, string $siteId, string $micId, string $micUrl): array
{
    $sources = bs_displayed_sources($config, $siteId, $micId);
    $version = bs_version($sources);
    $truth = $sources ? reset($sources) : null; // recipe, log and freshness come from the ground truth
    $paths = bs_asset_paths($sources);
    $url = function (string $kind) use ($paths, $micUrl): ?string {
        $stat = isset($paths[$kind]) ? @stat($paths[$kind]) : false;
        return $stat !== false ? $micUrl . '?f=' . $kind . '&v=' . bs_file_version($paths[$kind], $stat) : null;
    };

    return [
        'main_image_url' => $url('main'),
        // Thumbnails below the main image; the BakingTray image only when the main image is another one.
        'thumb_urls' => array_filter([
            'bakingtray' => ($paths['bakingtray'] ?? null) !== ($paths['main'] ?? null) ? $url('bakingtray') : null,
            'montage' => $url('montage'),
        ]),
        // The BakingTray image whenever acq/ is shown (a placeholder if it has none); the analysis image only without acq/.
        // Its thumbnail when the client sent one, else the full image.
        'card_image_url' => $url('tile') ?? (isset($sources['acq']) ? $url('bakingtray') : $url('main')),
        'tile_url' => $url('tile'),
        'montage_tile_url' => $url('montage_tile'),
        'meta_url' => $micUrl . '?f=meta',
        'recipe' => $truth !== null ? bs_parse_recipe($truth['dir'] . '/recipe.yml') : [],
        'acquisition' => bs_parse_acqlog($truth !== null ? (string) @file_get_contents($truth['dir'] . '/acqLog.txt') : ''),
        'uploaded_at' => $truth !== null ? bs_meta_string($truth['meta'], 'uploaded_at') : null,
        'version' => $version,
        'finished' => bs_is_finished($sources),
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

    $padL = 58;
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
        '<text transform="translate(12,%.1f) rotate(-90)" fill="#aaa" font-size="11" text-anchor="middle">minutes / section</text>' .
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
        $padT + $plotH / 2
    );
}

/**
 * Inline SVG of cumulative acquisition time (hours) by section: the actual running total in
 * blue, and in thin red what the total would be had every section taken as long as the longest
 * section so far.
 */
function bs_render_cumulative_svg(array $sections, int $width = 900, int $height = 220): string
{
    if (count($sections) < 2) {
        return '<p class="chart-empty">Not enough section-timing data yet to plot.</p>';
    }

    $padL = 58;
    $padR = 16;
    $padT = 16;
    $padB = 46;
    $plotW = $width - $padL - $padR;
    $plotH = $height - $padT - $padB;

    $actual = [];
    $worst = [];
    $sumA = 0.0;
    $sumW = 0.0;
    $longest = 0.0;
    foreach ($sections as $s) {
        $h = $s['duration_seconds'] / 3600.0;
        $longest = max($longest, $h);
        $sumA += $h;
        $sumW += $longest;
        $actual[] = $sumA;
        $worst[] = $sumW;
    }

    $minX = $sections[0]['n'];
    $maxX = end($sections)['n'];
    $spanX = max($maxX - $minX, 1);
    $maxY = max($sumW * 1.05, 1e-6);

    $toPx = fn(float $x, float $y) => [
        $padL + ($x - $minX) / $spanX * $plotW,
        $padT + $plotH - $y / $maxY * $plotH,
    ];

    $line = function (array $vals) use ($sections, $toPx): string {
        $pts = [];
        foreach ($sections as $i => $s) {
            [$px, $py] = $toPx((float) $s['n'], $vals[$i]);
            $pts[] = sprintf('%.1f,%.1f', $px, $py);
        }
        return implode(' ', $pts);
    };

    $yLabels = '';
    for ($i = 0; $i <= 4; $i++) {
        $val = $maxY * $i / 4;
        [, $py] = $toPx((float) $minX, $val);
        $yLabels .= sprintf(
            '<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#2a2a2a" stroke-width="1"/>' .
            '<text x="%d" y="%.1f" fill="#888" font-size="11" text-anchor="end" dominant-baseline="middle">%.1f</text>',
            $padL, $py, $width - $padR, $py, $padL - 6, $py, $val
        );
    }

    $xLabels = '';
    foreach (array_unique([$minX, (int) round(($minX + $maxX) / 2), $maxX]) as $xt) {
        [$px] = $toPx((float) $xt, 0);
        $xLabels .= sprintf(
            '<text x="%.1f" y="%d" fill="#888" font-size="11" text-anchor="middle">%d</text>',
            $px, $height - 24, $xt
        );
    }

    return sprintf(
        '<svg viewBox="0 0 %d %d" width="100%%" height="%d" role="img" aria-label="Cumulative acquisition time">' .
        '<rect x="0" y="0" width="%d" height="%d" fill="#161616"/>' .
        '%s' .
        '<polyline points="%s" fill="none" stroke="#e44" stroke-width="0.8"/>' .
        '<polyline points="%s" fill="none" stroke="#6cf" stroke-width="1.6"/>' .
        '%s' .
        '<text transform="translate(12,%.1f) rotate(-90)" fill="#aaa" font-size="11" text-anchor="middle">cumulative time (hours)</text>' .
        '<text x="%.1f" y="%d" fill="#aaa" font-size="11" text-anchor="middle">section number</text>' .
        '<text x="%d" y="14" fill="#e88" font-size="11" text-anchor="end">red: if every section took as long as the longest so far</text>' .
        '</svg>',
        $width, $height, $height, $width, $height,
        $yLabels, $line($worst), $line($actual), $xLabels, $padT + $plotH / 2, $padL + $plotW / 2, $height - 6, $width - $padR
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
 * its meta URL (built here, so the JS never builds paths), the version this page was
 * rendered with (reload when it changes), the ground truth's uploaded_at (for "ago" and
 * stale), whether the acquisition is finished (never drawn stale) and the stale threshold.
 */
function bs_watch_attrs(array $data, int $staleAfter): string
{
    return sprintf(
        'data-meta-url="%s" data-version="%s" data-uploaded-at="%s" data-finished="%d" data-stale-after="%d"',
        htmlspecialchars($data['meta_url']),
        htmlspecialchars($data['version']),
        htmlspecialchars((string) ($data['uploaded_at'] ?? '')),
        $data['finished'] ? 1 : 0,
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
 * The deployment's base URL path ('' at the web root, '/livefeed' in a sub-folder): where
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
 * router.php): a card grid, a microscope page, one of its assets (?f=main|bakingtray|montage|tile,
 * see bs_asset_paths(); ?f=meta is the version the auto-refresh polls), or the 404 page.
 * The headers keep view URLs out of Referer headers and search engines.
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
    if ($kind === null) {
        bs_render_mic_page($config, $view, $base);
        exit;
    }
    $sources = bs_displayed_sources($config, $view['site'], $view['mic']);
    if ($kind === 'meta' && $sources) {
        header('Cache-Control: no-store');
        bs_send_json(200, ['version' => bs_version($sources)]);
    }
    // Any other kind (including the recipe and log) has no entry, so it gets the 404 page.
    bs_serve_asset(is_string($kind) ? (bs_asset_paths($sources)[$kind] ?? null) : null);
}

/**
 * Send one JPEG, or the 404 page if it is missing. One open handle, so size, version and bytes
 * always match. Requested with the file's current ?v= (as the pages link it), it may be cached
 * for a year: a new upload changes the version and so the URL. Any other request (no or an old
 * ?v=) must be revalidated each time. Either way a request whose If-None-Match holds the current
 * version gets a 304 with no body. "private" keeps it out of shared caches.
 */
function bs_serve_asset(?string $path): never
{
    $fh = $path !== null ? @fopen($path, 'rb') : false;
    if ($fh === false) {
        bs_not_found();
    }
    $stat = fstat($fh);
    $version = bs_file_version($path, $stat);
    header('Content-Type: image/jpeg');
    header('Cache-Control: ' . (($_GET['v'] ?? null) === $version ? 'private, max-age=31536000, immutable' : 'private, no-cache'));
    header('ETag: "' . $version . '"');
    header('X-Content-Type-Options: nosniff');
    if (str_contains((string) ($_SERVER['HTTP_IF_NONE_MATCH'] ?? ''), '"' . $version . '"')) {
        http_response_code(304);
        exit;
    }
    header('Content-Length: ' . $stat['size']);
    fpassthru($fh);
    exit;
}

/** ["Xs ago" or null, stale?] for an uploaded_at value; never uploaded counts as stale, a finished acquisition never does. */
function bs_freshness(?string $uploadedAt, int $staleAfter, bool $finished): array
{
    $ts = $uploadedAt !== null ? strtotime($uploadedAt) : false;
    if ($ts === false) {
        return [null, !$finished];
    }
    return [bs_human_ago(time() - $ts), !$finished && (time() - $ts) > $staleAfter];
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
    $data = bs_load_mic_data($config, $siteId, $micId, $micUrl);
    [$ago, $isStale] = bs_freshness($data['uploaded_at'], $staleAfter, $data['finished']);
    $name = bs_name($mic, $micId);
    $sampleId = $data['recipe']['sample_id'] ?? '';
    ?>
  <a class="card<?= $isStale ? ' stale' : '' ?>" href="<?= htmlspecialchars($micUrl) ?>" <?= bs_watch_attrs($data, $staleAfter) ?>>
    <?php if ($data['card_image_url'] !== null): ?>
      <img src="<?= htmlspecialchars($data['card_image_url']) ?>" alt="<?= htmlspecialchars($name) ?>">
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>
    <div class="meta">
      <div class="name"><?= htmlspecialchars($name) ?></div>
      <?php if ($sampleId !== ''): ?><div class="sample">Sample: <?= htmlspecialchars($sampleId) ?></div><?php endif; ?>
      <div class="updated"><?php if ($data['finished']): ?><span class="finished">finished</span> &middot; <?php endif; ?><?php if ($ago !== null): ?><span data-ago><?= htmlspecialchars($ago) ?></span><?php else: ?>never uploaded<?php endif; ?></div>
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
 * Render one microscope's page: the main image with a magnifier lens, below it (when there is
 * one) thumbnails of the BakingTray image and the StitchIt montage that open full size, a
 * metadata table parsed from the recipe file, and a per-section acquisition-time chart parsed
 * from the acquisition log.
 */
function bs_render_mic_page(array $config, array $view, string $base): void
{
    $site = $view['sites'][$view['site']];
    $micName = bs_name($site['microscopes'][$view['mic']], $view['mic']);
    $title = $micName . ' — ' . bs_name($site, $view['site']);
    $staleAfter = bs_stale_after_seconds($config);
    $data = bs_load_mic_data($config, $view['site'], $view['mic'], bs_mic_url($base, $view, $view['site'], $view['mic']));
    $recipe = $data['recipe'];
    $acq = $data['acquisition'];
    [$ago, $isStale] = bs_freshness($data['uploaded_at'], $staleAfter, $data['finished']);
    $thumbCaptions = ['bakingtray' => 'BakingTray: last section', 'montage' => 'StitchIt: montage (all optical planes, single channel)'];

    // Rough ETA estimate from the average per-section duration seen so far —
    // labeled "estimated" since there's no dedicated ETA file yet.
    $etaAt = null; // the finish time as an instant (Unix seconds); the browser shows it in its own time zone
    if (!$data['finished'] && $acq['current_section'] !== null && $acq['total_sections'] !== null && count($acq['sections']) > 0) {
        $avgSeconds = array_sum(array_column($acq['sections'], 'duration_seconds')) / count($acq['sections']);
        $remaining = max($acq['total_sections'] - $acq['current_section'], 0);
        $etaSeconds = (int) round($remaining * $avgSeconds);
        $etaAt = time() + $etaSeconds;
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
  .thumbs { display: flex; gap: 16px; flex-wrap: wrap; margin: 12px 0; }
  .thumbs a { flex: 1 1 240px; max-width: 360px; color: #ccc; text-decoration: none; font-size: 0.85rem; }
  .thumbs img { width: 100%; height: auto; display: block; border: 1px solid #333; background: #000; }
  .placeholder { height: 320px; }
  #overlay { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.5); display: none; align-items: center; justify-content: center; z-index: 1000; }
  #overlay.open { display: flex; }
  #overlay img { max-width: 96vw; max-height: 96vh; background: #000; box-shadow: 0 0 24px #000; }
  #overlay-close { position: absolute; top: 12px; left: 16px; font-size: 2rem; line-height: 1; color: #eee; background: none; border: 0; cursor: pointer; }
</style>
</head>
<body data-server-now="<?= time() ?>">
<a class="back" href="<?= htmlspecialchars($base . '/' . $view['word']) ?>">&larr; all microscopes</a>
<h1><?= htmlspecialchars($title) ?></h1>

<div class="layout">
  <div class="main-col">
    <div class="status<?= $isStale ? ' stale' : '' ?>" <?= bs_watch_attrs($data, $staleAfter) ?>>
      <?php if ($data['finished']): ?><strong class="finished">Finished</strong> &mdash; <?php endif; ?>
      <?php if ($ago !== null): ?>Last updated <span data-ago><?= htmlspecialchars($ago) ?></span><?php else: ?>No image uploaded yet<?php endif; ?>
      <?php if ($acq['current_section'] !== null && $acq['total_sections'] !== null): ?>
        &mdash; section <?= (int) $acq['current_section'] ?> of <?= (int) $acq['total_sections'] ?>
      <?php endif; ?>
    </div>

    <?php if ($data['main_image_url'] !== null): ?>
      <div class="image-wrap">
        <img id="main-image" src="<?= htmlspecialchars($data['main_image_url']) ?>" alt="Last completed section">
      </div>
      <script>
        $(function () { $('#main-image').imageLens({ lensSize: 220 }); });
      </script>
    <?php else: ?>
      <div class="placeholder">no image yet</div>
    <?php endif; ?>

    <?php if ($data['thumb_urls']): ?>
      <div class="thumbs">
      <?php foreach ($data['thumb_urls'] as $kind => $thumbUrl): ?>
        <?php $smallUrl = $kind === 'bakingtray' ? $data['tile_url'] : ($kind === 'montage' ? $data['montage_tile_url'] : null); ?>
        <a id="thumb-<?= htmlspecialchars($kind) ?>" href="<?= htmlspecialchars($thumbUrl) ?>" <?= $kind === 'montage' ? 'data-overlay' : 'target="_blank" rel="noopener noreferrer"' ?>>
          <img src="<?= htmlspecialchars($smallUrl ?? $thumbUrl) ?>" alt="<?= htmlspecialchars($thumbCaptions[$kind]) ?>">
          <span><?= htmlspecialchars($thumbCaptions[$kind]) ?></span>
        </a>
      <?php endforeach; ?>
      </div>
    <?php endif; ?>

    <div class="chart-box">
      <div class="chart-title">Acquisition time per section</div>
      <?= bs_render_stats_svg($acq['sections']) ?>
    </div>

    <div class="chart-box">
      <div class="chart-title">Cumulative acquisition time</div>
      <?= bs_render_cumulative_svg($acq['sections']) ?>
    </div>
  </div>

  <div class="side-col">
    <table class="meta-table">
      <?php if (($recipe['sample_id'] ?? '') !== ''): ?><tr><td>Sample</td><td><?= htmlspecialchars($recipe['sample_id']) ?></td></tr><?php endif; ?>
      <?php if (isset($recipe['laser_power_percent'])): ?><tr><td>Laser power</td><td><?= htmlspecialchars((string) $recipe['laser_power_percent']) ?>%</td></tr><?php endif; ?>
      <?php if (!empty($recipe['voxel_size_um'])): ?>
        <tr><td>Voxel size X / Y / Z (&micro;m)</td>
            <td><?= htmlspecialchars(sprintf('%.1f x %.1f x %.0f', $recipe['voxel_size_um']['x'], $recipe['voxel_size_um']['y'], $recipe['voxel_size_um']['z'])) ?></td></tr>
      <?php endif; ?>
      <?php if (isset($recipe['num_optical_planes'])): ?><tr><td>Optical planes / section</td><td><?= (int) $recipe['num_optical_planes'] ?></td></tr><?php endif; ?>
      <?php if (isset($recipe['frames_averaged'])): ?><tr><td>Frames averaged</td><td><?= (int) $recipe['frames_averaged'] ?></td></tr><?php endif; ?>
      <?php if (!empty($recipe['acq_start_time'])): ?><tr><td>Acquisition started</td><td><?= htmlspecialchars($recipe['acq_start_time']) ?></td></tr><?php endif; ?>
      <?php if ($acq['sections'] && !empty(end($acq['sections'])['timestamp'])): ?><tr><td>Last section completed</td><td><?= htmlspecialchars(gmdate('Y-m-d H:i:s', strtotime(end($acq['sections'])['timestamp']))) ?></td></tr><?php endif; ?>
      <?php if ($etaAt !== null): ?><tr><td>Estimated completion</td><td><time id="eta" datetime="<?= gmdate('Y-m-d\TH:i:s\Z', $etaAt) ?>"><?= gmdate('Y-m-d H:i', $etaAt) ?> UTC</time> (estimated)</td></tr><?php endif; ?>
    </table>
    <?php if ($etaAt !== null): ?>
    <script>
      // Show the finish time in the viewer's own time zone. The UTC text above stays if this cannot run.
      (function () {
        var el = document.getElementById('eta');
        var d = new Date(el.getAttribute('datetime'));
        if (isNaN(d.getTime())) return;
        try {
          el.textContent = d.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short',
            hour: '2-digit', minute: '2-digit', timeZoneName: 'short' });
        } catch (e) { /* keep the UTC text */ }
      })();
    </script>
    <?php endif; ?>
  </div>
</div>
<div id="overlay" role="dialog" aria-label="Full-size image"><button id="overlay-close" type="button" aria-label="Close">&times;</button><img alt=""></div>
<script>
  // A thumbnail marked data-overlay opens its full image over the page; without JS the link opens it as usual.
  (function () {
    var overlay = document.getElementById('overlay');
    var img = overlay.querySelector('img');
    function close() { overlay.classList.remove('open'); img.removeAttribute('src'); }
    document.querySelectorAll('a[data-overlay]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        img.src = a.href;
        overlay.classList.add('open');
      });
    });
    overlay.addEventListener('click', function (e) { if (e.target !== img) close(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') close(); });
  })();
</script>
<?= bs_autorefresh_script($autorefreshJs) ?>
</body>
</html>
<?php
}
