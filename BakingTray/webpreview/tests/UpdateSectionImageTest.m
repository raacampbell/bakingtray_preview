classdef UpdateSectionImageTest < matlab.unittest.TestCase
    % Tests for webpreview.updateSectionImage with an injected fake Poster, so
    % nothing touches the network (except one test against a refused localhost
    % port). All inputs are synthetic temp files.
    % Run: runtests(fullfile(<repo>, 'BakingTray', 'webpreview', 'tests'))

    properties
        Dir          % scratch root, removed after each test
        StageRoot    % stage root handed to the function (never the real tempdir)
        Cfg          % webpreview.webConfig handed to the functions under test
        Recipe
        Log
        Token = 'SECRETTOKEN123'
        Calls        % struct array: folder, cfg, names (files present at call time)
        PosterReply  % what the fake poster returns
        PosterError  % if non-empty, the fake poster throws this message
        Out          % result of the function under test, stored by the closure
        WarnMsg      % message of the last warning issued during the call
        WarnId       % its identifier
    end

    properties (Dependent)
        BaseArgs     % name-value cell used by most calls (a property so tc.BaseArgs{:} is legal)
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
            tc.StageRoot = fullfile(tc.Dir, 'stageroot');
            tc.Cfg = tc.makeCfg('https://x.example/up.php');
            tc.Recipe = fullfile(tc.Dir, 'recipe_A.yml');
            tc.Log = fullfile(tc.Dir, 'acqLog_A.txt');
            writeText(tc.Recipe, 'sample: A');
            writeText(tc.Log, 'section 1');
            tc.Calls = struct('folder', {}, 'cfg', {}, 'names', {});
            tc.PosterReply = struct('ok', true, 'httpStatus', 200, 'message', 'uploaded');
            tc.PosterError = '';
            tc.Out = [];
            tc.WarnMsg = '';
            tc.WarnId = '';
        end
    end

    methods
        function cfg = makeCfg(tc, url)
            f = fullfile(tc.Dir, 'config.json');
            writeText(f, sprintf( ...
                '{"url":"%s","siteID":"site-1","micID":"mic-1","token":"%s"}', url, tc.Token));
            cfg = webpreview.webConfig(f);
        end

        function reply = recordingPoster(tc, folder, cfg)
            % Same signature as webpreview.zipAndPost; records what it saw.
            d = dir(folder);
            tc.Calls(end+1) = struct('folder', folder, 'cfg', cfg, ...
                'names', {sort({d(~[d.isdir]).name})});
            if ~isempty(tc.PosterError)
                error('fake:boom', '%s', tc.PosterError);
            end
            reply = tc.PosterReply;
        end

        function args = get.BaseArgs(tc)
            args = {'StageRoot', tc.StageRoot, 'Poster', @tc.recordingPoster};
        end

        function res = update(tc, varargin)
            % Run with the fake poster; store result and the warning issued.
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, tc.Cfg, tc.BaseArgs{:}, varargin{:}));
            res = tc.Out;
        end

        function callCapturing(tc, fn)
            % Closure capture: the function's output goes to tc.Out and the
            % warning it issued to tc.WarnId/WarnMsg. Warnings are turned on
            % explicitly so lastwarn is set, and the state is restored.
            saved = warning('on', 'all');
            restore = onCleanup(@() warning(saved));
            lastwarn('');
            tc.Out = fn();
            [tc.WarnMsg, tc.WarnId] = lastwarn;
        end

        function turnIntoErrors(tc, id)
            % Make the warning with this id throw for the rest of the test.
            saved = warning('error', id);
            tc.addTeardown(@warning, saved);
        end

        function verifyFailedWarning(tc)
            tc.verifyEqual(tc.WarnId, 'webpreview:updateSectionImage:failed');
        end
    end

    methods (Test)
        function happyPathStagesAndPostsOnce(tc)
            res = tc.update();
            tc.verifyTrue(res.ok);
            tc.verifyEmpty(res.error);
            tc.verifyEmpty(tc.WarnId, 'no warning expected on success');
            tc.verifyTrue(res.recipeFresh && res.logFresh);
            tc.verifyFalse(res.stale);
            tc.verifyEqual(res.post.httpStatus, 200);
            tc.verifyNumElements(tc.Calls, 1);
            tc.verifyEqual(tc.Calls.folder, res.stageDir);
            tc.verifyEqual(tc.Calls.names, ...
                {'LastCompleteSection.jpg', 'acqLog.txt', 'recipe.yml'});
            tc.verifyEqual(tc.Calls.cfg.siteID, 'site-1');
            tc.verifyEqual(res.stageDir, fullfile(tc.StageRoot, 'brainsaw_webpreview', 'site-1', 'mic-1'));
        end

        function montageIsStaged(tc)
            tc.update('Montage', uint8(magic(8)));
            tc.verifyTrue(ismember('montage.jpg', tc.Calls.names));
        end

        function rangeIsForwardedToConversion(tc)
            % A double image above 1 is an error without Range, so success
            % proves Range reached toUint8; 2048 of [0 4095] is 128.
            img = 2048 * ones(16);
            tc.callCapturing(@() webpreview.updateSectionImage(img, tc.Recipe, tc.Log, tc.Cfg, ...
                tc.BaseArgs{:}, 'Range', [0 4095]));
            tc.verifyTrue(tc.Out.ok);
            px = imread(fullfile(tc.Out.stageDir, 'LastCompleteSection.jpg'));
            tc.verifyEqual(double(px), 128 * ones(16), 'AbsTol', 2);
        end

        function errorFieldIsPopulatedOnFailure(tc)
            tc.PosterError = 'kaboom';
            res = tc.update();
            tc.verifyClass(res.error, 'MException');
            tc.verifyEqual(res.error.identifier, 'fake:boom');
            tc.verifySubstring(res.error.message, 'kaboom');
            tc.verifySubstring(tc.WarnMsg, 'fake:boom: kaboom');
        end

        function posterFailureIsNonFatal(tc)
            tc.PosterReply = struct('ok', false, 'httpStatus', 500, 'message', 'server said no');
            res = tc.update();
            tc.verifyFalse(res.ok);
            tc.verifyFailedWarning();
            tc.verifyEqual(res.post.httpStatus, 500);
            tc.verifySubstring(res.post.message, 'server said no');
            tc.verifyNotEmpty(res.error);
        end

        function posterThrowingIsNonFatal(tc)
            tc.PosterError = 'kaboom';
            res = tc.update();
            tc.verifyFalse(res.ok);
            tc.verifyFailedWarning();
            tc.verifySubstring(res.post.message, 'kaboom');
            tc.verifyNotEmpty(res.stage, 'stage info survives a poster failure');
        end

        function malformedPosterReplyIsNonFatal(tc)
            tc.PosterReply = 42;
            res = tc.update();
            tc.verifyFalse(res.ok);
            tc.verifyFailedWarning();
            tc.PosterReply = struct('ok', true, 'httpStatus', 200, 'message', 5);
            res = tc.update();
            tc.verifyFalse(res.ok, 'non-char message is a failure');
        end

        function nonConfigCfgIsNonFatal(tc)
            for bad = {[], 'cfg.json', struct('url', 'https://x'), [tc.Cfg tc.Cfg]}
                tc.callCapturing(@() webpreview.updateSectionImage( ...
                    uint8(magic(8)), tc.Recipe, tc.Log, bad{1}, tc.BaseArgs{:}));
                tc.verifyFalse(tc.Out.ok);
                tc.verifyFailedWarning();
                tc.verifySubstring(tc.WarnMsg, 'webpreview:updateSectionImage:badConfig');
            end
            tc.verifyEmpty(tc.Calls);
        end

        function deletedCfgIsNonFatal(tc)
            cfg = tc.makeCfg('https://x.example/up.php');
            delete(cfg)
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, cfg, tc.BaseArgs{:}));
            tc.verifyFalse(tc.Out.ok);
            tc.verifyFailedWarning();
        end

        function badImageIsNonFatal(tc)
            tc.callCapturing(@() webpreview.updateSectionImage(uint8(1), tc.Recipe, tc.Log, ...
                tc.Cfg, tc.BaseArgs{:}));
            tc.verifyFalse(tc.Out.ok);
            tc.verifyFailedWarning();
            tc.verifyEmpty(tc.Calls);
        end

        function argumentShapeErrorIsNonFatal(tc)
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, tc.Cfg, 'Bogus', 1));
            tc.verifyFalse(tc.Out.ok);
            tc.verifyFailedWarning();
        end

        function stageFailureIsNonFatalAndNotPosted(tc)
            % A regular file where the stage root should be: mkdir must fail.
            blocker = fullfile(tc.Dir, 'blocker');
            writeText(blocker, 'x');
            tc.StageRoot = blocker;
            res = tc.update();
            tc.verifyFalse(res.ok);
            tc.verifyFailedWarning();
            tc.verifySubstring(res.post.message, 'did not complete');
            tc.verifyEmpty(tc.Calls);
            tc.verifyEqual(res.error.identifier, 'webpreview:updateSectionImage:stageFailed');
        end

        function missingRecipeAndLogAreReportedAsStale(tc)
            tc.update();                                  % a good first section
            tc.Recipe = fullfile(tc.Dir, 'no_such_recipe.yml');
            res = tc.update();
            tc.verifyTrue(res.ok);
            tc.verifyFalse(res.recipeFresh);
            tc.verifyTrue(res.logFresh);
            tc.verifyTrue(res.stale);
            tc.verifyEqual(tc.WarnId, 'webpreview:updateSectionImage:stale');
            tc.verifySubstring(tc.WarnMsg, 'recipe');
            tc.verifySubstring(tc.WarnMsg, 'previously staged copy');
            tc.verifyTrue(ismember('recipe.yml', tc.Calls(2).names), ...
                'previous recipe is what was uploaded');

            tc.Log = fullfile(tc.Dir, 'no_such_log.txt');
            res = tc.update();
            tc.verifyFalse(res.logFresh);
            tc.verifySubstring(tc.WarnMsg, 'recipe and acq log');
        end

        function staleAndFailureGiveOneFailedWarningNamingTheFile(tc)
            tc.Recipe = fullfile(tc.Dir, 'no_such_recipe.yml');
            tc.PosterError = 'kaboom';
            tc.update();
            tc.verifyFailedWarning();
            tc.verifySubstring(tc.WarnMsg, 'recipe not refreshed');
        end

        function clearStageRemovesPreviousMetadata(tc)
            tc.update();
            tc.Recipe = fullfile(tc.Dir, 'no_such_recipe.yml');
            res = tc.update('ClearStage', true);
            tc.verifyTrue(res.ok);
            tc.verifyFalse(ismember('recipe.yml', tc.Calls(2).names));
            tc.verifyTrue(ismember('acqLog.txt', tc.Calls(2).names));
        end

        function repeatedCallsReuseStageWithoutStaleFiles(tc)
            first = tc.update('Montage', uint8(magic(8)));
            tc.verifyTrue(ismember('montage.jpg', tc.Calls(1).names));
            recipeB = fullfile(tc.Dir, 'recipe_B.yaml');
            writeText(recipeB, 'sample: B');
            tc.Recipe = recipeB;
            second = tc.update();               % no montage, different recipe name
            tc.verifyEqual(second.stageDir, first.stageDir);
            tc.verifyEqual(tc.Calls(2).names, ...
                {'LastCompleteSection.jpg', 'acqLog.txt', 'recipe.yaml'});
        end

        function tokenNeverAppearsInMessages(tc)
            % Poster throws with the token in its message.
            tc.PosterError = ['failed with ' tc.Token];
            res = tc.update();
            tc.verifyFailedWarning();
            tc.verifyThat(res.post.message, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
            tc.verifyThat(tc.WarnMsg, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
            tc.verifyThat(res.error.message, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
            % Poster replies with a failure message containing the token.
            tc.PosterError = '';
            tc.PosterReply = struct('ok', false, 'httpStatus', 401, 'message', ['bad ' tc.Token]);
            res = tc.update();
            tc.verifyFailedWarning();
            tc.verifyThat(res.post.message, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
            tc.verifyThat(tc.WarnMsg, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
        end

        function clearStageOptionOnlyTouchesTheManagedFolder(tc)
            tc.update();                                   % creates the managed folder
            managed = webpreview.stageDirFor('site-1', 'mic-1', tc.StageRoot);
            sibling = webpreview.stageDirFor('other', 'mic-1', tc.StageRoot);
            mkdir(sibling);
            writeText(fullfile(sibling, 'keep.txt'), 'x');
            writeText(fullfile(tc.StageRoot, 'keep.txt'), 'x');
            tc.update('ClearStage', true);
            tc.verifyTrue(isfile(fullfile(sibling, 'keep.txt')));
            tc.verifyTrue(isfile(fullfile(tc.StageRoot, 'keep.txt')));
            tc.verifyEqual(tc.Out.stageDir, managed);
        end

        function stageDirIsCharEvenForStringOptions(tc)
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, tc.Cfg, ...
                'StageRoot', string(tc.StageRoot), 'Poster', @tc.recordingPoster));
            tc.verifyClass(tc.Out.stageDir, 'char');
            tc.verifyTrue(tc.Out.ok);
        end

        function okMessageIsScrubbedToo(tc)
            tc.PosterReply = struct('ok', true, 'httpStatus', 200, 'message', ['ok ' tc.Token]);
            res = tc.update();
            tc.verifyTrue(res.ok);
            tc.verifyThat(res.post.message, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
        end

        function errorWithoutIdentifierDoesNotThrow(tc)
            % A plain error('text') has an empty identifier. MATLAB will not build an
            % error with a malformed one, so this is the nearest case that can be tested.
            % error() cannot output a value, so the poster must be a real function.
            poster = @throwWithoutId;
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, tc.Cfg, ...
                'StageRoot', tc.StageRoot, 'Poster', poster));
            tc.verifyFalse(tc.Out.ok);
            tc.verifySubstring(tc.Out.post.message, 'plain failure');
        end

        % ---- clearStage ----
        function clearStageRemovesOnlyTheManagedFolder(tc)
            tc.update();
            managed = webpreview.stageDirFor('site-1', 'mic-1', tc.StageRoot);
            sibling = webpreview.stageDirFor('other', 'mic-1', tc.StageRoot);
            mkdir(sibling);
            writeText(fullfile(sibling, 'keep.txt'), 'x');
            writeText(fullfile(tc.StageRoot, 'keep.txt'), 'x');
            ok = webpreview.clearStage(tc.Cfg, 'StageRoot', tc.StageRoot);
            tc.verifyTrue(ok);
            tc.verifyFalse(isfolder(managed));
            tc.verifyTrue(isfile(fullfile(sibling, 'keep.txt')));
            tc.verifyTrue(isfile(fullfile(tc.StageRoot, 'keep.txt')));
            tc.verifyNumElements(tc.Calls, 1, 'clearStage must not upload');
        end

        function clearStageOnAbsentFolderIsOk(tc)
            tc.verifyTrue(webpreview.clearStage(tc.Cfg, 'StageRoot', tc.StageRoot));
        end

        function clearStageWithNonConfigWarnsAndReturnsFalse(tc)
            for bad = {[], 'cfg.json', struct('siteID', 'site-1'), [tc.Cfg tc.Cfg]}
                tc.callCapturing(@() webpreview.clearStage(bad{1}, 'StageRoot', tc.StageRoot));
                tc.verifyFalse(tc.Out);
                tc.verifyEqual(tc.WarnId, 'webpreview:clearStage:failed');
                tc.verifySubstring(tc.WarnMsg, 'webpreview:clearStage:badConfig');
            end
        end

        function clearStageNeverThrowsEvenForBadArguments(tc)
            % warning('error','all') is not allowed in MATLAB, so name the ids.
            tc.turnIntoErrors('webpreview:clearStage:failed');
            tc.verifyFalse(webpreview.clearStage(tc.Cfg, 'Bogus', 1));
            tc.verifyFalse(webpreview.clearStage([]));
        end

        function warningsAsErrorsDoNotMakeItThrow(tc)
            tc.turnIntoErrors('webpreview:updateSectionImage:failed');
            res = webpreview.updateSectionImage(uint8(1), tc.Recipe, tc.Log, tc.Cfg, ...
                tc.BaseArgs{:});
            tc.verifyFalse(res.ok);
        end

        function defaultPosterOnUnreachableServerIsNonFatal(tc)
            % Port 9 on localhost refuses the connection; plain http is
            % accepted by webConfig for localhost only.
            tc.Cfg = tc.makeCfg('http://127.0.0.1:9/up.php');
            tc.callCapturing(@() webpreview.updateSectionImage( ...
                uint8(magic(8)), tc.Recipe, tc.Log, tc.Cfg, 'StageRoot', tc.StageRoot));
            tc.verifyFalse(tc.Out.ok);
            tc.verifyFailedWarning();
            tc.verifyThat(tc.WarnMsg, ~matlab.unittest.constraints.ContainsSubstring(tc.Token));
        end
    end
end


function reply = throwWithoutId(~, ~)
reply = [];
error('plain failure');
end


function writeText(file, txt)
fid = fopen(file, 'w');
assert(fid > 0, 'could not open "%s" for writing', file);
fwrite(fid, txt);
fclose(fid);
end
