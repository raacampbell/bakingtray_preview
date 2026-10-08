# webupload (MATLAB)

The source-neutral half of the brainsaw web preview client: loads and
validates the config file, zips a folder, and uploads the zip to the brainsaw
server using only built-in MATLAB (`zip`, `matlab.net.http`), so it works on
Windows and Mac with no external tools. It knows nothing about where the
folder came from. BakingTray stages its files with `BakingTray.webpreview`
(see `BakingTray/README.md`) and then hands the folder to this package.

Requires MATLAB R2019b or later (the oldest release BakingTray supports):
`matlab.net.http.io.MultipartFormProvider` needs R2019b, and option parsing
uses `inputParser`, not `arguments` blocks. No toolboxes are needed.

## Path

Add the `upload_core` folder (the one containing `+webupload`) to the MATLAB
path: `addpath('<path>/upload_core')`. Add the folder itself, not the
`+webupload` folder inside it, and not via `genpath`. In this repo, on a
development machine only, `add_to_path` does this together with the BakingTray
folders; never add this repo's `BakingTray` folder to the path on a rig that has
the real BakingTray installed, because the two `+BakingTray` packages would
merge and could shadow each other.

## Config file

Copy `webpreview_config.example.json` to a location outside any repository
(the file holds the secret token) and fill it in. There is no default
location: the calling code decides where the file lives and passes its path to
`webupload.webConfig`. A copy inside a checkout must be named
`webpreview_config.json` so `.gitignore` protects it. Never commit a
filled-in copy.

```json
{
  "url": "https://your-server.example/brainsaw/upload.php",
  "siteID": "YOUR_SITE_ID",
  "token": "YOUR_SECRET_TOKEN"
}
```

`url` must be `https://`; plain `http://` is accepted only for `localhost` /
`127.0.0.1`, for testing against a local server. `siteID` must start with a letter and contain only
letters, digits, `_` and `-`. The server keeps one token per site, so `siteID`
and `token` must both match its settings file; any mismatch is an HTTP 403.
The microscope ID is not a config setting: it is `SYSTEM.ID` in the recipe (see
below). A config file with a `micID` field is refused (`webupload:configMicID`). Optional fields `connectTimeout`,
`responseTimeout`, `dataTimeout` (seconds; defaults 15, 60, 60) can be raised
for slow uplinks. It is unverified whether ResponseTimeout/DataTimeout cover
the transfer of the upload itself; a warning `webupload:postZip:noTimeout`
is issued if this release lacks either property. Redirects are never followed
(the token must not be re-sent elsewhere); a 3xx reply is a failure.

Build the config object once, at startup, and keep it:

```matlab
cfg = webupload.webConfig(file);       % the path is required
```

Token: `webupload.webConfig` keeps the token private: it cannot be read by
property access, `disp` or `save` (`struct(cfg)` still can expose it, a MATLAB
limitation), and an object loaded from a MAT file has no token, so always build
it from the JSON. Code that needs the token calls `cfg.authHeader()` (the
`Authorization` header) or `cfg.scrub(msg)` (removes the token from a message).
The constructor always scrubs its own errors, using a regexp on the raw file
text, so they are safe even if the JSON cannot be parsed.

## Uploading a folder

`webupload.zipAndPost(folder, cfg, micID, source)` zips a folder, uploads and
deletes the temp zip, returning `struct(ok, httpStatus, message)` and never
throwing. `zipFolder`, `postZip` and `selectUploadable` are also usable alone.

`source` is `'acq'` (from BakingTray) or `'analysis'` (from StitchIt). `micID`
must match the server's ID rule (`serverLimits().idRegexp`): a letter, then
letters, digits, `_` and `-`. `micID` and `source` may be char or string. If
either is wrong the result is `ok = false` with a message that says whether the
ID was missing or invalid, and shows it; no request is sent. Optional
`'ConnectTimeout'`, `'ResponseTimeout'` and `'DataTimeout'` (seconds) replace
the config values for that one call, for example `'ConnectTimeout', 5,
'ResponseTimeout', 10, 'DataTimeout', 10` for a call that must not block its
caller for long.

The folder must contain `recipe.yml` and `status.json`, or the server refuses
the upload (HTTP 400).

`[micID, sampleID] = webupload.readRecipe(recipeFile)` reads `SYSTEM.ID` and
`sample.ID` from a recipe, in block or flow YAML style, without a YAML parser.
A trailing ` #` comment is dropped, one pair of quotes is removed, and white
space is trimmed. The microscope ID has each space replaced with `_`, as the
server does (`Scope A` gives `Scope_A`). A field it cannot find is `''`, which
`postZip` then refuses. `tests/recipe_id_vectors.json` holds the cases, and the
server's tests use the same file.

`webupload.writeStatus(folder, finished)` writes `status.json`,
`{"finished": true|false}`.

Form fields sent: `site_id`, `microscope_id`, `source`, `data` (the zip), with
the token in an `Authorization: Bearer` header. Only files the server keeps are
zipped: the name whitelist (`allowedNames`) mirrors `BS_ZIP_ALLOWED_NAMES` in
`brainsaw/lib.php`; a test compares them when `lib.php` is present. Any other
name is skipped. Client-side limits (`serverLimits`, from
the server defaults): at most 500 files and a 200 MB zip. If the server's PHP
`post_max_size` is smaller than the zip, the failure can appear as an HTTP 403
rather than 413. `interpretResponse` turns the HTTP status and body into the
result structure.

## Windows notes

Only built-in MATLAB is used. Paths are built with `fullfile`. MATLAB does not
expand `%VAR%` in paths: use `getenv('USERPROFILE')` when you need the home
folder.

## Tests

Run `runtests(fullfile(<repo>, 'upload_core', 'tests'))`; the tests add the
package to the path themselves. They need no real server (one test posts to a
refused `127.0.0.1` port).
