# BakingTray side of the web preview

The staging and upload code is not BakingTray-specific: it is the
`webupload` package in `upload_core/` (see `upload_core/README.md` for the
config file, the token, `webupload.updateSectionImage` and its options). This
folder holds only what is on the BakingTray side:

- `simulate/`, a fake acquisition for testing the pipeline and the server
  (`simulate/README.md`);
- `tests/`, tests that use the simulator's sample recipe;
- the example call sites below.

Nothing here is installed into BakingTray, and these examples do not change it.
The real BakingTray needs `upload_core` on its MATLAB path (the folder
containing `+webupload`) and a `webupload.webConfig` object, built once at
startup and kept, as described in `upload_core/README.md`.

## Example call sites

BakingTray uses source `acq` and never sends a montage. Each call is guarded
twice: `which` keeps acquisition running if `upload_core` is not on the path,
and `try`/`catch` covers a path variable that does not exist (MATLAB raises that
before `updateSectionImage` starts, so it cannot be caught inside it).
`updateSectionImage` itself never throws.

### Start of an acquisition (`bake.m`)

Once, after the recipe and the acquisition log exist. No image yet (`[]`), so
the page shows the new recipe and any image from a previous run is deleted;
`'ClearStage', true` also empties the stage folder. The short timeouts keep the
call from holding up the start of the acquisition when the server is slow or
dead.

```matlab
if ~isempty(which('webupload.updateSectionImage'))
    try
        webupload.updateSectionImage([], recipePath, logPath, cfg, ...
            'ClearStage', true, 'ConnectTimeout', 5, 'ResponseTimeout', 10);
    catch ME
        warning('preview:unexpected', 'Web preview failed: %s', ME.message);
    end
end
```

### After each section (`sliceSample.m`, during the cut)

`img` is the latest section image (gray HxW or RGB HxWx3). Non-uint8 images are
autoscaled; pass `'Range', [0 4095]` for a fixed mapping (see
`upload_core/README.md`).

```matlab
if ~isempty(which('webupload.updateSectionImage'))
    try
        webupload.updateSectionImage(img, recipePath, logPath, cfg, ...
            'ConnectTimeout', 5, 'ResponseTimeout', 10, 'Range', [0 4095]);
    catch ME
        warning('preview:unexpected', 'Web preview failed: %s', ME.message);
    end
end
```

### End of an acquisition (`bake.m`)

Marks the run finished on the page. If the server answers 429 (this call comes
soon after the last section's) it waits about 6 s and tries once more, so this
call can block for longer than the others.

```matlab
if ~isempty(which('webupload.updateSectionImage'))
    try
        webupload.updateSectionImage(img, recipePath, logPath, cfg, ...
            'Finished', true, 'ConnectTimeout', 5, 'ResponseTimeout', 10);
    catch ME
        warning('preview:unexpected', 'Web preview failed: %s', ME.message);
    end
end
```

The result structure (`ok`, `post`, `error`, ...) is described in
`upload_core/README.md`; assign it (`res = webupload.updateSectionImage(...)`)
if the caller wants it.

## Tests

From the repo root (this runs everything, including `upload_core/tests`):

```
/Applications/MATLAB_R2023b.app/bin/matlab -batch "add_to_path; r=[runtests('upload_core/tests'), runtests('BakingTray/tests'), runtests('BakingTray/simulate/tests')]; disp(table(r))"
```

`add_to_path` puts `upload_core` and `BakingTray/simulate` on the path.
