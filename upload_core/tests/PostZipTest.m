classdef PostZipTest < matlab.unittest.TestCase
    % Tests for postZip, zipAndPost and interpretResponse.
    % The real upload path needs a live server and is not covered here. Validation of the
    % config and scrubbing of the token are tested in WebConfigTest.

    properties
        Dir
        CfgDir   % holds the config file, kept apart from Dir so it is never zipped
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
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.CfgDir = fx.Folder;
        end
    end

    methods (Test)
        function unreachableUrlReturnsNotOkWithoutThrowing(tc)
            zipPath = tc.makeZip();
            % Port 1 on localhost: connection refused immediately.
            res = webupload.postZip(zipPath, tc.makeCfg());
            PostZipTest.verifyNetworkFailure(tc, res);
        end

        function uploadLeavesGlobalRandomStateAlone(tc)
            % The multipart body is built before the refused connection, so this covers it.
            zipPath = tc.makeZip();
            cfg = tc.makeCfg();
            before = rng;
            webupload.postZip(zipPath, cfg);
            tc.verifyEqual(rng, before);
        end

        function zipAndPostFailureIsNonFatal(tc)
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            res = webupload.zipAndPost(tc.Dir, tc.makeCfg());
            PostZipTest.verifyNetworkFailure(tc, res);
        end

        function zipAndPostReportsFolderProblemsWithoutThrowing(tc)
            res = webupload.zipAndPost(tc.Dir, tc.makeCfg());   % no files
            tc.verifyFalse(res.ok);
            tc.verifyNotEmpty(res.message);
            res = webupload.zipAndPost(fullfile(tc.Dir, 'nope'), tc.makeCfg());
            tc.verifyFalse(res.ok);
        end

        function zipAndPostSurvivesGarbageCfg(tc)
            % A recognised file makes zipFolder succeed, so postZip is reached.
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            for bad = {[], 'str', struct('url', 'https://x'), struct('url', 5, 'siteID', 1, 'token', 7)}
                res = webupload.zipAndPost(tc.Dir, bad{1});
                tc.verifyFalse(res.ok);
                tc.verifyNotEmpty(res.message);
            end
        end

        function tokenInUrlIsScrubbedFromResults(tc)
            % A refused connection may quote the url, so a url that contains the token
            % must not let the token reach the message.
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            cfg = tc.makeCfg('url', ['http://127.0.0.1:1/', PostZipTest.Token]);
            res1 = webupload.postZip(tc.makeZip(), cfg);
            res2 = webupload.zipAndPost(tc.Dir, cfg);
            for res = {res1, res2}
                tc.verifyFalse(res{1}.ok);
                tc.verifyNotEmpty(res{1}.message);
                tc.verifyEmpty(strfind(res{1}.message, PostZipTest.Token));
            end
        end

        function requestCarriesSiteAndMicroscopeIDs(tc)
            % A local socket that never answers captures the request: the operating system
            % accepts the connection and buffers the small request until we accept() it
            % after postZip has given up (short response timeout).
            tc.assumeTrue(usejava('jvm'), 'needs the Java VM to open a local socket');
            srv = java.net.ServerSocket(0);
            tc.addTeardown(@() srv.close());
            srv.setSoTimeout(5000);
            cfg = tc.makeCfg('url', sprintf('http://127.0.0.1:%d/upload.php', srv.getLocalPort()), ...
                             'responseTimeout', 2, 'dataTimeout', 2);
            res = webupload.postZip(tc.makeZip(), cfg);
            tc.verifyFalse(res.ok);
            conn = srv.accept();
            tc.addTeardown(@() conn.close());
            in = conn.getInputStream();
            request = char(zeros(1, 0));
            while in.available() > 0
                request(end+1) = char(mod(in.read(), 256)); %#ok<AGROW> small request
            end
            tc.verifyNotEmpty(regexp(request, '(?i)content-length:\s*\d+', 'once'), ...
                'a Content-Length header is what stops IONOS FastCGI dropping the form fields');
            tc.verifyEmpty(regexp(request, '(?i)transfer-encoding:\s*chunked', 'once'), ...
                'a chunked request loses every form field on IONOS FastCGI');
            tc.verifyNotEmpty(regexp(request, 'name="?site_id"?\s+site_a', 'once'));
            tc.verifyNotEmpty(regexp(request, 'name="?microscope_id"?\s+mic_1', 'once'));
        end

        function redirectStatusIsNotOkAndSaysSo(tc)
            r = webupload.interpretResponse(302, '');
            tc.verifyFalse(r.ok);
            tc.verifySubstring(r.message, 'redirect');
        end

        function missingZipReturnsNotOk(tc)
            res = webupload.postZip(fullfile(tc.Dir, 'nope.zip'), tc.makeCfg());
            tc.verifyFalse(res.ok);
            tc.verifyNotEmpty(res.message);
        end

        function badCfgReturnsNotOk(tc)
            res = webupload.postZip('whatever.zip', struct('url', 'https://x'));
            tc.verifyFalse(res.ok);
            tc.verifySubstring(res.message, 'webConfig');
        end

        function status200WithOkBodyIsOk(tc)
            r = webupload.interpretResponse(200, struct('status', 'ok', 'files', {{'a.jpg'}}));
            tc.verifyTrue(r.ok);
            tc.verifyEqual(r.httpStatus, 200);
        end

        function status200OkWithoutFilesIsOk(tc)
            r = webupload.interpretResponse(200, struct('status', 'ok'));
            tc.verifyTrue(r.ok);
        end

        function status200WithErrorBodyIsNotOk(tc)
            r = webupload.interpretResponse(200, struct('status', 'error', 'message', 'boom'));
            tc.verifyFalse(r.ok);
            tc.verifySubstring(r.message, 'boom');
        end

        function errorStatusesAreNotOkAndKeepServerMessage(tc)
            for code = [401 403 413 415 429]
                r = webupload.interpretResponse(code, struct('status', 'error', 'message', 'nope'));
                tc.verifyFalse(r.ok);
                tc.verifyEqual(r.httpStatus, code);
                tc.verifySubstring(r.message, 'nope');
            end
        end

        function nonJsonEmptyAndArrayBodiesAreHandled(tc)
            bodies = {'<html>oops</html>', [], '', struct('status', {'ok', 'ok'}), {1, 2}};
            for ii = 1:numel(bodies)
                r = webupload.interpretResponse(200, bodies{ii});
                tc.verifyFalse(r.ok);
                tc.verifyNotEmpty(r.message);
            end
            r = webupload.interpretResponse(500, '<html>oops</html>');
            tc.verifyEqual(r.httpStatus, 500);
        end
    end

    properties (Constant, Access = private)
        Token = 'SECRET-TOKEN-XYZ'
    end

    methods (Static, Access = private)
        function verifyNetworkFailure(tc, res)
            tc.verifyFalse(res.ok);
            tc.verifyTrue(isnan(res.httpStatus));
            tc.verifyNotEmpty(res.message);
            tc.verifyEmpty(strfind(res.message, PostZipTest.Token));
            % The failure must come from the connection, not from our own
            % argument checks or a coding error.
            tc.verifyEmpty(regexp(res.message, ...
                'cfg must|must (start|be)|not found|Undefined|Unrecognized|Invalid', 'once'));
        end
    end

    methods (Access = private)
        function cfg = makeCfg(tc, varargin)
            % A webConfig for a refused localhost port. Name/value pairs override fields
            % of the config file, for example makeCfg('url', 'http://127.0.0.1:1/x').
            s = struct('url', 'http://127.0.0.1:1/upload.php', ...
                       'siteID', 'site_a', 'micID', 'mic_1', 'token', PostZipTest.Token);
            for ii = 1:2:numel(varargin)
                s.(varargin{ii}) = varargin{ii+1};
            end
            f = fullfile(tc.CfgDir, 'cfg.json');
            fid = fopen(f, 'w');
            fwrite(fid, jsonencode(s));
            fclose(fid);
            cfg = webupload.webConfig(f);
        end

        function zipPath = makeZip(tc)
            fid = fopen(fullfile(tc.Dir, 'a.txt'), 'w'); fwrite(fid, 'x'); fclose(fid);
            zipPath = fullfile(tc.Dir, 'x.zip');
            zip(zipPath, 'a.txt', tc.Dir);
        end
    end
end
