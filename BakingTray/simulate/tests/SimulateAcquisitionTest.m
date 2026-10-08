classdef SimulateAcquisitionTest < matlab.unittest.TestCase
    % Tests for simulate.simulateAcquisition and its pure helpers. Nothing
    % touches the network; recipes are synthetic temp files. The log-format
    % tests use a copy of the server's regexes (below) so they run when the
    % simulator is used without the repo; one drift test compares that copy
    % with brainsaw/lib.php when the repo is present.
    % Run: runtests(fullfile(<repo>, 'BakingTray', 'simulate', 'tests'))

    properties
        Dir
        Recipe
        Config          % config whose url is a testserver canary
        ProdConfig      % config whose url is not
        Fmt = 'yyyy/MM/dd HH:mm:ss'
        T0 = datetime(2026, 10, 7, 12, 3, 50)
        PosterStatus    % http status the scripted poster returns (NaN: ok)
        PosterCalls     % number of calls the scripted poster saw
        StageSeen       % per call: [stale file present, marker present before the call]
    end

    methods (TestClassSetup)
        function addPackageToPath(tc)
            % simulate/ and the BakingTray and webupload packages it drives
            simDir = fileparts(fileparts(mfilename('fullpath')));
            bakingTrayDir = fileparts(simDir);
            coreDir = fullfile(fileparts(bakingTrayDir), 'upload_core');
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(simDir));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(bakingTrayDir));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(coreDir));
        end
    end

    methods (TestMethodSetup)
        function makeFixtures(tc)
            tc.Dir = tempname;
            mkdir(tc.Dir);
            tc.addTeardown(@() rmdir(tc.Dir, 's'));
            tc.Recipe = fullfile(tc.Dir, 'recipe_test.yml');
            writeText(tc.Recipe, sprintf(['Acquisition: {acqStartTime: ''2019/12/09 12:03:50''}\n' ...
                'sample: {ID: REALSAMPLE, objectiveName: real objective 16x}\nmosaic:\n  numSections: 289.0\nSYSTEM:\n  ID: brainsaw\n']));
            tc.Config = fullfile(tc.Dir, 'config.json');
            writeText(tc.Config, '{"url":"https://x.example/testserver/upload.php","siteID":"sim-1","token":"TOK"}');
            tc.ProdConfig = fullfile(tc.Dir, 'prod.json');
            writeText(tc.ProdConfig, '{"url":"https://x.example/brainsaw/upload.php","siteID":"sim-1","token":"TOK"}');
            tc.PosterStatus = NaN;
            tc.PosterCalls = 0;
            tc.StageSeen = zeros(0, 2);
        end
    end

    methods (Test)
        % ---- server regexes ----
        function serverRegexCopyMatchesLibPhp(tc)
            % Repo-only: skipped when brainsaw/ is not present.
            % tests -> simulate -> BakingTray -> repo root
            lib = fullfile(fileparts(mfilename('fullpath')), '..', '..', '..', 'brainsaw', 'lib.php');
            tc.assumeTrue(isfile(lib), 'brainsaw/lib.php not present');
            found = regexp(fileread(lib), '''/(\^\(\\d\{4\}[^\n]*)/'',', 'tokens');
            patterns = cellfun(@(c) c{1}, found, 'UniformOutput', false);
            [startRe, finishRe] = serverRegexes();
            tc.verifyEqual(sort(patterns), sort({startRe, finishRe}));
        end

        % ---- log lines ----
        function logLinesMatchServerRegexes(tc)
            [startRe, finishRe] = serverRegexes();
            lines = simulate.simulatedLogLines(7, 289, tc.T0, 285);
            tc.verifyNumElements(lines, 5);
            tc.verifyNotEmpty(regexp(lines{1}, startRe, 'once'));
            tc.verifyNotEmpty(regexp(lines{5}, finishRe, 'once'));
            for ii = 2:4    % laser and acquired lines are neither STARTING nor FINISHED
                tc.verifyEmpty(regexp(lines{ii}, startRe, 'once'));
                tc.verifyEmpty(regexp(lines{ii}, finishRe, 'once'));
            end
        end

        function logLinesEqualTheRealFormatExactly(tc)
            % Shape taken from test_images/acqLog_*.txt; the directory is
            % backslash text and must come out literally.
            lines = simulate.simulatedLogLines(1, 289, tc.T0, 285);
            tc.verifyEqual(lines{1}, ['2026/10/07 12:03:50 -- STARTING section number 1 (1 of 289) ' ...
                'at z=24.3800 in directory F:\SIMULATED\rawData\SIM-0001']);
            tc.verifyEqual(lines{3}, '2026/10/07 12:07:38 -- acquired 274 tile positions in 3 mins 48 secs');
            tc.verifyEqual(lines{5}, '2026/10/07 12:08:35 -- FINISHED section number 1, section completed in 4 mins 45 secs');
            tc.verifyNotEmpty(regexp(lines{2}, ...
                '^laser status: wavelength=920nm,outputPower=2100mW,pumpPower=\d+mW,pumpCurrent=97\.1,humidity=2\.0$', 'once'));
            tc.verifyEqual(lines{2}(1:13), 'laser status:');
        end

        function logLinesHaveNoControlCharacters(tc)
            lines = simulate.simulatedLogLines(12, 289, tc.T0, 285);
            tc.verifyTrue(all(double(char(strjoin(lines, ' '))) >= 32));
            hdr = simulate.simulatedLogHeader(tc.T0);
            tc.verifyTrue(all(double(char(strjoin(hdr, ' '))) >= 32));
        end

        function logLinesCarryTheRightNumbers(tc)
            [startRe, finishRe] = serverRegexes();
            lines = simulate.simulatedLogLines(7, 289, tc.T0, 285);
            s = regexp(lines{1}, startRe, 'tokens', 'once');
            tc.verifyEqual(s(2:4), {'7', '7', '289'});
            f = regexp(lines{5}, finishRe, 'tokens', 'once');
            tc.verifyEqual(f(2:4), {'7', '4', '45'});      % 285 s = 4 mins 45 secs
        end

        function logLinesTimestampsAreConsistent(tc)
            [startRe, finishRe] = serverRegexes();
            for dur = [2 5 61 285]
                lines = simulate.simulatedLogLines(2, 3, tc.T0, dur);
                tc.verifyEqual(stampOf(lines{5}, finishRe, tc.Fmt) - stampOf(lines{1}, startRe, tc.Fmt), seconds(dur));
                acq = regexp(lines{3}, '^(\S+ \S+) -- acquired (\d+) tile positions in (\d+) mins (\d+) secs$', 'tokens', 'once');
                tc.assertNotEmpty(acq);
                acqSec = 60 * str2double(acq{3}) + str2double(acq{4});
                tc.verifyEqual(datetime(acq{1}, 'InputFormat', tc.Fmt) - stampOf(lines{1}, startRe, tc.Fmt), seconds(acqSec));
                tc.verifyLessThanOrEqual(acqSec, dur);
            end
        end

        function logLinesAreDeterministic(tc)
            tc.verifyEqual(simulate.simulatedLogLines(3, 5, tc.T0, 10), ...
                simulate.simulatedLogLines(3, 5, tc.T0, 10));
        end

        function logLinesRejectSectionBeyondTotal(tc)
            tc.verifyError(@() simulate.simulatedLogLines(4, 3, tc.T0, 10), ...
                'simulate:simulatedLogLines:badSection');
        end

        function headerHasOneTimestampedStartLineAndNoSectionLine(tc)
            [startRe, finishRe] = serverRegexes();
            hdr = simulate.simulatedLogHeader(tc.T0);
            tc.verifyTrue(any(strcmp(hdr, '2026/10/07 12:03:50 -- STARTING NEW ACQUISITION')));
            tc.verifyEmpty(regexp(strjoin(hdr, newline), startRe, 'once', 'lineanchors'));
            tc.verifyEmpty(regexp(strjoin(hdr, newline), finishRe, 'once', 'lineanchors'));
        end

        function wholeLogParsesLikeTheServer(tc)
            [startRe, finishRe] = serverRegexes();
            lines = simulate.simulatedLogHeader(tc.T0);
            for k = 1:3
                lines = [lines; simulate.simulatedLogLines(k, 3, tc.T0 + seconds(10 * k), 8)]; %#ok<AGROW>
            end
            nFinished = nnz(~cellfun(@isempty, regexp(lines, finishRe, 'once')));
            nStarting = nnz(~cellfun(@isempty, regexp(lines, startRe, 'once')));
            tc.verifyEqual([nStarting nFinished], [3 3]);
        end

        % ---- durations ----
        function simulatedDurationsTrackIntervalWithoutExceedingIt(tc)
            d = arrayfun(@(k) simulate.simulatedDurationSec(k, 5), 1:6);
            tc.verifyEqual(d, [4 3 5 4 3 5]);
            tc.verifyLessThanOrEqual(max(d), 5);
            tc.verifyGreaterThan(numel(unique(d)), 1);
            tc.verifyEqual(simulate.simulatedDurationSec(1, 0), 1);
        end

        function loggedDurationScales(tc)
            tc.verifyEqual(simulate.loggedDurationSec(5, 1), 5);
            tc.verifyEqual(simulate.loggedDurationSec(5, 60), 300);
            tc.verifyEqual(simulate.loggedDurationSec(1, 0.1), 1);   % never below 1 s
        end

        % ---- images ----
        function imagesAreUint8WithSpecSizes(tc)
            spec = simulate.simulationSpec();
            [img, montage] = simulate.simulatedImages(12, 20);
            tc.verifyClass(img, 'uint8');
            tc.verifySize(img, [spec.ImageSize 3]);
            tc.verifyClass(montage, 'uint8');
            tc.verifySize(montage, spec.MontageSize);
            tc.verifyEqual(BakingTray.webpreview.toUint8(img), img);
            tc.verifyEqual(BakingTray.webpreview.toUint8(montage), montage);
        end

        function imagesDifferBetweenSectionsAndAreRepeatable(tc)
            a = simulate.simulatedImages(1, 5);
            b = simulate.simulatedImages(2, 5);
            tc.verifyNotEqual(a, b);
            tc.verifyEqual(a, simulate.simulatedImages(1, 5));
        end

        function imagesLeaveGlobalRandomStreamAlone(tc)
            saved = rng;
            tc.addTeardown(@() rng(saved));
            rng(5);
            before = rand(1, 3);
            rng(5);
            simulate.simulatedImages(3, 5);
            tc.verifyEqual(rand(1, 3), before);
        end

        function numberMaskIsLogicalAndDigitsDiffer(tc)
            m7 = simulate.renderNumberMask(7, 2);
            tc.verifyClass(m7, 'logical');
            tc.verifySize(m7, [10 6]);
            tc.verifyClass(simulate.renderNumberMask(12, 2), 'logical');
            tc.verifySize(simulate.renderNumberMask(12, 2), [10 14]);   % 2 digits + 1 cell gap
            tc.verifyNotEqual(m7, simulate.renderNumberMask(1, 2));
        end

        function simulatedImagesStageWithStageFiles(tc)
            [img, montage] = simulate.simulatedImages(4, 9);
            logFile = fullfile(tc.Dir, 'acqLog_x.txt');
            writeText(logFile, 'x');
            stageDir = fullfile(tc.Dir, 'stage');
            res = BakingTray.webpreview.stageFiles(img, tc.Recipe, logFile, stageDir, 'Montage', montage);
            tc.verifyTrue(res.stageOk);
            tc.verifyTrue(isfile(fullfile(stageDir, 'LastCompleteSection.jpg')));
            tc.verifyTrue(isfile(fullfile(stageDir, 'montage.jpg')));
        end

        % ---- recipe patching ----
        function recipeTextSetsNumSectionsInTheKeyTheServerReads(tc)
            out = simulate.simulatedRecipeText(fileread(tc.Recipe), 42, tc.T0);
            tok = regexp(out, '^\s*numSections:\s*([\d.]+)', 'tokens', 'once', 'lineanchors');   % as bs_parse_recipe
            tc.verifyEqual(str2double(tok{1}), 42);
            tc.verifyNotEmpty(strfind(out, '2026/10/07 12:03:50'));
        end

        function recipeTextReplacesSampleAndObjective(tc)
            out = simulate.simulatedRecipeText(fileread(tc.Recipe), 3, tc.T0);
            tc.verifyEmpty(strfind(out, 'REALSAMPLE'));
            tc.verifyEmpty(strfind(out, 'real objective'));
            id = regexp(out, '^sample:\s*\{[^}]*\<ID:\s*([^,}\s]+)', 'tokens', 'once', 'lineanchors');   % as bs_parse_recipe
            obj = regexp(out, '^sample:\s*\{[^}]*objectiveName:\s*([^,}]+)', 'tokens', 'once', 'lineanchors');
            tc.verifyEqual(id{1}, 'SIMULATED');
            tc.verifyEqual(strtrim(obj{1}), 'simulated objective');
        end

        function recipeTextWithoutNumSectionsErrors(tc)
            tc.verifyError(@() simulate.simulatedRecipeText('sample: A', 3, tc.T0), ...
                'simulate:simulatedRecipeText:noNumSections');
        end

        % ---- dry run end to end ----
        function dryRunStagesAllFilesForThreeSections(tc)
            [~, finishRe] = serverRegexes();
            r = tc.dry('NumSections', 3);
            tc.verifyTrue(r.dryRun);
            tc.verifyFalse(r.aborted);
            tc.verifyTrue(all([r.sections.ok]));
            tc.verifyNumElements(r.dryRunCalls, 3);
            last = r.dryRunCalls(end);
            tc.verifyEqual(last.names, ...
                {'LastCompleteSection.jpg', 'acqLog.txt', 'montage.jpg', 'recipe.yml', 'status.json'});
            tc.verifyTrue(all(last.bytes > 0));
            for k = 1:3     % the log grows by one FINISHED line per upload
                nFinished = nnz(~cellfun(@isempty, ...
                    regexp(splitlines(r.dryRunCalls(k).logText), finishRe, 'once')));
                tc.verifyEqual(nFinished, k);
            end
        end

        function dryRunWorkDirHoldsRecipeAndLogAndNeedsNoConfig(tc)
            work = fullfile(tc.Dir, 'work');
            r = tc.dry('NumSections', 1, 'WorkDir', work);
            tc.verifyEqual(r.workDir, work);
            tc.verifyEqual(fileparts(r.logPath), work);
            tc.verifyTrue(isfile(r.logPath));
            text = fileread(r.recipePath);
            tok = regexp(text, '^\s*numSections:\s*([\d.]+)', 'tokens', 'once', 'lineanchors');
            tc.verifyEqual(str2double(tok{1}), 1);
        end

        function dryRunIgnoresAConfigFile(tc)
            r = tc.dry('NumSections', 1, 'ConfigFile', tc.ProdConfig);
            tc.verifyTrue(r.sections.ok);
        end

        function defaultWorkDirIsOutsideRepo(tc)
            r = tc.dry('NumSections', 1, 'WorkDir', '');
            tc.addTeardown(@() rmdir(r.workDir, 's'));
            tc.verifyEqual(fileparts(r.workDir), fileparts(tempname));
        end

        function defaultRecipeIsFoundInSampleData(tc)
            simDir = fileparts(fileparts(which('simulate.simulateAcquisition')));
            tc.assertNotEmpty(dir(fullfile(simDir, 'sample_data', 'recipe_*.yml')));
            r = tc.dry('NumSections', 1, 'RecipeFile', '');
            [~, name] = fileparts(r.recipePath);
            tc.verifyTrue(startsWith(name, 'recipe_'));
            tc.verifyTrue(isfile(r.recipePath));
        end

        function loggedTimesNeverInFutureAndFinishedIsStartPlusDuration(tc)
            [startRe, finishRe] = serverRegexes();
            r = tc.dry('NumSections', 3);
            now0 = datetime('now');
            lines = splitlines(fileread(r.logPath));
            for k = 1:3
                s = stampOf(lines{find(~cellfun(@isempty, regexp(lines, ...
                    sprintf('STARTING section number %d ', k), 'once')), 1)}, startRe, tc.Fmt);
                f = stampOf(lines{find(~cellfun(@isempty, regexp(lines, ...
                    sprintf('FINISHED section number %d,', k), 'once')), 1)}, finishRe, tc.Fmt);
                tc.verifyLessThanOrEqual(f, now0);
                tc.verifyEqual(f - s, seconds(r.sections(k).durationSec));
            end
            tc.verifyTrue(all(double(fileread(r.logPath)) >= 10 & double(fileread(r.logPath)) ~= 13));
        end

        function logTimeScaleMultipliesLoggedDurationsOnly(tc)
            r = tc.dry('NumSections', 2, 'LogTimeScale', 60);
            tc.verifyEqual([r.sections.durationSec], [60 60]);   % 1 s * 60
            tc.verifyNotEmpty(strfind(fileread(r.logPath), 'section completed in 1 mins 0 secs'));
            tc.verifyLessThanOrEqual(max([r.sections.startTime]), datetime('now'));
        end

        % ---- real mode (injected poster) ----
        function realModeUsesInjectedPosterAndConfig(tc)
            poster = simulate.FakePoster();
            r = tc.verifyWarningFreeCall(@() simulate.simulateAcquisition( ...
                'ConfigFile', tc.Config, 'NumSections', 1, 'Interval', 5, 'Poster', @poster.post, ...
                'WorkDir', fullfile(tc.Dir, 'w'), 'RecipeFile', tc.Recipe, 'Verbose', false));
            tc.verifyFalse(r.dryRun);
            tc.verifyNumElements(poster.Calls, 1);
            tc.verifyEmpty(r.dryRunCalls);
        end

        function fastIntervalWarnsOnlyInRealMode(tc)
            poster = simulate.FakePoster();
            real = @() simulate.simulateAcquisition('ConfigFile', tc.Config, 'NumSections', 1, ...
                'Interval', 1, 'Poster', @poster.post, 'WorkDir', fullfile(tc.Dir, 'w1'), ...
                'RecipeFile', tc.Recipe, 'Verbose', false);
            tc.verifyWarning(real, 'simulate:simulateAcquisition:fastInterval');
            tc.verifyWarningFree(@() tc.dry('NumSections', 1, 'Interval', 0));
        end

        function clearStageOnlyOnFirstSection(tc)
            work = fullfile(tc.Dir, 'w2');
            stale = fullfile(work, 'stage', 'brainsaw_webpreview', 'sim-1', 'brainsaw', 'acq', 'stale.txt');
            mkdir(fileparts(stale));
            writeText(stale, 'old');
            tc.runReal(@tc.markerPoster, 'NumSections', 2, 'WorkDir', work);
            tc.verifyEqual(tc.StageSeen(1, :), [0 0]);   % stale file cleared at call 1
            tc.verifyEqual(tc.StageSeen(2, 2), 1);       % call 1's marker survives to call 2
        end

        function failureOtherThan429AbortsTheRun(tc)
            tc.PosterStatus = 403;
            r = tc.runReal(@tc.statusPoster, 'NumSections', 3);
            tc.verifyTrue(r.aborted);
            tc.verifyEqual(tc.PosterCalls, 1);
            tc.verifyNumElements(r.sections, 1);
            tc.verifyNotEmpty(strfind(r.abortReason, '403'));
        end

        function rateLimitDoesNotAbortTheRun(tc)
            tc.PosterStatus = 429;
            r = tc.runReal(@tc.statusPoster, 'NumSections', 3);
            tc.verifyFalse(r.aborted);
            tc.verifyEqual(tc.PosterCalls, 3);
            tc.verifyNumElements(r.sections, 3);
        end

        % ---- safety ----
        function realRunRequiresExplicitConfigFile(tc)
            tc.verifyError(@() simulate.simulateAcquisition('NumSections', 1, 'Verbose', false, ...
                'RecipeFile', tc.Recipe, 'WorkDir', fullfile(tc.Dir, 'w3')), ...
                'simulate:simulateAcquisition:noConfig');
        end

        function realRunRefusesNonTestUploadUrl(tc)
            poster = simulate.FakePoster();
            args = {'ConfigFile', tc.ProdConfig, 'NumSections', 1, 'Interval', 5, 'Poster', @poster.post, ...
                'WorkDir', fullfile(tc.Dir, 'w4'), 'RecipeFile', tc.Recipe, 'Verbose', false};
            tc.verifyError(@() simulate.simulateAcquisition(args{:}), ...
                'simulate:simulateAcquisition:productionUrl');
            tc.verifyEmpty(poster.Calls);
            simulate.simulateAcquisition(args{:}, 'AllowProduction', true);
            tc.verifyNumElements(poster.Calls, 1);
        end

        function realRunAcceptsLocalhostUrls(tc)
            urls = {'http://localhost:8000/upload.php', 'http://localhost/upload.php', ...
                'http://localhost', 'http://127.0.0.1:8000/upload.php', ...
                'http://127.0.0.1/upload.php', 'https://localhost/upload.php'};
            for ii = 1:numel(urls)
                cfg = tc.configWithUrl(urls{ii});
                poster = simulate.FakePoster();
                args = {'ConfigFile', cfg, 'NumSections', 1, 'Interval', 5, 'Poster', @poster.post, ...
                    'WorkDir', fullfile(tc.Dir, sprintf('wl%d', ii)), 'RecipeFile', tc.Recipe, ...
                    'Verbose', false};
                simulate.simulateAcquisition(args{:});
                tc.verifyNumElements(poster.Calls, 1, urls{ii});
            end
        end

        function realRunRefusesLocalhostLookAlikeUrls(tc)
            % https look-alikes pass webupload.webConfig, so the target check itself must refuse them.
            urls = {'https://localhost@evil.example/upload.php', ...
                'https://localhost.evil.com/upload.php', ...
                'https://127.0.0.1.evil.com/upload.php', ...
                'https://x.example/localhost', ...
                'https://x.example/upload.php?h=http://localhost/', ...
                'https://x.example/test-upload/upload.php', ...
                'https://prod.example/upload.php?x=testserver', ...
                'https://testserver.example/upload.php', ...
                'https://x.example/testserver2/upload.php', ...
                'https://prod.example/testserver/../upload.php'};
            for ii = 1:numel(urls)
                cfg = tc.configWithUrl(urls{ii});
                poster = simulate.FakePoster();
                args = {'ConfigFile', cfg, 'NumSections', 1, 'Interval', 5, 'Poster', @poster.post, ...
                    'WorkDir', fullfile(tc.Dir, sprintf('wm%d', ii)), 'RecipeFile', tc.Recipe, ...
                    'Verbose', false};
                tc.verifyError(@() simulate.simulateAcquisition(args{:}), ...
                    'simulate:simulateAcquisition:productionUrl', urls{ii});
                tc.verifyEmpty(poster.Calls);
            end
        end

        function plainHttpLookAlikesAreRefusedByTheConfigLoader(tc)
            urls = {'http://localhost@evil.example/', 'http://localhost.evil.com/', ...
                'http://127.0.0.1.evil.com/'};
            for ii = 1:numel(urls)
                cfg = tc.configWithUrl(urls{ii});
                tc.verifyError(@() simulate.simulateAcquisition('ConfigFile', cfg, ...
                    'NumSections', 1, 'Poster', @(~, ~, ~, ~) struct(), 'RecipeFile', tc.Recipe, ...
                    'WorkDir', fullfile(tc.Dir, sprintf('wn%d', ii)), 'Verbose', false), ...
                    'webupload:insecureUrl', urls{ii});
            end
        end

        % ---- validation ----
        function numSectionsMustBePositiveInteger(tc)
            for bad = {0, -2, 2.5, NaN, Inf}
                tc.verifyError(@() tc.dry('NumSections', bad{1}), ...
                    'simulate:simulateAcquisition:badNumSections');
            end
        end

        function intervalMustBeNonNegative(tc)
            tc.verifyError(@() tc.dry('Interval', -1), 'simulate:simulateAcquisition:badInterval');
        end

        function logTimeScaleMustBePositive(tc)
            tc.verifyError(@() tc.dry('LogTimeScale', 0), 'simulate:simulateAcquisition:badLogTimeScale');
        end

        function posterWithDryRunIsRejected(tc)
            tc.verifyError(@() tc.dry('Poster', @(~, ~, ~, ~) struct()), ...
                'simulate:simulateAcquisition:posterInDryRun');
        end

        function missingRecipeErrors(tc)
            tc.verifyError(@() tc.dry('RecipeFile', fullfile(tc.Dir, 'nope.yml')), ...
                'simulate:simulateAcquisition:noRecipe');
        end
    end

    methods
        function reply = statusPoster(tc, ~, ~, ~, ~)
            % Scripted poster: replies with tc.PosterStatus as a failure.
            tc.PosterCalls = tc.PosterCalls + 1;
            reply = struct('ok', false, 'httpStatus', tc.PosterStatus, 'message', 'scripted failure');
        end

        function reply = markerPoster(tc, folder, ~, ~, ~)
            % Records whether the stale file and its own earlier marker are
            % in the stage folder, then leaves a marker for the next call.
            marker = fullfile(folder, 'marker.txt');
            tc.StageSeen(end+1, :) = [isfile(fullfile(folder, 'stale.txt')), isfile(marker)];
            writeText(marker, 'm');
            reply = struct('ok', true, 'httpStatus', 200, 'message', 'ok');
        end
    end

    methods (Access = private)
        function cfg = configWithUrl(tc, url)
            % Write a config file whose url is the one given; return its path.
            cfg = tempname(tc.Dir);
            writeText(cfg, sprintf('{"url":"%s","siteID":"sim-1","token":"TOK"}', url));
        end

        function r = dry(tc, varargin)
            % Dry run with a synthetic recipe, no waiting and no output; options override.
            o = struct('DryRun', true, 'Interval', 0, 'NumSections', 3, ...
                'RecipeFile', tc.Recipe, 'WorkDir', fullfile(tc.Dir, 'work'), 'Verbose', false);
            for ii = 1:2:numel(varargin)
                o.(varargin{ii}) = varargin{ii+1};
            end
            args = namedargs2cell(o);
            r = simulate.simulateAcquisition(args{:});
        end

        function r = runReal(tc, poster, varargin)
            % Real mode with a scripted poster and the canary config. Interval 0
            % keeps the test fast, so the (expected) rate-limit warning and the
            % per-failure warnings of updateSectionImage are silenced here.
            saved = warning('off', 'simulate:simulateAcquisition:fastInterval');
            saved2 = warning('off', 'webpreview:updateSectionImage:failed');
            restore = onCleanup(@() warning([saved; saved2]));
            o = struct('ConfigFile', tc.Config, 'Interval', 0, 'Poster', poster, ...
                'WorkDir', fullfile(tc.Dir, 'wreal'), 'RecipeFile', tc.Recipe, 'Verbose', false);
            for ii = 1:2:numel(varargin)
                o.(varargin{ii}) = varargin{ii+1};
            end
            args = namedargs2cell(o);
            r = simulate.simulateAcquisition(args{:});
        end

        function r = verifyWarningFreeCall(tc, fn)
            % Run fn, fail if it warns, return its output.
            saved = warning('on', 'all');
            restore = onCleanup(@() warning(saved));
            lastwarn('');
            r = fn();
            [msg, id] = lastwarn;
            tc.verifyEmpty(id, ['unexpected warning: ' msg]);
        end
    end
end


function [startRe, finishRe] = serverRegexes()
% Copies of the patterns bs_parse_acqlogs() uses in brainsaw/lib.php (PCRE \/
% and \d are valid MATLAB regexp as is). serverRegexCopyMatchesLibPhp checks
% them against the server source.
startRe = '^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) -- STARTING section number (\d+) \((\d+) of (\d+)\)';
finishRe = '^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) -- FINISHED section number (\d+), section completed in (\d+) mins? (\d+) secs?';
end


function t = stampOf(line, re, fmt)
tok = regexp(line, re, 'tokens', 'once');
t = datetime(tok{1}, 'InputFormat', fmt);
end


function writeText(file, text)
fid = fopen(file, 'w');
fwrite(fid, text);
fclose(fid);
end
