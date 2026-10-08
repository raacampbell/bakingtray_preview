# webpreview (MATLAB)

Stages a section image, recipe and acquisition log, zips them, and uploads
them to the brainsaw server using only built-in MATLAB (`zip`, `imwrite`,
`matlab.net.http`), so it works on Windows and Mac with no external tools.

Requires MATLAB R2019b or later (the oldest release BakingTray supports):
`matlab.net.http.io.MultipartFormProvider` needs R2019b, and option parsing
uses `inputParser`, not `arguments` blocks. No toolboxes are needed.

## Dropping it into BakingTray

1. Copy the `webpreview` folder (the one containing `+webpreview`) into the
   BakingTray tree, or leave it where it is, and add that folder to the MATLAB
   path: `addpath('<path>/BakingTray/webpreview')`. Add the folder itself, not
   the `+webpreview` folder inside it, and not via `genpath`.
2. Create the config file (below).
3. Call `updateSectionImage` after each section completes (below).

## Config file

Copy `webpreview_config.example.json` to `~/.brainsaw_webpreview.json`
(`.brainsaw_webpreview.json` in `getenv('USERPROFILE')` on Windows). This is
the default location, outside any repository, because the file holds the
secret token. To keep it elsewhere pass its path to `webpreview.webConfig`;
name such a copy `webpreview_config.json` so `.gitignore` protects it. Never
commit a filled-in copy.

```json
{
  "url": "https://your-server.example/brainsaw/upload.php",
  "siteID": "YOUR_SITE_ID",
  "micID": "YOUR_MICROSCOPE_ID",
  "token": "YOUR_SECRET_TOKEN"
}
```

`url` must be `https://`; plain `http://` is accepted only for `localhost` /
`127.0.0.1`, for testing against a local server. `siteID` may contain only
letters, digits, `_` and `-`; `micID` (the microscope name) is also required
and takes the same characters. Optional fields `connectTimeout`,
`responseTimeout`, `dataTimeout` (seconds; defaults 15, 60, 60) can be raised
for slow uplinks. It is unverified whether ResponseTimeout/DataTimeout cover
the transfer of the upload itself; a warning `webpreview:postZip:noTimeout`
is issued if this release lacks either property. Redirects are never followed
(the token must not be re-sent elsewhere); a 3xx reply is a failure.

## Calling it from BakingTray

Build the config object once, at startup, and keep it. It validates the file
and holds the token privately (see Token below):

```matlab
cfg = webpreview.webConfig();            % or webpreview.webConfig(file)
```

At the start of a new acquisition, once, empty the managed stage folder so a
previous run's recipe and log can never be sent. This needs no image and
uploads nothing (so it does not use up the server's rate limit):

```matlab
ok = webpreview.clearStage(cfg);
```

`clearStage` takes the option `StageRoot` like `updateSectionImage`, needs the
config only for the site and microscope IDs, and removes just
`<StageRoot>/brainsaw_webpreview/<siteID>/<micID>`, never sibling folders or anything
else under `StageRoot`. It never throws: on failure it warns
`webpreview:clearStage:failed` and returns `false`. (`updateSectionImage` with
`'ClearStage', true` does the same clearing before staging.)

After each section completes (a hook sketch; `img`, `recipePath`, `logPath`
and `cfg` are variables BakingTray already has at that point; the
`which` check keeps acquisition running if the folder is not on the path, and
the `try` covers anything else):

```matlab
% img: latest section image, recipePath: recipe file or folder,
% logPath: acquisition log, cfg: the webpreview.webConfig built at startup
if ~isempty(which('webpreview.updateSectionImage'))
    try
        res = webpreview.updateSectionImage(img, recipePath, logPath, cfg, ...
            'Montage', montageImg, 'Range', [0 4095]);
    catch ME
        warning('preview:unexpected', 'Web preview failed: %s', ME.message);
    end
end
```

`updateSectionImage` itself never throws for anything that goes wrong while
it runs. Two things it cannot protect against: a path variable that does not
exist in the caller (MATLAB raises that error before the function starts, so
it has to be guarded in the caller, as the `try` above does), and the call
blocking: it is synchronous and holds the acquisition thread for up to about
the connect plus response timeouts (roughly 15 s + 60 s by default) when the
server is dead or stalled.

Arguments: `img` is the latest section image (gray HxW or RGB HxWx3);
`recipePath` is the recipe file, or the folder holding it; `logPath` the
acquisition log; `cfg` is the `webpreview.webConfig` object. Options:

| option | meaning |
| --- | --- |
| `Montage` | optional montage image, sent as `montage.jpg` |
| `Range` | `[lo hi]` for non-uint8 images (see below) |
| `ClearStage` | `true` empties the managed stage folder first; default `false` |
| `StageRoot` | parent of the stage folder; default `tempdir`; text options may be strings, paths are returned as char |
| `Poster` | function handle `poster(folder, cfg)` returning `struct(ok, httpStatus, message)`, where `cfg` is a `webpreview.webConfig` object; default `@webpreview.zipAndPost`; for tests |

Result fields: `ok`; `stage` (the `stageFiles` result); `post` (`ok`,
`httpStatus`, `message`); `stageDir` (a char path built from `StageRoot`; `stage.files` are canonical,
symlink-resolved paths, so they can differ textually); `recipeFresh`,
`logFresh` (this call staged a new recipe/log); `stale` (either is false; a
log or recipe that is permanently absent keeps `stale` true on every
section, with a notice each time); `error` (an `MException`
built from the scrubbed message, `[]` on success).

Failures: any problem inside the call (a `cfg` that is not a valid `webConfig`, image, options, staging,
network, a throwing poster) becomes a warning
`webpreview:updateSectionImage:failed` of the form `id: message`, with
`ok = false`. When the upload succeeded but the recipe or log could not be
refreshed, the warning `webpreview:updateSectionImage:stale` names the file
and says the previously staged copy, if any, was used; in a failure the same
text is added to the failed warning. This function issues at most one
notice per call, but `stageFiles` may warn first about the same cause. The
warning call is guarded, so `warning('error', ...)` settings cannot make the
function throw.

Token: the config is held in a `webpreview.webConfig` object, which validates
the file once and then keeps the token private. It cannot be read, displayed
or saved from outside the object. Code that needs it calls `cfg.authHeader()`
(the `Authorization` header) or `cfg.scrub(msg)` (removes the token from a
message). An error raised while the config is being loaded is scrubbed by the
constructor itself, using a regexp on the raw file text if the file cannot be
parsed. Result and warning messages, including a custom `Poster`'s, are scrubbed
with `cfg.scrub`.

## What is sent

A zip of up to four files, named to match the server's globs in
`brainsaw/lib.php`:

- `LastCompleteSection.jpg` from `img`
- `montage.jpg` from `Montage`, only if given (a stale one is removed when not)
- `recipe.yml` (or `recipe.yaml`, following the source), copied from the recipe
- `acqLog.txt`, copied from the log

The stage folder is `<tempdir>/brainsaw_webpreview/<siteID>/<micID>`, reused between
calls so only the latest files exist; it is not deleted afterwards. Two MATLAB
sessions using the same site and microscope ID share it and will overwrite each
other's files. The upload also carries `microscope_id`. Client-side limits (from the server
defaults): at most 500 files and a 200 MB zip. If the server's PHP
`post_max_size` is smaller than the zip, the failure can appear as an HTTP 403
rather than 413.

## Images that are not uint8

uint8 is used as is. uint16 and int16 are autoscaled to `[0 max(img)]`, so
11-14 bit camera data is not near-black; negatives clamp to 0. Pass
`'Range', [lo hi]` for a fixed mapping (`lo` becomes 0, `hi` 255, clamped),
for example `[0 4095]` for a 12-bit camera so brightness does not change from
section to section. single/double must lie in [0,1] unless `Range` is given.
The same `Range` applies to the montage. Details: `help webpreview.toUint8`.

## Windows notes

Only built-in MATLAB is used. Paths are built with `fullfile`. MATLAB does not
expand `%VAR%` in paths: use `getenv('USERPROFILE')` when you need the home
folder. The stage folder is under `tempdir` (normally the user's `Temp`).
Antivirus or a file held open elsewhere can make a rename fail; that is a
staging-failure warning, not an error.

## Lower-level pieces

`zipAndPost(folder, cfg)` zips a folder, uploads and deletes the temp zip,
returning `struct(ok, httpStatus, message)` and never throwing; `zipFolder`,
`postZip` and `stageFiles` are also usable alone, and `webpreview.webConfig(file)`
loads and validates a config file. The extension
whitelist (`allowedExtensions`) mirrors `BS_ZIP_ALLOWED_EXTENSIONS` in
`brainsaw/lib.php`; a test compares them when `lib.php` is present. Dotfiles
and names containing `*` or `?` are skipped (the latter are wildcards to
`zip`).

## Tests and limitations

Run `runtests(fullfile(<repo>, 'BakingTray', 'webpreview', 'tests'))`; the
tests add the package to the path themselves. They need no real server (one
test posts to a refused `127.0.0.1` port).

Nothing in this module has been run against a live brainsaw server. Treat the
first real acquisition as the test, on a spare site ID.
