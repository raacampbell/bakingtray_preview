---
type: infrastructure
complexity: simple
status: in review
---

# webConfig object passed in by the caller; micID required; fix what is broken

The PI moved config loading into a class `webpreview.webConfig` (BakingTray/webpreview/+webpreview/webConfig.m)
and deliberately DELETED several small functions (loadConfig, checkUrl, defaultConfigPath, timeouts, tokenOf,
scrubToken) and inlined some validators, because there were too many functions. Do NOT bring any of them back,
as files or as new local helpers doing the same job. Keep the code lean; fewer lines is better when behaviour
is kept.

Plan the PI described: BakingTray will build the config object ONCE at startup, keep it, and pass it to this
module after each section. The module must not know about BakingTray.

## Changes
1. micID REQUIRED: a required text field in the config file (same trimming, same [A-Za-z0-9_-] rule as siteID,
   error ids as for siteID: configIncomplete if missing/empty, configWrongType if not a string, configInvalid if
   bad characters). Add it to webpreview_config.example.json and the READMEs. Use it:
   - stage folder becomes <StageRoot>/brainsaw_webpreview/<siteID>/<micID> (stageDirFor; clearStage must still
     remove only that folder);
   - postZip sends an extra multipart field `microscope_id` = micID (the server will require it in a later work
     item; today's server ignores unknown fields, so this is safe).
2. Config object passed in: `updateSectionImage(img, recipePath, logPath, cfg, ...)` and `clearStage(cfg, ...)`
   take a webpreview.webConfig as a required positional argument. Remove the 'ConfigFile' option and all code
   that loaded the config or scrubbed before the config was known (that whole case disappears). A cfg that is not
   a scalar valid webConfig is a failure handled by the existing never-throw policy (warning + ok=false for
   updateSectionImage; warning + false for clearStage). Poster contract stays poster(folder, cfg).
3. Streamline webConfig without changing its public behaviour: loop over the text fields and the two ID fields
   instead of repeating blocks, drop the intermediate cfg struct, etc. Keep the token protections (private
   transient token, authHeader, scrub, scrubbed constructor errors). Only simplify where clearly shorter and
   clearer; do not add abstractions.
4. Fix what is broken. Test status on tidy_bakingtray: 181 tests, 18 fail.
   - 9 NEW, all in SimulateAcquisitionTest: the simulator still calls webpreview.loadConfig (deleted). Build a
     webConfig once from its 'ConfigFile' option and pass it on. Fix BakingTray/simulate/README.md
     (webpreview.defaultConfigPath is deleted).
   - 9 ALSO FAIL ON main (code never run before): StageFilesTest/{toUint8IntegerClassRangeIsUsedAsDouble,
     copyFailureWarnsAndStillStagesImageAndRecipe, sameFileDifferentCaseNameIsNotDeletedOnCaseInsensitiveSystems,
     staleDifferentlyCasedLogIsRemoved, undeletableStaleFileSetsStageFailed}, UpdateSectionImageTest/
     {malformedErrorIdentifierDoesNotThrow, clearStageNeverThrowsEvenForBadArguments, warningsAsErrorsDoNotMakeItThrow},
     SimulateAcquisitionTest/recipeTextReplacesSampleAndObjective. For each, decide whether the CODE or the TEST
     is wrong and fix the right one, with evidence. A test that cannot be valid on this platform uses an assume*
     with a clear reason. Do not weaken a test just to make it pass.
   - Check the unverified points from the PI's notes: evalc('disp(cfg)') hiding the token; char(h.Name)/
     char(h.Value) on HeaderField; Constant property read via instance; isvalid(cfg) inside &&; tokenFromFile
     regexp with escaped characters; throwAsCaller of a rebuilt MException; property-set-from-outside test
     (find the real error id and use verifyError).
5. Update tests for the new signatures (WebConfigTest micID, PostZipTest microscope_id, UpdateSectionImageTest/
   clearStage tests for the cfg argument and for a non-webConfig cfg being non-fatal). Remove tests that only
   covered the deleted ConfigFile/scrub-before-load paths.
6. Docs: BakingTray/webpreview/README.md, the simulator README, example JSON. Keep short; delete stale text.

## Acceptance criteria
- All tests in BakingTray/webpreview/tests and BakingTray/simulate/tests pass in MATLAB R2023b (or are skipped by
  an assume with a stated reason).
- No reference to loadConfig, tokenOf, scrubToken, webpreview.timeouts, webpreview.checkUrl,
  webpreview.defaultConfigPath, rawToken, or 'ConfigFile' in BakingTray/webpreview (simulate keeps its own
  ConfigFile option).
- Net line count of BakingTray/webpreview/+webpreview does not grow beyond what micID strictly needs.
- `simulate.simulateAcquisition('DryRun',true,'NumSections',2,'Interval',0)` runs.
