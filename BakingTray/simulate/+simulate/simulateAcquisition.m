function result = simulateAcquisition(varargin)
    % Fake an acquisition and push it through the web preview pipeline
    %
    % function result = simulate.simulateAcquisition('Param1',val1,...)
    %
    % Purpose
    % For each section 1..NumSections: build a synthetic RGB section image and a
    % gray montage, append that section's lines to a fresh acquisition log (exact
    % real format, see simulate.simulatedLogLines), call
    % webpreview.updateSectionImage, print one line with the outcome (the token is
    % never printed), then wait so the section took Interval seconds of wall
    % clock. The first call passes 'ClearStage', true, as BakingTray does at the
    % start of an acquisition.
    %
    % SAFETY: a real run must be given an explicit 'ConfigFile' (there is no
    % default, so a forgotten argument can never reach a production site) and the
    % config's url must contain 'testserver' or have the host localhost or
    % 127.0.0.1 (optional port), which can never be a production site. Pass
    % 'AllowProduction', true to override that check, only when you really mean to
    % write fake data to the named site. A dry run uploads nothing and needs neither.
    %
    % Time: each section's FINISHED line is stamped with the time it is written
    % and STARTING is the logged duration earlier, so no timestamp is in the
    % future. The logged duration is about Interval seconds (see
    % simulate.simulatedDurationSec), not a real section's ~285 s, times
    % LogTimeScale. The server's acquisition-time chart is in minutes, so
    % second-scale durations draw as ~0.1 min and its ETA collapses to "now";
    % 'LogTimeScale', 60 logs minutes-scale durations for a readable chart, at
    % the price of timestamps that lie in the past (STARTING lines earlier than
    % the run began, overlapping the previous section).
    %
    % Stopping: if a real upload fails with anything other than HTTP 429 (rate
    % limited, which later sections may recover from), the run stops after that
    % section instead of repeating the failure.
    %
    % Examples
    % r = simulate.simulateAcquisition('ConfigFile',f,'NumSections',10)
    % r = simulate.simulateAcquisition('DryRun',true,'NumSections',3,'Interval',0)
    %
    %
    % Inputs (optional param/val pairs)
    % 'ConfigFile' - Config JSON for the real upload (required unless DryRun).
    % 'NumSections' - Total number of sections, a positive integer (default 10).
    % 'Interval' - Seconds per section (default 5). The server rejects uploads
    %              closer together than simulate.simulationSpec().MinInterval
    %              (5 s); a real run with a smaller Interval warns
    %              'simulate:simulateAcquisition:fastInterval'.
    % 'DryRun' - If true use simulate.FakePoster: nothing touches the network,
    %            no config or site is needed, and the files that would be
    %            sent are recorded in result.dryRunCalls. Never aborts. Default false.
    % 'Poster' - Function handle poster(folder,cfg), as for updateSectionImage;
    %            default @webpreview.zipAndPost. Not allowed with DryRun.
    % 'AllowProduction' - If true skip the testserver/localhost url check (default false).
    % 'LogTimeScale' - Multiplies the durations written to the log only (default 1,
    %                  see Time above).
    % 'WorkDir' - Working folder for the recipe copy, log and stage folder;
    %             default a new folder under tempname (never in the repo).
    %             The log in it is overwritten.
    % 'RecipeFile' - Recipe to copy; default the first recipe_*.yml in this
    %                package's sample_data folder (an error if it is missing:
    %                pass RecipeFile). The copy has
    %                numSections set to NumSections and a neutral fake sample ID
    %                and objective, so the page agrees with the log and never
    %                shows a real sample.
    % 'Verbose' - Print progress lines (default true).
    %
    %
    % Outputs
    % result - Structure with fields: workDir, recipePath, logPath, dryRun, aborted,
    %          abortReason ('' unless aborted), sections (struct array, only the
    %          sections run: section, startTime, durationSec as logged, ok,
    %          httpStatus, message, update = the updateSectionImage result),
    %          dryRunCalls (FakePoster calls, [] if not a dry run).
    %
    % See also webpreview.updateSectionImage, simulate.simulationSpec, simulate.FakePoster


    opts = parseOptions(varargin);
    spec = simulate.simulationSpec();
    checkOptions(opts);

    cfg = [];   % a dry run builds its own throwaway config in chooseBackend
    if ~opts.DryRun
        cfg = webpreview.webConfig(char(opts.ConfigFile));
        checkTarget(cfg, opts.AllowProduction, spec);
        if opts.Interval<spec.MinInterval
            warning('simulate:simulateAcquisition:fastInterval', ...
                ['Interval %g s is below the server rate limit of %g s; ', ...
                 'uploads may be rejected (HTTP 429).'], ...
                opts.Interval, spec.MinInterval);
        end
    end


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Set up the work folder, the poster and the files the acquisition will write
    workDir = prepareWorkDir(opts.WorkDir);
    backend = chooseBackend(opts, spec, workDir, cfg);
    files = struct('recipe', '', 'log', fullfile(workDir, spec.LogName), ...
        'stageRoot', fullfile(workDir, 'stage'));
    N = opts.NumSections;
    sections = cell(1,N);
    aborted = false;
    abortReason = '';


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Main loop over sections
    for kk=1:N
        tStart = tic;
        loggedSec = simulate.loggedDurationSec( ...
            simulate.simulatedDurationSec(kk,opts.Interval), opts.LogTimeScale);
        startTime = datetime('now') - seconds(loggedSec);    % FINISHED lands at the time of writing

        if kk==1
            files.recipe = beginAcquisition(opts.RecipeFile, files.log, workDir, N, startTime);
        end

        sections{kk} = runSection(kk, N, startTime, loggedSec, files, backend);
        if opts.Verbose
            printSection(sections{kk}, N, opts.DryRun);
        end

        if shouldAbort(sections{kk}, opts.DryRun)
            aborted = true;
            abortReason = sprintf('section %d failed (HTTP %g): %s', kk, ...
                sections{kk}.httpStatus, sections{kk}.message);
            sections = sections(1:kk);
            break
        end

        if kk<N
            pause(max(0, opts.Interval - toc(tStart)));
        end
    end %for


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    result = struct('workDir', workDir, 'recipePath', files.recipe, 'logPath', files.log, ...
        'dryRun', opts.DryRun, 'aborted', aborted, 'abortReason', abortReason, ...
        'sections', [sections{:}], 'dryRunCalls', []);
    if opts.DryRun
        result.dryRunCalls = backend.recorder.Calls;
    end

end %simulateAcquisition


function opts = parseOptions(args)
    % Parse the name/value options into a structure with defaults filled in
    %
    % function opts = parseOptions(args)
    %
    % args is the varargin cell array of simulateAcquisition. Only the type and size of each
    % value is checked here; checkOptions checks the ranges.

    isNumScalar = @(x) (isnumeric(x) || islogical(x)) && isscalar(x);
    isFlag = @(x) isscalar(x) && (islogical(x) || (isnumeric(x) && ~isnan(x)));
    isText = @(x) (ischar(x) && (isrow(x) || isempty(x))) || (isstring(x) && isscalar(x));

    params = inputParser;
    params.CaseSensitive = false;
    params.addParameter('ConfigFile', '', isText);
    params.addParameter('NumSections', 10, isNumScalar);
    params.addParameter('Interval', 5, isNumScalar);
    params.addParameter('DryRun', false, isFlag);
    params.addParameter('Poster', []);
    params.addParameter('AllowProduction', false, isFlag);
    params.addParameter('LogTimeScale', 1, isNumScalar);
    params.addParameter('WorkDir', '', isText);
    params.addParameter('RecipeFile', '', isText);
    params.addParameter('Verbose', true, isFlag);
    params.parse(args{:});
    opts = params.Results;

    opts.NumSections = double(opts.NumSections);
    opts.Interval = double(opts.Interval);
    opts.LogTimeScale = double(opts.LogTimeScale);
    opts.DryRun = logical(opts.DryRun);
    opts.AllowProduction = logical(opts.AllowProduction);
    opts.Verbose = logical(opts.Verbose);
end %parseOptions


function checkOptions(opts)
    % Fail loudly on values the type checks in parseOptions let through
    %
    % function checkOptions(opts)

    n = opts.NumSections;
    if ~(isfinite(n) && n>=1 && n==round(n))
        error('simulate:simulateAcquisition:badNumSections', ...
            'NumSections must be a positive integer, got %g', n);
    end
    if ~(isfinite(opts.Interval) && opts.Interval>=0)
        error('simulate:simulateAcquisition:badInterval', ...
            'Interval must be a finite number >= 0, got %g', opts.Interval);
    end
    if ~(isfinite(opts.LogTimeScale) && opts.LogTimeScale>0)
        error('simulate:simulateAcquisition:badLogTimeScale', ...
            'LogTimeScale must be a finite number > 0, got %g', opts.LogTimeScale);
    end
    if ~isempty(opts.Poster) && ~isa(opts.Poster, 'function_handle')
        error('simulate:simulateAcquisition:badPoster', 'Poster must be a function handle');
    end
    if opts.DryRun && ~isempty(opts.Poster)
        error('simulate:simulateAcquisition:posterInDryRun', ...
            'DryRun uses its own fake poster; do not also pass Poster');
    end
    if ~opts.DryRun && isempty(opts.ConfigFile)
        error('simulate:simulateAcquisition:noConfig', ...
            ['a real run needs an explicit ''ConfigFile'' (pointing at a testserver or ', ...
             'localhost site); use ''DryRun'', true to run without one']);
    end
end %checkOptions


function checkTarget(cfg,allowProduction,spec)
    % Refuse to upload fake data to a url that is not known to be a test site. Only the url
    % is inspected, never the token.
    %
    % function checkTarget(cfg,allowProduction,spec)

    if ~allowProduction && ~isTestUrl(cfg.url, spec.CanaryMarker)
        error('simulate:simulateAcquisition:productionUrl', ...
            ['config url "%s" is neither a localhost url nor contains "%s"; refusing to ', ...
             'upload fake data (pass ''AllowProduction'', true to override)'], ...
            cfg.scrub(cfg.url), spec.CanaryMarker);
    end
end %checkTarget


function isTest = isTestUrl(url,marker)
    % True if a path segment of url is the canary marker or its host is exactly localhost or 127.0.0.1
    %
    % function isTest = isTestUrl(url,marker)
    %
    % The host must be followed by an optional :port and then '/' or the end of the url, so
    % http://localhost@evil.example/ (userinfo), http://localhost.evil.com/ and
    % https://x/localhost are not local. The marker must be a whole segment of the path
    % (not the host, a query string or part of a longer name), e.g. https://x/testserver/upload.php.

    isLocal = ~isempty(regexp(url, '^https?://(localhost|127\.0\.0\.1)(:\d+)?(/|$)', 'once'));
    inPath = ~isempty(regexp(url, ['^https?://[^/?#]+(/[^/?#]*)*/', regexptranslate('escape', marker), '(/|$)'], 'once'));
    isTest = isLocal || inPath;
end %isTestUrl


function workDir = prepareWorkDir(requested)
    % Return the work folder, creating it if needed. Empty requested gives a new tempname.
    %
    % function workDir = prepareWorkDir(requested)

    if isempty(requested)
        workDir = tempname;
    else
        workDir = char(requested);
    end

    if ~isfolder(workDir)
        [ok,msg] = mkdir(workDir);
        if ~ok
            error('simulate:simulateAcquisition:workDir', ...
                'cannot create WorkDir "%s": %s', workDir, msg);
        end
    end
end %prepareWorkDir


function backend = chooseBackend(opts,spec,workDir,cfg)
    % Choose the poster and config object
    %
    % function backend = chooseBackend(opts,spec,workDir,cfg)
    %
    % Dry run: fake poster and a throwaway config (updateSectionImage always needs one).
    % Real run: the given Poster (default zipAndPost) and the webConfig built from ConfigFile.

    backend = struct('poster', [], 'cfg', cfg, 'recorder', []);
    if opts.DryRun
        recorder = simulate.FakePoster();
        backend.recorder = recorder;
        backend.poster = @recorder.post;
        configFile = fullfile(workDir, 'dryrun_config.json');
        writeLines(configFile, {jsonencode(spec.DryRunConfig)}, 'w');
        backend.cfg = webpreview.webConfig(configFile);
    elseif isempty(opts.Poster)
        backend.poster = @webpreview.zipAndPost;
    else
        backend.poster = opts.Poster;
    end
end %chooseBackend


function recipePath = beginAcquisition(recipeSource,logPath,workDir,N,startTime)
    % Write a fresh log with the header, and the patched recipe copy
    %
    % function recipePath = beginAcquisition(recipeSource,logPath,workDir,N,startTime)

    writeLines(logPath, simulate.simulatedLogHeader(startTime), 'w');
    if isempty(recipeSource)
        recipeSource = defaultRecipe();
    end
    if ~isfile(recipeSource)
        error('simulate:simulateAcquisition:noRecipe', 'recipe file not found: %s', recipeSource);
    end

    [~,name,ext] = fileparts(recipeSource);
    recipePath = fullfile(workDir, [name ext]);
    text = simulate.simulatedRecipeText(fileread(recipeSource), N, startTime);
    writeLines(recipePath, {text}, 'w');
end %beginAcquisition


function file = defaultRecipe()
    % Path of the first recipe_*.yml in the sample_data folder next to the +simulate folder
    %
    % function file = defaultRecipe()

    % +simulate -> simulate, which holds sample_data
    pkgDir = fileparts(mfilename('fullpath'));
    sampleDir = fullfile(fileparts(pkgDir), 'sample_data');
    found = dir(fullfile(sampleDir, 'recipe_*.yml'));
    if isempty(found)
        error('simulate:simulateAcquisition:noRecipe', ...
            'no recipe_*.yml in %s; pass ''RecipeFile''', sampleDir);
    end
    file = fullfile(found(1).folder, found(1).name);
end %defaultRecipe


function sec = runSection(k,N,startTime,loggedSec,files,backend)
    % Write section k's log lines, build its images and push it through updateSectionImage
    %
    % function sec = runSection(k,N,startTime,loggedSec,files,backend)

    % Log lines first, as in a real acquisition where FINISHED precedes the call.
    writeLines(files.log, simulate.simulatedLogLines(k,N,startTime,loggedSec), 'a');
    [img,montage] = simulate.simulatedImages(k,N);
    update = webpreview.updateSectionImage(img, files.recipe, files.log, ...
        backend.cfg, 'Montage', montage, ...
        'Poster', backend.poster, 'StageRoot', files.stageRoot, 'ClearStage', k==1);
    sec = struct('section', k, 'startTime', startTime, 'durationSec', loggedSec, ...
        'ok', update.ok, 'httpStatus', update.post.httpStatus, ...
        'message', update.post.message, 'update', update);
end %runSection


function stop = shouldAbort(sec,dryRun)
    % True if a real upload failed in a way that will repeat
    %
    % function stop = shouldAbort(sec,dryRun)
    %
    % 429 means "too fast"; the next section is slower. Anything else (auth, size,
    % network, staging) will repeat, so stop instead of failing N times.

    stop = ~dryRun && ~sec.ok && ~isequal(sec.httpStatus, 429);
end %shouldAbort


function printSection(sec,N,dryRun)
    % Print one line per section. The message is already token-scrubbed by zipAndPost.
    %
    % function printSection(sec,N,dryRun)

    status = 'FAILED';
    if sec.ok
        status = 'ok';
    end
    mode = '';
    if dryRun
        mode = ' (dry run)';
    end
    fprintf('section %d/%d: %s%s, HTTP %g: %s\n', sec.section, N, status, mode, ...
        sec.httpStatus, sec.message);
end %printSection


function writeLines(file,lines,permission)
    % Write a cellstr to file, one entry per line, using the fopen permission given
    %
    % function writeLines(file,lines,permission)

    fid = fopen(file, permission);
    if fid<0
        error('simulate:simulateAcquisition:writeFailed', 'cannot open %s for writing', file);
    end
    closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', lines{:});
end %writeLines
