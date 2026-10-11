---
type: infrastructure
complexity: simple
status: in review
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# An upload with no image clears both sources' folders on the server

## Why
A client that clears its local stage and sends [] (no image) at the start of a run expects every image of the previous acquisition to vanish from the website. Today the server only empties a source folder when the recipe's sample ID differs from the stored one, so with the same sample ID the old LastCompleteSection.jpg, thumbnails and montage stay up.

## Rule (PI-confirmed)
A start-of-run call is an upload with no image (no LastCompleteSection.jpg and no montage.jpg) whose status.json says finished:false. A montage-only upload is a mid-run analysis result, not an empty start: it merges as usual. Before installing the upload into the SENDER's source folder:
- ACQ start call: acq/ and analysis/ are emptied (every file, including meta.json) and analysis/ is removed.
- ANALYSIS start call: analysis/ is emptied. acq/ is emptied and removed ONLY IF acq's stored sample_id (acq/meta.json) differs from the sample ID in the uploaded recipe, or acq/ has no readable sample_id (an orphan of another sample). If they are equal acq/ is left completely untouched: analysis starts minutes after acq and must not blank acq's images.
- A folder belonging to the other source is removed (rmdir) after emptying, so the display rule falls back to what remains (acq missing = analysis alone). The sender's own folder is kept or created as usual. The display rule is not changed.
- Known gap: an orphan acq/ with the SAME sample ID is not cleared by an analysis start call, only by an acq start call.

The guard `finished:false` is deliberate: an end-of-run call (finished:true) that carries no image must NOT wipe the final images. instructions.md says so.

Uploads that contain LastCompleteSection.jpg behave exactly as before (including the sample-ID-changed emptying of the sender's own folder).

## Details
- Concurrency: the per-source lock is a dotfile in the microscope folder. A start call takes both locks, in a fixed order (acq then analysis), so two uploads cannot deadlock. The rate-limit re-check under the lock is for the sender's source only; a rate-limited sender (429) changes nothing on disk. A later upload to a removed folder recreates it (bs_install_upload makes the folder).
- The wipe only deletes regular files inside the two source folders; the .lock files and .tmp-* dirs are left alone. Before deleting anything the server checks every folder to empty is writable, and that a folder to be removed is a real directory (not a symlink) without sub-folders (the sender's own folder may keep sub-folders); otherwise it answers 500 (logging the folder) and changes nothing. This is best effort: a failure after the check can leave a partial wipe (documented in instructions.md).
- Validation (bs_check_upload) happens before any wipe: a refused upload (400 etc.) wipes nothing.
- Unchanged: allowed names, the contract (tests/web/upload_contract.json and its sha256), the finished rule, the display rule, autorefresh.

## Acceptance criteria
- tests/web/check_pages.sh covers: acq + analysis present with the same sample ID, then an acq upload with no image and finished:false -> acq/ holds only the new files, analysis/ is removed, the page shows the new recipe and no image; an analysis start call with the same sample ID leaves acq/ untouched, with another sample ID (or acq without meta.json) removes acq/; no-image upload with finished:true -> nothing wiped; image-bearing upload -> other source untouched; refused (400) and rate-limited (429) no-image uploads wipe nothing; ?f= for wiped assets 404.
- All existing check_pages.sh and node tests in tests/web still pass.
- instructions.md and work.md describe the rule.
- Out of scope: MATLAB client, the orphan-acq-blocking-analysis problem, check_deployed.sh.
