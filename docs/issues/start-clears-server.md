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
When an upload for a microscope contains no LastCompleteSection.jpg AND its status.json says finished:false (the "start of run" call), the server empties BOTH source folders of that microscope (acq/ and analysis/: every file in them, including meta.json) before installing the upload, then installs the upload's files (recipe.yml, acqLog.txt, status.json, anything else sent) into the SENDER's source folder as usual. Consequences the PI accepts: an analysis start call also wipes acq/ (and vice versa); the other source's data returns with its next upload. When the other source's folder is gone the display rule falls back to what remains (acq/ missing = analysis alone, and so on); the display rule is not changed.

The guard `finished:false` is deliberate: an end-of-run call (finished:true) that carries no image must NOT wipe the final images. instructions.md says so.

Uploads that contain LastCompleteSection.jpg behave exactly as before (including the sample-ID-changed emptying of the sender's own folder).

## Details
- Concurrency: the per-source lock is a dotfile in the microscope folder. Wiping the other source's folder takes that source's lock too; both locks are taken in a fixed order (acq then analysis) so two uploads cannot deadlock. The rate-limit re-check under the lock is for the sender's source only; a rate-limited sender (429) changes nothing on disk.
- The wipe only deletes regular files inside the two source folders; the folders, the .lock files and .tmp-* dirs are left alone. If a file cannot be deleted the response is 500 (as in bs_install_upload) and it is logged; the sender's meta.json must not claim an upload that did not complete.
- Validation (bs_check_upload) happens before any wipe: a refused upload (400 etc.) wipes nothing.
- Unchanged: allowed names, the contract (tests/web/upload_contract.json and its sha256), the finished rule, the display rule, autorefresh.

## Acceptance criteria
- tests/web/check_pages.sh covers: acq + analysis present with the same sample ID, then an acq upload with no image and finished:false -> acq/ holds only the new files, analysis/ is empty, the page shows the new recipe and no image; the same with an analysis start call wiping acq/; no-image upload with finished:true -> nothing wiped; image-bearing upload -> other source untouched; refused (400) and rate-limited (429) no-image uploads wipe nothing; ?f= for wiped assets 404.
- All existing check_pages.sh and node tests in tests/web still pass.
- instructions.md and work.md describe the rule.
- Out of scope: MATLAB client, the orphan-acq-blocking-analysis problem, check_deployed.sh.
