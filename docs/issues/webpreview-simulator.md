---
type: infrastructure
complexity: simple
status: done
---
# Simulate an acquisition against a real server

Depends on: webpreview-entrypoint.
`webpreview.simulateAcquisition('ConfigFile', f, 'NumSections', n, 'Interval', 5)`: builds a temp dir,
generates a synthetic test image per section (e.g. noise+section number text so progress is visible),
starts from the first lines of `test_images/acqLog_*.txt` (header) and appends STARTING/FINISHED lines in the
real log format every `Interval` seconds (timestamps current), uses `test_images/recipe_*.yml`, and calls
updateSectionImage after each section. Prints server responses. Must honour the server's 5 s rate limit.
Use `test-upload/` URL by default per `instructions.md` §7.

## Acceptance criteria
- Test of the log-line generator: output parses with the same regexes as `bs_parse_acqlogs()` in lib.php.
- Runnable on Mac; a dry-run mode (no network) so it can be tested without a site.
