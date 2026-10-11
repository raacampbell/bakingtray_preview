
# Currently
Currently the StitchIt package sends data to the web via SSH. It just uploads the last completed section. 
It runs on the analysis PC.
https://github.com/SWC-Advanced-Microscopy/StitchIt/tree/master/code/processDuringAcquistion
It runs in a loop with three threads:
1. A thread that copies data from the acquisition PC to the analysis PC. 
2. A thread that runs some pre-processing to get rid of vignetting and make nicer images.
3. A thread that makes a downsampled version of the last imaged section and it sends it to the web. 

It's using rsync and a shared key. 

It works well for a few reasons. For one, it doesn't burden the acquisition PC with calculating these average images. 
However, sometimes users forget to start it. Or sometimes syncAndCrunch (which coordinates the above) crashes or fails and the update to the web stops. 
Also the existing website is shit and the constraint of having the SSH keys is a problem. 

# The general plan
The work done so far on this project fixes many of the above issues. But we need to decide where to deploy it and how. 

## Deploying on the acquisition PC
If BakingTray on the acquisition PC runs the function, it can do so cheaply because after each section it has access to a low-res preview image that it generates from one channel during its normal acquisition. So it can easily send this. 
With suitable guards in place to avoid the operation crashing the acquisition, this is a good option. 
If the acquisition starts then the web preview will start also. The user will get a preview even if they forget syncAndCrunch or it crashes. 
However, the images will look rubbish as they are low res and full of tiling artifacts. 
To get this to work people have to upgrade BakingTray. This should be easy, but there is always inertia to upgrading acquisition software. 


## Deploying on the analysis PC
This will give better images but it requires the user to run syncAndCrunch and sometimes (about once a month, perhaps) it stops during acquisition. 
It's easier to get users to upgrade this. 


# How to deploy?
The path of least resistance is, frankly, to simply upgrade StitchIt to the new system we have been making. 
However, this ignores the benefits of having it run on BakingTray. 
So I am wondering about a dual approach. 
Briefly, BakingTray is the ground truth and StitchIt adds the icing in terms of nicer images as it goes. 

## My vague plan for code layout
Place the core upload functions that we have spent so much time debugging into StitchIt. 
Ask users to install StichIt alongside BakingTray when they upgrade. 
This BakingTray access to the web upload core, without creating a third package. 
We may need to refactor the web core such that there is a module that just handles upload and then BakingTray functions that handle upload of its last section and StitchIt functions that handle upload of its nicer section. 

## What the user would see
They start the acquisition. Right after they start the website indicates acquisition has started. 
The recipe file is uploaded so the sample name and resolution appear online. 
During slicing of the section, which is slow, BakingTray uploads it section preview image and log files are sent. 
This keeps going. Even if syncAndCrunch is never started the above continues.
Then the acquisition finishes, BakingTray sends that information and it's marked as finished online. 

If the user then also syncAndCrunch, when they navigate to the microscope page they now see a larger pretty image that is RGB. That is from syncAndCrunch. Beneath it are largish thumbnails of the last BakingTray image and the last montage image. Clicking on them enlarges them. 
The thumbnail image on the tile is the StitchIt image when there is one (BakingTray's when StitchIt lags or is absent).


## Implementing that
### Why it could be tricky
Implementing the above is tricky because we have two systems sending data and now have edge cases to consider. 
e.g. what happens if the user stops the acquisition at the microscope but syncAndCrunch is still running and tries to send an image?
What happens if the user then starts a new acquisition with a new sample name, whilst the old syncAndCrunch is still running and tries to send an image?

Other things:
We can't assume that all acquisitions will end gracefully and be marked as ended on the web. 
Sometimes users stop and restart an acquisition. It could be a restart of the same acquisition in the same folder with the same name. 
It could be under a new folder with a new name. The latter would just count as a new acquisition. 

One analysis PC can serve many acquisition PCs. It has to have the token config files for all and choose the correct one. 


### How I think this should work on the back-end
BakingTray is the ground truth. When it starts a new acquisition it should:
1. We need to simplify the token JSON file. I think this is a must. 
The microscope ID leaves the JSON. It is, instead, pulled from the recipe file. 
The server will have access to the recipe file and can find that line and it will know what to do with it. 
No need to specify it twice (JSON and recipe). 
The token should be shared across all microscopes from the same site. That will make life much easier and is no less safe. 
Thus, all acq PCs and all analysis PCs on a site share the same JSON. The analysis PC needs one JSON. 


2. It send the recipe and acquisition log files and last image. It does that every time it finishes a section. 
Presumably data will be landing in a site_id/microscope_id folder
BrainSaw will append the string "acq" to the zip file. That will tell the server to place the data in site_id/microscope_id/acquisition_pc
It will treat those data as ground truth

2. The analysis PC starts its stuff. 
It has a copy of the JSON file with the token and site details. 
It uploads a zip with the string "stitchit" appended to the zip file name. 
This ends up in site_id/microscope_id/analysis_pc on the server
We send not only the images but also the recipe file and the acquisition log file. 

3. The server uses the images in site_id/microscope_id/analysis_pc only if the sample name in the recipe file matches that of the sample name in site_id/microscope_id/acquisition_pc

4. For the above to work well, I think we need to send the recipe and acquisition log files as generic names always. So always have it land and be called "raw_recipe" and "raw_acqlog". That way they will just over-write whatever was there before. 
If we do things this way, then even if StitchIt is pushing old acquisition files to the server they will never be displayed because the server will refuse to plot anything with a sample name that does not match. 

5. Acquisition end: at the end of the acquisition BakingTray sends an indicator that it is done, in a small status JSON
(other things can go in it too). From then on the tile says "finished". If the system starts again (e.g. a resume) the
next upload is not finished, so the word goes away. The FINISHED file and the acq log are NOT used for this (a resume
leaves "FINISHED AND COMPLETED ACQUISITION" in the log). Later, syncAndCrunch can make a similar final pass.


# Agreed plan (PI and Claude, 2026-10-08)
This section is the specification for the agents doing the work. Where it differs from the text above, this section
wins. In particular: the source is a form field (not text added to the zip name), the server folders are `acq/` and
`analysis/` (not `acquisition_pc`/`analysis_pc`), and the fixed file names are `recipe.yml` and `acqLog.txt` (not
`raw_recipe`/`raw_acqlog`).

## Who does what
- **Rob, later:** all changes to the real BakingTray repo (`../bakingtray`): the call sites in `bake.m` and
  `sliceSample.m`, and where and how the config file is loaded. Then moving the core into StitchIt, and StitchIt's own
  uploads. Agents do not touch `../bakingtray` or `../StitchIt`.
- **Agents, now:** the server (`brainsaw/`) and the MATLAB code in this repo. The core code must be ready for what is
  coming (BakingTray's three calls now, StitchIt's uploads later) without any BakingTray or StitchIt change being needed
  on the server afterwards.
- The `BakingTray/` folder in this repo is not BakingTray. It holds code that Rob will later copy into BakingTray.

## Decisions
1. Sites and microscopes must both be listed in the settings file. An upload naming an unlisted site or microscope is
   refused.
2. One token per site, shared by every acquisition and analysis PC at that site. The microscope ID is not in the config
   JSON: it comes from the recipe (`SYSTEM.ID`).
3. Two sources: `acq` (BakingTray, the ground truth) and `analysis` (StitchIt, later). Each has its own folder.
4. BakingTray sends the bare minimum: the first-depth section image, recipe, log and status. Never a montage. The
   montage only ever comes from StitchIt.
5. "Finished" is an explicit flag set by the caller. BakingTray sends `finished: true` on its end-of-acquisition upload
   after any graceful stop (completed or stopped early; no distinction). Every other upload sends `finished: false`, so a
   resume clears it. The FINISHED file and the acquisition log are not used for this.
6. A microscope with no `acq/` folder (BakingTray not upgraded) is shown from `analysis/` alone.
7. The start-of-acquisition upload uses a 5 s connect timeout and a 10 s response timeout.
8. Where the config file lives and how BakingTray finds it is Rob's concern, decided later. Core functions take a
   loaded `webConfig` object and do not care where it came from.
9. StitchIt is out of scope until phase 3.

## Upload contract (server and every client)
- POST multipart fields: `site_id`, `microscope_id`, `source` (`acq` or `analysis`), `data` (the zip).
  `Authorization: Bearer <site token>`.
- Unknown site, unlisted microscope and wrong token: the same 403 and message as today (nothing reveals which exists).
  A `source` outside the two values: 400.
- Microscope ID normalisation, identical in MATLAB and PHP: take `SYSTEM.ID` from the recipe, trim, replace spaces with
  `_`. The result must match the server ID rule (`^[A-Za-z][A-Za-z0-9_-]*$`), otherwise the client does not upload and
  warns. The server checks that the normalised `SYSTEM.ID` in the uploaded `recipe.yml` equals `microscope_id`, and
  refuses with 400 otherwise.
- Zip contents: only these names are extracted, anything else is skipped:
  `LastCompleteSection.jpg`, `tile_thumbnail.jpg`, `montage.jpg`, `montage_thumbnail.jpg`, `recipe.yml`, `acqLog.txt`, `status.json`.
  `tile_thumbnail.jpg` (added 2026-10-09): optional, made by the client, about 500 px wide; the card shows it instead
  of the full image. A new section image without one removes the old one.
  `montage_thumbnail.jpg` (added 2026-10-10): the same for `montage.jpg`; the page shows it and opens the full montage in an overlay.
  `recipe.yml` and `status.json` are required in every upload (400 if missing). The recipe is always sent as
  `recipe.yml`, whatever the source file's extension.
- `status.json`: `{"finished": true|false}`. Unknown keys are ignored, so more can be added later.

## Server changes
- Settings file shape:
  `{"panopticon": "...", "sites": {"<site>": {"display_name": "...", "token": "...",
  "microscopes": {"<mic>": {"display_name": "..."}}}}}`.
  A `token` key inside a microscope is a validation error, so an old-format file is not half-accepted.
- Data in `system_data/<site>/<mic>/<source>/`, each with its own `meta.json` (`uploaded_at`).
- Rate limit per (site, microscope, source), 5 s as now.
- New sample: when an upload's recipe has a sample ID different from the one stored in that source folder (or none is
  stored), the folder is emptied before extracting. This applies to `acq/` and `analysis/` alike, so neither ever mixes
  two samples.
- Start of a run: an upload with no image (no `LastCompleteSection.jpg` and no `montage.jpg`) and `finished: false` (the client
  cleared its stage; a montage-only upload is a mid-run result and merges as usual) empties folders before installing into the sender's folder, so the
  old images vanish even for the same sample ID. An `acq` start empties `acq/` and removes `analysis/`. An `analysis`
  start empties `analysis/`, and removes `acq/` only when acq's stored sample ID differs from the upload's or is
  unreadable (analysis starts minutes after acq and must not blank acq's images). A removed other-source folder makes
  the display rule fall back to what remains. Known gap: an orphan `acq/` with the same sample ID is cleared only by
  an `acq` start. The `finished: false` guard is deliberate: an end-of-run call (`finished: true`) with no image must
  not wipe the final images. A refused or rate-limited call wipes nothing, and so does a wipe that the pre-check
  finds cannot complete (500).
- Which data is shown, per microscope:
  - `acq/` exists: it is the ground truth (image, recipe table, log chart, status, freshness). `analysis/` is shown in
    addition only if its sample ID equals `acq/`'s.
  - No `acq/`: `analysis/` alone.
  - Microscope page with matching `analysis/` data: the StitchIt image is the large main image; below it, thumbnails of
    the BakingTray image and the StitchIt montage, which enlarge on click. Without matching analysis data the page is
    as today (BakingTray image, magnifier, no montage).
  - Card thumbnail: the StitchIt image (its `tile_thumbnail.jpg` if sent) when `analysis/` is shown, else the BakingTray
    image. If StitchIt lags acq by more than 2 finished sections (the largest section in `acq/acqLog.txt` minus the
    largest in `analysis/acqLog.txt`), the card and the page's main image use the BakingTray image instead, and the
    StitchIt image goes into the strip below.
- Finished: the status shown is the newest (by `uploaded_at`) among the displayed sources. When it is finished, the
  card and the page say "finished" and the card is not drawn as stale.
- Freshness and auto-refresh: staleness comes from the ground-truth source (`acq/`, or `analysis/` when it is shown
  alone). The page auto-refreshes when either displayed source changes.
- Assets (`?f=`): only files the display rule shows are served. A hidden `analysis/` image or montage gives the same
  404 as any missing page. Recipe and log are never served (as now).
- Remove what the fixed names make obsolete (the newest-file globs for the main image, recipe and log).
- One-off on /testserver (now /livefeed): delete the old flat `system_data/<site>/<mic>/` files and reshape the settings file (document
  the steps for Rob).

## MATLAB: split this repo's code into core and BakingTray-specific
`BakingTray/webpreview/+webpreview` is split in two. All functions keep Rob's doc-string style and the
`end % name` markers, and doc-string usage lines name the new package.

**Core transfer code: `upload_core/+webupload/`** (package `webupload`, tests in `upload_core/tests/`). This is what
Rob will later move into StitchIt unchanged, and what both BakingTray and StitchIt will call. It knows nothing about
BakingTray. The names `upload_core` and `webupload` are provisional; renaming later is a find and replace.
- Moves here: `webConfig`, `zipAndPost`, `postZip`, `zipFolder`, `selectUploadable`, `allowedExtensions`,
  `serverLimits`, `interpretResponse`.
- `webConfig`: drop `micID`. The constructor requires the path to the file; remove `defaultConfigPath` and the
  default location (deciding where the file lives is BakingTray's job, see decision 8).
- `zipAndPost(folder, cfg, micID, source, ...)` and `postZip(zipPath, cfg, micID, source, ...)`: send `microscope_id`
  and `source` with `site_id`. Optional param/val `'ConnectTimeout'`, `'ResponseTimeout'` override the cfg values for
  that call only (used for the start upload). `source` must be `acq` or `analysis`, and `micID` must pass the ID rule;
  otherwise `ok = false`, no request.
- `allowedExtensions` becomes the list of allowed file names (the contract list above), mirroring `lib.php`; the test
  comparing them stays.
- New, small: a recipe reader returning the normalised microscope ID and the sample ID from a recipe file, and the
  definition of the contract file names (including `status.json`) and a way to write `status.json`. Both sources must
  produce identical uploads, so these belong in the core.

**BakingTray-specific: `BakingTray/+BakingTray/+webpreview/`** (called as `BakingTray.webpreview.*`, mirroring
`code/+BakingTray/+webpreview` in the real BakingTray repo; tests in `BakingTray/tests/` or similar). Everything left
after the move: `updateSectionImage`, `stageFiles`, `stageSpec`, `toUint8`, `stageDirFor`, `clearStage`,
`clearStageDir`, and `globToRegexp` if it is still needed once the server uses fixed names (delete it if not).
- `updateSectionImage(img, recipePath, logPath, cfg, ...)` is BakingTray's single entry point for all three calls:
  - start: `img` is `[]`; no image is sent, and any previously staged image is deleted first, so an old sample's image
    can never go up with a new recipe;
  - each section: the first-depth image;
  - end: `'Finished', true`. Only for this call, a 429 reply is retried once after waiting the rate-limit interval
    plus 1 s, so the finished flag is not lost.
  It always sends `source = 'acq'`, the micID from the recipe (core reader), `status.json` with the `Finished` value
  (default false), and passes `'ConnectTimeout'`/`'ResponseTimeout'` through to the core.
- Remove the `Montage` option and montage staging (decision 4).
- Stage folder: `<StageRoot>/brainsaw_webpreview/<siteID>/<micID>/acq`, micID now from the recipe.
- README: the three calls as Rob will write them in `bake.m` (start, with 5 s / 10 s timeouts; end, with
  `'Finished', true`) and `sliceSample.m` (during the cut), each guarded with `which` and try/catch. These are examples
  for Rob, not changes to BakingTray.

**Also update:** `add_to_path.m`: add `upload_core` and `BakingTray` (the folder containing `+BakingTray`).
Never add this repo's `BakingTray` folder on a rig that has the real BakingTray installed: the two `+BakingTray`
packages would merge and could shadow each other (say so in the READMEs). Docs (`server-setup.md` settings shape,
READMEs, `instructions.md`) and `tests/web/check_pages.sh` and `check_deployed.sh`, including `analysis` uploads made
with curl, to test the match rule and the analysis-only fallback before StitchIt exists.

## Phases
1. **Now (agents):** everything above, tested locally (`php -S`, MATLAB suite) and on the server (/testserver, renamed /livefeed on 2026-10-09).
2. **Later (Rob):** the core goes into StitchIt, which does not use it yet; the BakingTray-specific package and the three
   call sites go into BakingTray; install both on a rig and run against the new site.
3. **Later still (Rob):** StitchIt uploads with `source = 'analysis'`, replacing its scp route. No server change needed.

## How the edge cases resolve
| Case | Outcome |
| --- | --- |
| Stopped at the microscope (gracefully), syncAndCrunch still sending | BakingTray sends finished. Same sample, so StitchIt images still shown. |
| Stopped without the end upload (crash, power loss) | Goes stale after `stale_after_seconds`. |
| New sample started while the old syncAndCrunch still sends | `acq/` emptied and holds the new sample; old StitchIt uploads do not match, so they are hidden. |
| Resume in the same folder, same name | Same sample ID: everything keeps matching; the next upload is not finished, so "finished" goes away. |
| Restart under a new folder and name | A new acquisition (as for a new sample). |
| BakingTray's start upload fails (server down) | Server still has the old sample, so new StitchIt images are hidden until BakingTray's next upload succeeds. |
| BakingTray not upgraded | No `acq/`: `analysis/` shown alone. |
| Same sample name reused later in a new folder | Old StitchIt output would match. Rare; accepted. |

## Background facts (checked in the code, 2026-10-08)
- StitchIt's `buildSectionPreview` writes `LastCompleteSection.jpg` and `montage.jpg`, the same names BakingTray
  stages, so separate source folders are required.
- StitchIt already takes the microscope name from the recipe (`readMetaData2Stitchit` -> `System.ID`, spaces -> `_`).
- Recipe: `SYSTEM: {ID: ...}` is the microscope name; `sample: {ID: ...}` the sample name, which always starts with
  `<SYSTEM.ID>_` (recipe.m:356). An unconfigured rig has `SYSTEM.ID` = `SYSTEM_NAME` (refused: not listed).
- `Acquisition.acqStartTime` is rewritten on every bake, including a resume (bake.m:136), so matching uses the sample
  ID, not the start time.
- The analysis PC already has the recipe and acqLog (syncAndCrunch rsyncs the sample folder), and StitchIt's web runner
  is a separate background MATLAB process, so a blocking upload there costs the acquisition nothing.



# Code notes

## HOW YOU WILL WRITE THE CODE
You will see I made changes to the code you wrote. I changed the comment style. 
I merged some of the very small functions into others to make it less bitty. 
I created a class to make life easier than the functional sprawl you created. 
When you write new MATLAB code, carry on the same vibe. 

For the web code, do as you were doing before. 
