# BakingTray.webpreview (MATLAB)

The BakingTray-specific half of the brainsaw web preview client: stages a
section image, recipe and acquisition log into a folder, then uploads it with
the source-neutral `webupload` package in `upload_core/` (see
`upload_core/README.md` for the config file, the token and the lower-level
upload functions). The package is laid out to drop into
`code/+BakingTray/+webpreview` in the real BakingTray repo.

Requires MATLAB R2019b or later (the oldest release BakingTray supports);
option parsing uses `inputParser`, not `arguments` blocks. Staging uses only
built-in MATLAB (`imwrite`, `copyfile`, `movefile`); the upload is in
`webupload`. No toolboxes are needed.

Never add this repo's `BakingTray` folder to the path on a rig that has the
real BakingTray installed, because the two `+BakingTray` packages would merge
and could shadow each other.

## Path

Add `upload_core` and this `BakingTray` folder (the one containing
`+BakingTray`) to the MATLAB path: from the repo root run `add_to_path`, which
also adds `BakingTray/simulate`. Add the folders themselves, not the `+`
folders inside them, and not via `genpath`. Then create the config file (see
`upload_core/README.md`) and call `updateSectionImage` after each section
completes (below).

## Calling it from BakingTray

Build the `cfg` object once, at startup, as described in
`upload_core/README.md` (`webupload.webConfig`), and keep it.

At the start of a new acquisition, once, empty the managed stage folder so a
previous run's recipe and log can never be sent. This needs no image and
uploads nothing (so it does not use up the server's rate limit):

```matlab
ok = BakingTray.webpreview.clearStage(cfg);
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
% logPath: acquisition log, cfg: the webupload.webConfig built at startup
if ~isempty(which('BakingTray.webpreview.updateSectionImage'))
    try
        res = BakingTray.webpreview.updateSectionImage(img, recipePath, logPath, cfg, ...
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
acquisition log; `cfg` is the `webupload.webConfig` object. Options:

| option | meaning |
| --- | --- |
| `Montage` | optional montage image, sent as `montage.jpg` |
| `Range` | `[lo hi]` for non-uint8 images (see below) |
| `ClearStage` | `true` empties the managed stage folder first; default `false` |
| `StageRoot` | parent of the stage folder; default `tempdir`; text options may be strings, paths are returned as char |
| `Poster` | function handle `poster(folder, cfg)` returning `struct(ok, httpStatus, message)`, where `cfg` is a `webupload.webConfig` object; default `@webupload.zipAndPost`; for tests |

Result fields: `ok`; `stage` (the `stageFiles` result); `post` (`ok`,
`httpStatus`, `message`); `stageDir` (a char path built from `StageRoot`;
`stage.files` are canonical, symlink-resolved paths, so they can differ
textually); `recipeFresh`,
`logFresh` (this call staged a new recipe/log); `stale` (either is false; a
log or recipe that is permanently absent keeps `stale` true on every
section, with a notice each time); `error` (an `MException`
built from the scrubbed message, `[]` on success).

Failures: any problem inside the call (a `cfg` that is not a valid
`webConfig`, image, options, staging, network, a throwing poster) becomes a warning
`webpreview:updateSectionImage:failed` of the form `id: message`, with
`ok = false`. When the upload succeeded but the recipe or log could not be
refreshed, the warning `webpreview:updateSectionImage:stale` names the file
and says the previously staged copy, if any, was used; in a failure the same
text is added to the failed warning. This function issues at most one
notice per call, but `stageFiles` may warn first about the same cause. The
warning call is guarded, so `warning('error', ...)` settings cannot make the
function throw.

Result and warning messages, including a custom `Poster`'s, are scrubbed with
`cfg.scrub`, so the token never appears in them.

## What is sent

A zip of up to four files, named to match the server's globs in
`brainsaw/lib.php`:

- `LastCompleteSection.jpg` from `img`
- `montage.jpg` from `Montage`, only if given (a stale one is removed when not)
- `recipe.yml` (or `recipe.yaml`, following the source), copied from the recipe
- `acqLog.txt`, copied from the log

The form fields and the client-side upload limits are in `upload_core/README.md`.

The stage folder is `<tempdir>/brainsaw_webpreview/<siteID>/<micID>`, reused
between calls so only the latest files exist; it is not deleted afterwards. Two
MATLAB sessions using the same site and microscope ID share it and will
overwrite each other's files; give each its own `micID`.

## Images that are not uint8

uint8 is used as is. uint16 and int16 are autoscaled to `[0 max(img)]`, so
11-14 bit camera data is not near-black; negatives clamp to 0. Pass
`'Range', [lo hi]` for a fixed mapping (`lo` becomes 0, `hi` 255, clamped),
for example `[0 4095]` for a 12-bit camera so brightness does not change from
section to section. single/double must lie in [0,1] unless `Range` is given.
The same `Range` applies to the montage. Details: `help BakingTray.webpreview.toUint8`.

## Windows notes

The stage folder is under `tempdir` (normally the user's `Temp`). Antivirus or a file
held open elsewhere can make a rename fail; that is a staging-failure warning,
not an error.

## Lower-level pieces

`BakingTray.webpreview.stageFiles` is usable alone; the upload functions
(`zipAndPost`, `zipFolder`, `postZip`, `webConfig`) are in `webupload`.

## Tests and limitations

Run `runtests(fullfile(<repo>, 'BakingTray', 'tests'))`; the tests add the
packages to the path themselves. They need no real server.

Nothing in this module has been run against a live brainsaw server. Treat the
first real acquisition as the test, on a spare site ID.
