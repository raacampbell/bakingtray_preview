classdef StageFilesTest < matlab.unittest.TestCase
    % Tests for BakingTray.webpreview.stageFiles, toUint8, globToRegexp and stageSpec.
    % Run: runtests('StageFilesTest'). All inputs are synthetic temp files; the
    % package folder is put on the path by a fixture so tests run from anywhere.

    properties
        Dir      % scratch root, removed after each test
        Stage
        Recipe
        Log
        Last     % result of the most recent stageOut/stageTo call
        Globs    % server globs, from stageSpec (checked against lib.php below)
    end

    methods (TestClassSetup)
        function addPackageToPath(tc)
            root = fileparts(fileparts(mfilename('fullpath')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(root));
        end
    end

    methods (TestMethodSetup)
        function makeFixtures(tc)
            tc.Dir = tempname;
            mkdir(tc.Dir);
            tc.addTeardown(@() rmdir(tc.Dir, 's'));
            tc.Stage = fullfile(tc.Dir, 'stage');
            tc.Recipe = fullfile(tc.Dir, 'recipe_SAMPLE_191209.yml');
            tc.Log = fullfile(tc.Dir, 'acqLog_SAMPLE.txt');
            writeText(tc.Recipe, sprintf('sample:\n  ID: SAMPLE\n'));
            writeText(tc.Log, sprintf('section 1 done\n'));
            spec = BakingTray.webpreview.stageSpec();
            tc.Globs = spec.Globs;
        end
    end

    methods (Test)
        % ---- stageSpec vs the server ----
        function specGlobsMatchServerSource(tc)
            % tests/ -> BakingTray/ -> repo root
            here = fileparts(mfilename('fullpath'));
            repo = fileparts(fileparts(here));
            lib = fullfile(repo, 'brainsaw', 'lib.php');
            tc.verifyTrue(isfile(lib), ['server source not found at ' lib]);
            txt = fileread(lib);
            % Images are found through BS_ASSETS, the recipe and logs by direct glob calls.
            tok = [regexp(txt, '''(?:main|montage)'' => \[''([^'']+)''', 'tokens'), ...
                   regexp(txt, 'bs_find_(?:latest|all)\(\$micDir, ''([^'']+)''\)', 'tokens')];
            found = cellfun(@(t) t{1}, tok, 'UniformOutput', false);
            expected = {tc.Globs.Main, tc.Globs.Montage, tc.Globs.Recipe, tc.Globs.Log};
            tc.verifyEqual(found, expected);
        end

        % ---- toUint8 (pure, no JPEG) ----
        function toUint8RoundsFloatHalfUp(tc)
            tc.verifyEqual(BakingTray.webpreview.toUint8(0.5 * ones(2)), uint8(128 * ones(2)));
        end

        function toUint8Uint8IsIdentity(tc)
            img = uint8([0 1 127 255; 3 4 5 6]);
            tc.verifyEqual(BakingTray.webpreview.toUint8(img), img);
        end

        function toUint8Uint16AutoscalesToMax(tc)
            out = BakingTray.webpreview.toUint8(uint16([0 1000; 2000 2000]));
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8Uint16AllZeroIsBlack(tc)
            tc.verifyEqual(BakingTray.webpreview.toUint8(zeros(3, 3, 'uint16')), zeros(3, 3, 'uint8'));
        end

        function toUint8Uint16ExplicitFullRangeKeepsAbsoluteScale(tc)
            out = BakingTray.webpreview.toUint8(uint16([0 2047; 2047 2047]), [0 65535]);
            tc.verifyLessThan(double(out(1,2)), 10);
        end

        function toUint8Int16ClampsNegativesAndAutoscales(tc)
            out = BakingTray.webpreview.toUint8(int16([-5 0; 100 200]));
            tc.verifyEqual(out, uint8([0 0; 128 255]));
        end

        function toUint8RangeScalesAndClamps(tc)
            out = BakingTray.webpreview.toUint8([-1 5; 10 20], [0 10]);
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8IntegerClassRangeIsUsedAsDouble(tc)
            out = BakingTray.webpreview.toUint8(uint16([0 2048; 4095 4095]), uint16([0 4095]));
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8NegativeLoRange(tc)
            out = BakingTray.webpreview.toUint8(int16([-100 0; 100 300]), int16([-100 300]));
            tc.verifyEqual(out, uint8([0 64; 128 255]));
        end

        function toUint8SingleAccepted(tc)
            tc.verifyEqual(BakingTray.webpreview.toUint8(0.5 * ones(2, 'single')), uint8(128 * ones(2)));
        end

        function toUint8BadRangeErrors(tc)
            img = uint8(ones(4));
            tc.verifyError(@() BakingTray.webpreview.toUint8(img, [5 1]), 'webpreview:toUint8:badRange');
            tc.verifyError(@() BakingTray.webpreview.toUint8(img, [1 NaN]), 'webpreview:toUint8:badRange');
            tc.verifyError(@() BakingTray.webpreview.toUint8(img, [1 2 3]), 'webpreview:toUint8:badRange');
        end

        function toUint8FloatOutOfRangeErrorsWithoutRange(tc)
            tc.verifyError(@() BakingTray.webpreview.toUint8(2 * ones(4)), 'webpreview:toUint8:badImage');
        end

        function toUint8NanAndInfError(tc)
            bad = ones(4); bad(3) = NaN;
            tc.verifyError(@() BakingTray.webpreview.toUint8(bad), 'webpreview:toUint8:badImage');
            tc.verifyError(@() BakingTray.webpreview.toUint8(bad, [0 1]), 'webpreview:toUint8:badImage');
            bad(3) = Inf;
            tc.verifyError(@() BakingTray.webpreview.toUint8(bad), 'webpreview:toUint8:badImage');
        end

        function toUint8UnsupportedClassErrors(tc)
            tc.verifyError(@() BakingTray.webpreview.toUint8(int32(ones(4))), 'webpreview:toUint8:badImage');
        end

        function toUint8BadDimsError(tc)
            tc.verifyError(@() BakingTray.webpreview.toUint8(uint8(ones(4,4,3,2))), 'webpreview:toUint8:badImage');
            tc.verifyError(@() BakingTray.webpreview.toUint8(uint8(ones(4,4,2))), 'webpreview:toUint8:badImage');
            tc.verifyError(@() BakingTray.webpreview.toUint8(uint8([])), 'webpreview:toUint8:badImage');
            tc.verifyError(@() BakingTray.webpreview.toUint8(uint8(1:10)), 'webpreview:toUint8:badImage');
            tc.verifyError(@() BakingTray.webpreview.toUint8(uint8((1:10)')), 'webpreview:toUint8:badImage');
        end

        % ---- globToRegexp ----
        function globEscapesDots(tc)
            rx = BakingTray.webpreview.globToRegexp('*.jpg');
            tc.verifyTrue(globHit(rx, 'a.jpg'));
            tc.verifyFalse(globHit(rx, 'ajpg'));
        end

        function globBracketClass(tc)
            rx = BakingTray.webpreview.globToRegexp('[Mm]ontage*');
            tc.verifyTrue(globHit(rx, 'montage1'));
            tc.verifyTrue(globHit(rx, 'Montage'));
            tc.verifyFalse(globHit(rx, 'xontage'));
        end

        function globIsCaseSensitive(tc)
            tc.verifyFalse(globHit(BakingTray.webpreview.globToRegexp('*ecipe*'), 'RECIPE.yml'));
        end

        function globQuestionMarkIsOneChar(tc)
            rx = BakingTray.webpreview.globToRegexp('a?c');
            tc.verifyTrue(globHit(rx, 'abc'));
            tc.verifyFalse(globHit(rx, 'ac'));
            tc.verifyFalse(globHit(rx, 'abbc'));
        end

        function globWildcardDoesNotMatchLeadingDot(tc)
            tc.verifyFalse(globHit(BakingTray.webpreview.globToRegexp('*ecipe*.yml'), '._recipe.yml'));
            tc.verifyFalse(globHit(BakingTray.webpreview.globToRegexp('*'), '.hidden'));
            tc.verifyTrue(globHit(BakingTray.webpreview.globToRegexp('a*'), 'a.b'));
        end

        function globUnterminatedBracketErrors(tc)
            tc.verifyError(@() BakingTray.webpreview.globToRegexp('a[bc'), 'webpreview:globToRegexp:unterminated');
        end

        % ---- stageFiles: image content ----
        function uint8RgbRoundTrips(tc)
            img = repmat(reshape(uint8([200 100 50]), 1, 1, 3), 16, 16);
            tc.stage(img);
            out = tc.readMain();
            tc.verifySize(out, [16 16 3]);
            tc.verifyEqual(double(squeeze(out(8,8,:)))', [200 100 50], 'AbsTol', 6);
        end

        function uint16GrayIsAutoscaledInJpeg(tc)
            tc.stage(repmat(uint16(2047), 16, 16));
            out = tc.readMain();
            tc.verifyClass(out, 'uint8');
            tc.verifyGreaterThan(double(out(8,8)), 250);
        end

        function uint16RgbWorks(tc)
            img = repmat(reshape(uint16([65535 0 32768]), 1, 1, 3), 16, 16);
            tc.stage(img);
            out = tc.readMain();
            tc.verifySize(out, [16 16 3]);
            tc.verifyGreaterThan(double(out(8,8,1)), 240);
            tc.verifyLessThan(double(out(8,8,2)), 15);
        end

        function doubleZeroToOneIsScaled(tc)
            tc.stage(0.5 * ones(16, 16));
            out = tc.readMain();
            tc.verifyEqual(double(out(8,8)), 128, 'AbsTol', 4);
        end

        function badImageThrowsAndLeavesOldStageIntact(tc)
            tc.stage(uint8(ones(8)));
            before = fileread(fullfile(tc.Stage, 'recipe.yml'));
            tc.verifyError(@() tc.stage(2*ones(8)), 'webpreview:toUint8:badImage');
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
            tc.verifyEqual(fileread(fullfile(tc.Stage, 'recipe.yml')), before);
        end

        function badRangeThrowsFromStageFiles(tc)
            tc.verifyError(@() tc.stage(uint8(ones(8)), 'Range', [5 1]), 'webpreview:toUint8:badRange');
        end

        % ---- stageFiles: file naming ----
        function filesMatchServerGlobs(tc)
            tc.stage(uint8(ones(8)), 'Montage', uint8(ones(8)));
            names = tc.stagedNames();
            tc.verifyEqual(sum(matchesGlob(names, tc.Globs.Main)), 1);
            tc.verifyEqual(sum(matchesGlob(names, tc.Globs.Montage)), 1);
            tc.verifyEqual(sum(matchesGlob(names, tc.Globs.Recipe)), 1);
            tc.verifyEqual(sum(matchesGlob(names, tc.Globs.Log)), 1);
            tc.verifyEqual(numel(names), 4);   % no leftover .part files
        end

        function mainImageDoesNotMatchMontageGlob(tc)
            tc.stage(uint8(ones(8)));
            tc.verifyFalse(any(matchesGlob(tc.stagedNames(), tc.Globs.Montage)));
        end

        function yamlRecipeKeepsYamlExtensionAndMatches(tc)
            r = fullfile(tc.Dir, 'my_recipe.yaml');
            writeText(r, 'x');
            tc.stage(uint8(ones(8)), r);
            tc.verifyEqual(sum(matchesGlob(tc.stagedNames(), tc.Globs.Recipe)), 1);
        end

        function montageIsOptional(tc)
            tc.stage(uint8(ones(8)));
            tc.verifyEmpty(dir(fullfile(tc.Stage, '*ontage*')));
        end

        function montageDroppedOnSecondCallIsCleared(tc)
            tc.stage(uint8(ones(8)), 'Montage', uint8(ones(8)));
            tc.stage(uint8(ones(8)));
            tc.verifyFalse(any(matchesGlob(tc.stagedNames(), tc.Globs.Montage)));
        end

        function appleDoubleFilesAreNeverTouched(tc)
            mkdir(tc.Stage);
            hidden = fullfile(tc.Stage, '._recipe.yml');
            writeText(hidden, 'appledouble');
            tc.stage(uint8(ones(8)));
            tc.verifyEqual(fileread(hidden), 'appledouble');
        end

        % ---- recipe / log handling ----
        function missingLogWarnsButStagesImage(tc)
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, ...
                fullfile(tc.Dir, 'nope.txt')), 'webpreview:stageFiles:missingLog');
            r = tc.Last;
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
            tc.verifyEmpty(dir(fullfile(tc.Stage, '*cqLog*.txt')));
            tc.verifyTrue(r.recipeStaged);
            tc.verifyFalse(r.logStaged);
        end

        function missingRecipeWarnsButStagesImage(tc)
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), ...
                fullfile(tc.Dir, 'nope.yml'), tc.Log), 'webpreview:stageFiles:missingRecipe');
            r = tc.Last;
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
            tc.verifyFalse(r.recipeStaged);
            tc.verifyTrue(r.logStaged);
        end

        function missingRecipeAndLogTogether(tc)
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), ...
                fullfile(tc.Dir, 'nope.yml'), fullfile(tc.Dir, 'nope.txt')), ...
                'webpreview:stageFiles:missingRecipe');
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
            tc.verifyTrue(tc.Last.stageOk);
        end

        function missingRecipeKeepsPreviousRecipe(tc)
            tc.stage(uint8(ones(8)));
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), ...
                fullfile(tc.Dir, 'typo.yml'), tc.Log), 'webpreview:stageFiles:missingRecipe');
            tc.verifyTrue(contains(fileread(fullfile(tc.Stage, 'recipe.yml')), 'SAMPLE'));
        end

        function nonTextSourcesWarnInsteadOfThrowing(tc)
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), [], tc.Log), ...
                'webpreview:stageFiles:missingRecipe');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, 42), ...
                'webpreview:stageFiles:missingLog');
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
        end

        function folderAsLogPathWarns(tc)
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Dir), ...
                'webpreview:stageFiles:missingLog');
        end

        function emptyRecipeFolderWarns(tc)
            d = fullfile(tc.Dir, 'empty');
            mkdir(d);
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), d, tc.Log), ...
                'webpreview:stageFiles:missingRecipe');
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
        end

        function recipeFolderUsesNewest(tc)
            d = fullfile(tc.Dir, 'recipes');
            mkdir(d);
            oldFile = fullfile(d, 'recipe_old.yml');
            writeText(oldFile, 'old');
            % Back-date the old file; where touch is unavailable fall back to
            % waiting out coarse (1 s) filesystem timestamp resolution.
            if ispc || system(sprintf('touch -t 200001010000 "%s"', oldFile)) ~= 0
                pause(1.1);
            end
            writeText(fullfile(d, 'recipe_new.yml'), 'new');
            r = tc.stageOut(uint8(ones(8)), d, tc.Log);
            tc.verifyEqual(strtrim(fileread(fullfile(tc.Stage, 'recipe.yml'))), 'new');
            tc.verifyEqual(r.recipeSource, fullfile(d, 'recipe_new.yml'));
        end

        function staleFilesAreReplaced(tc)
            tc.stage(uint8(ones(8)));
            % A stale file with another name that the server would also match.
            writeText(fullfile(tc.Stage, 'recipe_STALE.yml'), 'stale');
            recipe2 = fullfile(tc.Dir, 'recipe_OTHER.yml');
            writeText(recipe2, 'other');
            tc.stage(uint8(ones(8)), recipe2);
            f = dir(fullfile(tc.Stage, '*ecipe*.yml'));
            tc.verifyNumElements(f, 1);
            tc.verifyEqual(fileread(fullfile(f.folder, f.name)), 'other');
            tc.verifyNumElements(dir(fullfile(tc.Stage, '*.jpg')), 1);
        end

        function recipeInsideStageDirIsPreserved(tc)
            mkdir(tc.Stage);
            inStage = fullfile(tc.Stage, 'recipe.yml');
            writeText(inStage, 'live recipe');
            tc.stage(uint8(ones(8)), inStage);
            tc.verifyEqual(fileread(inStage), 'live recipe');
        end

        function recipeInsideStageDirUnderOtherNameIsNeverDeleted(tc)
            mkdir(tc.Stage);
            inStage = fullfile(tc.Stage, 'recipe_live.yml');
            writeText(inStage, 'live recipe');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), inStage, tc.Log), ...
                'webpreview:stageFiles:missingRecipe');
            tc.verifyEqual(fileread(inStage), 'live recipe');
        end

        function logInsideStageDirUnderOtherNameIsNeverDeleted(tc)
            mkdir(tc.Stage);
            inStage = fullfile(tc.Stage, 'acqLog_live.txt');
            writeText(inStage, 'live log');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, inStage), ...
                'webpreview:stageFiles:missingLog');
            tc.verifyEqual(fileread(inStage), 'live log');
        end

        function sourcesAreUnmodified(tc)
            before = {fileread(tc.Recipe), fileread(tc.Log)};
            infoBefore = {dir(tc.Recipe), dir(tc.Log)};
            tc.stage(uint8(ones(8)));
            tc.verifyEqual({fileread(tc.Recipe), fileread(tc.Log)}, before);
            tc.verifyEqual(dir(tc.Recipe).datenum, infoBefore{1}.datenum);
            tc.verifyEqual(dir(tc.Log).datenum, infoBefore{2}.datenum);
        end

        function resultReportsEverythingStaged(tc)
            r = tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Log, 'Montage', uint8(ones(8)));
            tc.verifyTrue(r.recipeStaged && r.logStaged && r.montageStaged && r.stageOk);
            tc.verifyNumElements(r.files, 4);
            tc.verifyTrue(all(cellfun(@isfile, r.files)));
        end

        % ---- file-system failures ----
        function unwritableStageDirWarnsAndReportsFailure(tc)
            underAFile = fullfile(tc.Recipe, 'sub');   % mkdir below a regular file fails
            tc.verifyWarning(@() tc.stageTo(underAFile, uint8(ones(8))), ...
                'webpreview:stageFiles:stageFailed');
            tc.verifyFalse(tc.Last.stageOk);
        end

        function copyFailureWarnsAndStillStagesImageAndRecipe(tc)
            tc.assumeFalse(ispc);
            % fileattrib cannot clear the read bit on Unix, so use chmod
            tc.assumeEqual(system(sprintf('chmod 000 "%s"', tc.Log)), 0);
            tc.addTeardown(@() system(sprintf('chmod 644 "%s"', tc.Log)));
            fid = fopen(tc.Log, 'r');
            if fid > 0, fclose(fid); end
            tc.assumeTrue(fid < 0, 'cannot make the log unreadable (running as root?)');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Log), ...
                'webpreview:stageFiles:copyFailed');
            tc.verifyTrue(tc.Last.recipeStaged);
            tc.verifyFalse(tc.Last.logStaged);
            tc.verifyTrue(isfile(fullfile(tc.Stage, 'LastCompleteSection.jpg')));
        end

        function readOnlyStageFailsCleanlyWithoutPartFiles(tc)
            tc.assumeFalse(ispc);
            tc.stage(uint8(ones(8)));
            fileattrib(tc.Stage, '-w', 'a');
            tc.addTeardown(@() fileattrib(tc.Stage, '+w', 'u'));
            probe = fopen(fullfile(tc.Stage, 'probe.tmp'), 'w');
            if probe > 0, fclose(probe); delete(fullfile(tc.Stage, 'probe.tmp')); end
            tc.assumeTrue(probe < 0, 'cannot make the stage read-only (running as root?)');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Log), ...
                'webpreview:stageFiles:stageFailed');
            tc.verifyFalse(tc.Last.stageOk);
            tc.verifyEmpty(dir(fullfile(tc.Stage, '*.part')));
        end

        % ---- path comparison ----
        function folderCaseDifferencesAreIgnoredOnCaseInsensitiveSystems(tc)
            tc.assumeTrue(ispc || ismac);
            real = fullfile(tc.Dir, 'StageCase');
            mkdir(real);
            tc.assumeTrue(isfolder(fullfile(tc.Dir, 'stagecase')), 'file system is case-sensitive');
            live = fullfile(real, 'recipe_live.yml');
            writeText(live, 'live recipe');
            tc.verifyWarning(@() BakingTray.webpreview.stageFiles(uint8(ones(8)), live, tc.Log, ...
                fullfile(tc.Dir, 'stagecase')), 'webpreview:stageFiles:missingRecipe');
            tc.verifyEqual(fileread(live), 'live recipe');
        end

        function sameFileDifferentCaseNameIsNotDeletedOnCaseInsensitiveSystems(tc)
            tc.assumeTrue(ispc || ismac);
            mkdir(tc.Stage);
            tc.assumeTrue(isfolder(fullfile(tc.Dir, 'STAGE')), 'file system is case-sensitive');
            % 'Recipe.yml' matches the server glob *ecipe*.y*ml, so it reaches the
            % stale-file logic; on these systems it is the same file as recipe.yml.
            caps = fullfile(tc.Stage, 'Recipe.yml');
            writeText(caps, 'live recipe');
            r = tc.stageOut(uint8(ones(8)), caps, tc.Log);
            tc.verifyTrue(r.recipeStaged);
            f = dir(fullfile(tc.Stage, '*.yml'));
            tc.verifyNumElements(f, 1);
            % The name on disk keeps the case of the file that was already there
            tc.verifyEqual(lower(f.name), 'recipe.yml');
            tc.verifyEqual(fileread(fullfile(f.folder, f.name)), 'live recipe');
        end

        function staleDifferentlyCasedLogIsRemoved(tc)
            % The server would parse both AcqLog.txt and acqLog.txt on a
            % case-sensitive file system, so only the staged name may remain. On a
            % case-insensitive one the two names are the same file, so there is nothing
            % to remove.
            mkdir(tc.Stage);
            tc.assumeFalse(isfolder(fullfile(tc.Dir, 'STAGE')), 'file system is case-insensitive');
            writeText(fullfile(tc.Stage, 'AcqLog.txt'), 'stale log');
            r = tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Log);
            tc.verifyTrue(r.logStaged);
            f = dir(fullfile(tc.Stage, '*cqLog*.txt'));
            tc.verifyEqual({f.name}, {'acqLog.txt'});
            tc.verifyEqual(fileread(fullfile(f.folder, f.name)), sprintf('section 1 done\n'));
        end

        function symlinkedStageDirIsRecognised(tc)
            tc.assumeFalse(ispc);
            tc.assumeTrue(usejava('jvm'), 'symlink resolution needs the JVM');
            real = fullfile(tc.Dir, 'realstage');
            mkdir(real);
            link = fullfile(tc.Dir, 'linkstage');
            tc.assumeEqual(system(sprintf('ln -s "%s" "%s"', real, link)), 0);
            live = fullfile(real, 'recipe_live.yml');
            writeText(live, 'live recipe');
            tc.verifyWarning(@() BakingTray.webpreview.stageFiles(uint8(ones(8)), live, tc.Log, link), ...
                'webpreview:stageFiles:missingRecipe');
            tc.verifyEqual(fileread(live), 'live recipe');
        end

        function undeletableStaleFileSetsStageFailed(tc)
            mkdir(tc.Stage);
            stale = fullfile(tc.Stage, 'recipe_STALE.yml');
            writeText(stale, 'stale');
            fileattrib(stale, '-w');
            tc.addTeardown(@() isfile(stale) && fileattrib(stale, '+w'));
            s = warning('off', 'all');
            delete(stale);
            warning(s);
            tc.assumeTrue(isfile(stale), 'this platform lets a read-only file be deleted');
            tc.verifyWarning(@() tc.stageOut(uint8(ones(8)), tc.Recipe, tc.Log), ...
                'webpreview:stageFiles:stageFailed');
            tc.verifyFalse(tc.Last.stageOk);
            tc.verifyTrue(tc.Last.recipeStaged);   % the new recipe is in place
        end

        function unrelatedPartFilesSurviveAndOwnAreRemoved(tc)
            mkdir(tc.Stage);
            other = fullfile(tc.Stage, 'other_tool.part');
            writeText(other, 'keep me');
            tc.stage(uint8(ones(8)));
            tc.verifyEqual(fileread(other), 'keep me');
            tc.verifyEqual(numel(dir(fullfile(tc.Stage, '*.part'))), 1);
        end
    end

    methods
        function stage(tc, img, varargin)
            % Stage with the fixture recipe/log unless a recipe path is given first.
            recipe = tc.Recipe;
            if ~isempty(varargin) && ischar(varargin{1}) && ~any(strcmp(varargin{1}, {'Montage', 'Range'}))
                recipe = varargin{1};
                varargin(1) = [];
            end
            BakingTray.webpreview.stageFiles(img, recipe, tc.Log, tc.Stage, varargin{:});
        end

        function r = stageOut(tc, img, recipe, log, varargin)
            r = BakingTray.webpreview.stageFiles(img, recipe, log, tc.Stage, varargin{:});
            tc.Last = r;
        end

        function stageTo(tc, stageDir, img)
            tc.Last = BakingTray.webpreview.stageFiles(img, tc.Recipe, tc.Log, stageDir);
        end

        function out = readMain(tc)
            out = imread(fullfile(tc.Stage, 'LastCompleteSection.jpg'));
        end

        function names = stagedNames(tc)
            d = dir(tc.Stage);
            names = {d(~[d.isdir]).name};
        end
    end
end

function tf = matchesGlob(names, glob)
% names: cellstr -> logical vector; char -> scalar.
tf = ~cellfun(@isempty, regexp(cellstr(names), BakingTray.webpreview.globToRegexp(glob), 'once'));
end

function tf = globHit(rx, name)
tf = ~isempty(regexp(name, rx, 'once'));
end

function writeText(path, txt)
fid = fopen(path, 'w');
assert(fid > 0, 'Could not open "%s" for writing.', path);
closer = onCleanup(@() fclose(fid));
fwrite(fid, txt);
end
