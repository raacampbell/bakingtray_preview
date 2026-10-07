classdef PostZipTest < matlab.unittest.TestCase
    % Tests for postZip, zipAndPost, interpretResponse and scrubToken.
    % The real upload path needs a live server and is not covered here.

    properties
        Dir
    end

    methods (TestClassSetup)
        function addPackageToPath(tc)
            tc.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(fileparts(mfilename('fullpath')), '..')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fx.Folder;
        end
    end

    methods (Test)
        function unreachableUrlReturnsNotOkWithoutThrowing(tc)
            zipPath = tc.makeZip();
            % Port 1 on localhost: connection refused immediately.
            res = webpreview.postZip(zipPath, PostZipTest.cfg());
            PostZipTest.verifyNetworkFailure(tc, res);
        end

        function zipAndPostFailureIsNonFatal(tc)
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            res = webpreview.zipAndPost(tc.Dir, PostZipTest.cfg());
            PostZipTest.verifyNetworkFailure(tc, res);
        end

        function zipAndPostReportsFolderProblemsWithoutThrowing(tc)
            res = webpreview.zipAndPost(tc.Dir, PostZipTest.cfg());   % no files
            tc.verifyFalse(res.ok);
            tc.verifyNotEmpty(res.message);
            res = webpreview.zipAndPost(fullfile(tc.Dir, 'nope'), PostZipTest.cfg());
            tc.verifyFalse(res.ok);
        end

        function zipAndPostSurvivesGarbageCfg(tc)
            % A recognised file makes zipFolder succeed, so postZip is reached.
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            for bad = {[], 'str', struct('url', 'https://x'), struct('url', 5, 'siteID', 1, 'token', 7)}
                res = webpreview.zipAndPost(tc.Dir, bad{1});
                tc.verifyFalse(res.ok);
                tc.verifyNotEmpty(res.message);
            end
        end

        function tokenInUrlIsScrubbedFromResults(tc)
            % checkUrl's error echoes the url, so the token reaches the
            % message unless the wiring scrubs it.
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            cfg = PostZipTest.cfg();
            cfg.url = ['http://example.org/', cfg.token];
            res1 = webpreview.postZip(tc.makeZip(), cfg);
            res2 = webpreview.zipAndPost(tc.Dir, cfg);
            for res = {res1, res2}
                tc.verifyFalse(res{1}.ok);
                tc.verifyNotEmpty(res{1}.message);
                tc.verifyEmpty(strfind(res{1}.message, cfg.token));
            end
        end

        function charMatrixTokenDoesNotThrow(tc)
            cfg = PostZipTest.cfg();
            cfg.token = ['ab'; 'cd'];
            tc.verifyEqual(webpreview.tokenOf(cfg), '');
            tc.verifyFalse(webpreview.postZip(tc.makeZip(), cfg).ok);
            tc.verifyFalse(webpreview.zipAndPost(tc.Dir, cfg).ok);
        end

        function timeoutsDefaultAndOverride(tc)
            t = webpreview.timeouts(struct());
            tc.verifyEqual([t.connect t.response t.data], [15 60 60]);
            t = webpreview.timeouts(struct('responseTimeout', 300));
            tc.verifyEqual(t.response, 300);
            tc.verifyError(@() webpreview.timeouts(struct('dataTimeout', -1)), 'webpreview:badConfig');
            tc.verifyError(@() webpreview.timeouts(struct('dataTimeout', 'x')), 'webpreview:badConfig');
        end

        function badTimeoutInCfgReturnsNotOk(tc)
            cfg = PostZipTest.cfg();
            cfg.dataTimeout = 0;
            tc.verifyFalse(webpreview.postZip(tc.makeZip(), cfg).ok);
        end

        function redirectStatusIsNotOkAndSaysSo(tc)
            r = webpreview.interpretResponse(302, '');
            tc.verifyFalse(r.ok);
            tc.verifySubstring(r.message, 'redirect');
        end

        function postZipRejectsHttpToRemoteHost(tc)
            zipPath = tc.makeZip();
            cfg = PostZipTest.cfg();
            cfg.url = 'http://example.org/upload.php';
            res = webpreview.postZip(zipPath, cfg);
            tc.verifyFalse(res.ok);
            tc.verifySubstring(res.message, 'https');
        end

        function postZipSurvivesNonCharToken(tc)
            zipPath = tc.makeZip();
            cfg = PostZipTest.cfg();
            cfg.token = 12345;
            res = webpreview.postZip(zipPath, cfg);
            tc.verifyFalse(res.ok);
        end

        function missingZipReturnsNotOk(tc)
            res = webpreview.postZip(fullfile(tc.Dir, 'nope.zip'), PostZipTest.cfg());
            tc.verifyFalse(res.ok);
            tc.verifyNotEmpty(res.message);
        end

        function badCfgReturnsNotOk(tc)
            res = webpreview.postZip('whatever.zip', struct('url', 'https://x'));
            tc.verifyFalse(res.ok);
        end

        function scrubTokenRemovesEveryOccurrence(tc)
            msg = webpreview.scrubToken('bad Bearer SECRET and again SECRET end', 'SECRET');
            tc.verifyEmpty(strfind(msg, 'SECRET'));
            tc.verifySubstring(msg, '***');
        end

        function scrubTokenNeverThrows(tc)
            tc.verifyEqual(webpreview.scrubToken('msg', ''), 'msg');
            tc.verifyEqual(webpreview.scrubToken('msg', 5), 'msg');
            tc.verifyEqual(webpreview.scrubToken(5, 'tok'), '');
        end

        function status200WithOkBodyIsOk(tc)
            r = webpreview.interpretResponse(200, struct('status', 'ok', 'files', {{'a.jpg'}}));
            tc.verifyTrue(r.ok);
            tc.verifyEqual(r.httpStatus, 200);
        end

        function status200OkWithoutFilesIsOk(tc)
            r = webpreview.interpretResponse(200, struct('status', 'ok'));
            tc.verifyTrue(r.ok);
        end

        function status200WithErrorBodyIsNotOk(tc)
            r = webpreview.interpretResponse(200, struct('status', 'error', 'message', 'boom'));
            tc.verifyFalse(r.ok);
            tc.verifySubstring(r.message, 'boom');
        end

        function errorStatusesAreNotOkAndKeepServerMessage(tc)
            for code = [401 403 413 415 429]
                r = webpreview.interpretResponse(code, struct('status', 'error', 'message', 'nope'));
                tc.verifyFalse(r.ok);
                tc.verifyEqual(r.httpStatus, code);
                tc.verifySubstring(r.message, 'nope');
            end
        end

        function nonJsonEmptyAndArrayBodiesAreHandled(tc)
            bodies = {'<html>oops</html>', [], '', struct('status', {'ok', 'ok'}), {1, 2}};
            for ii = 1:numel(bodies)
                r = webpreview.interpretResponse(200, bodies{ii});
                tc.verifyFalse(r.ok);
                tc.verifyNotEmpty(r.message);
            end
            r = webpreview.interpretResponse(500, '<html>oops</html>');
            tc.verifyEqual(r.httpStatus, 500);
        end
    end

    methods (Static, Access = private)
        function cfg = cfg()
            cfg = struct('url', 'http://127.0.0.1:1/upload.php', ...
                         'siteID', 'site_a', 'token', 'SECRET-TOKEN-XYZ');
        end

        function verifyNetworkFailure(tc, res)
            tc.verifyFalse(res.ok);
            tc.verifyTrue(isnan(res.httpStatus));
            tc.verifyNotEmpty(res.message);
            tc.verifyEmpty(strfind(res.message, 'SECRET-TOKEN-XYZ'));
            % The failure must come from the connection, not from our own
            % argument checks or a coding error.
            tc.verifyEmpty(regexp(res.message, ...
                'cfg must|must (start|be)|not found|Undefined|Unrecognized|Invalid', 'once'));
        end
    end

    methods (Access = private)
        function zipPath = makeZip(tc)
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            zipPath = fullfile(tc.Dir, 'x.zip');
            zip(zipPath, 'a.txt', tc.Dir);
        end
    end
end
