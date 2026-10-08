classdef WebConfigTest < matlab.unittest.TestCase
    % Tests for webpreview.webConfig (loading, validation and token protection) and the
    % extension whitelist.

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
        % ---- loading and validation ----
        function validFileReturnsFields(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            tc.verifyEqual(cfg.url, 'https://example.org/upload.php');
            tc.verifyEqual(cfg.siteID, 'site_a-1');
            tc.verifyEqual(cfg.micID, 'mic_1');
        end

        function valuesAreTrimmed(tc)
            s = WebConfigTest.good();
            s.token = sprintf('  tok123\n');
            s.siteID = sprintf(' site_a-1 ');
            cfg = webpreview.webConfig(tc.writeJson(s));
            tc.verifyEqual(cfg.siteID, 'site_a-1');
            tc.verifyEqual(cfg.scrub('a tok123 b'), 'a *** b');
        end

        function missingFileErrors(tc)
            tc.verifyError(@() webpreview.webConfig(fullfile(tc.Dir, 'absent.json')), ...
                'webpreview:configMissing');
        end

        function missingFieldErrorsAndNamesField(tc)
            for field = {'token', 'micID'}
                f = tc.writeJson(rmfield(WebConfigTest.good(), field{1}));
                tc.verifyError(@() webpreview.webConfig(f), 'webpreview:configIncomplete');
                try
                    webpreview.webConfig(f);
                catch err
                    tc.verifySubstring(err.message, field{1});
                end
            end
        end

        function emptyFieldErrors(tc)
            s = WebConfigTest.good(); s.token = '';
            tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configIncomplete');
        end

        function whitespaceOnlyFieldErrors(tc)
            s = WebConfigTest.good(); s.token = '   ';
            tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configIncomplete');
        end

        function nonTextFieldErrorsWithWrongType(tc)
            for field = {'siteID', 'micID', 'token', 'url'}
                s = WebConfigTest.good(); s.(field{1}) = 42;
                tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configWrongType');
            end
        end

        function charMatrixTokenIsRejected(tc)
            s = WebConfigTest.good(); s.token = ['ab'; 'cd'];
            tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configWrongType');
        end

        function malformedJsonErrors(tc)
            f = fullfile(tc.Dir, 'bad.json');
            fid = fopen(f, 'w'); fwrite(fid, '{not json'); fclose(fid);
            tc.verifyError(@() webpreview.webConfig(f), 'webpreview:configInvalid');
        end

        function jsonArrayRootErrors(tc)
            f = fullfile(tc.Dir, 'arr.json');
            fid = fopen(f, 'w');
            fwrite(fid, '[{"url":"https://a.b/c","siteID":"x","micID":"m","token":"t"},{"url":"https://a.b/c","siteID":"y","micID":"m","token":"u"}]');
            fclose(fid);
            tc.verifyError(@() webpreview.webConfig(f), 'webpreview:configInvalid');
        end

        function badIDsError(tc)
            for field = {'siteID', 'micID'}
                for bad = {'has space', 'a/b', '../x', 'a.b'}
                    s = WebConfigTest.good(); s.(field{1}) = bad{1};
                    tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configInvalid');
                end
            end
        end

        function timeoutsDefaultAndOverride(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            tc.verifyEqual([cfg.connectTimeout cfg.responseTimeout cfg.dataTimeout], [15 60 60]);
            s = WebConfigTest.good(); s.responseTimeout = 300;
            cfg = webpreview.webConfig(tc.writeJson(s));
            tc.verifyEqual([cfg.connectTimeout cfg.responseTimeout cfg.dataTimeout], [15 300 60]);
        end

        function badTimeoutsError(tc)
            for bad = {-1, 0, 'soon', Inf, [1 2]}
                s = WebConfigTest.good(); s.dataTimeout = bad{1};
                tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:configWrongType');
            end
        end

        function httpUrlIsRejected(tc)
            s = WebConfigTest.good(); s.url = 'http://example.org/upload.php';
            tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:insecureUrl');
        end

        function localhostHttpIsAllowed(tc)
            for u = {'http://localhost/u.php', 'http://localhost:8080/u.php', 'http://127.0.0.1:8000/upload.php'}
                s = WebConfigTest.good(); s.url = u{1};
                cfg = webpreview.webConfig(tc.writeJson(s));
                tc.verifyEqual(cfg.url, u{1});
            end
        end

        function lookalikeLocalhostHostIsRejected(tc)
            for u = {'http://localhost.evil.com/u', 'http://127.0.0.1.evil.com/u'}
                s = WebConfigTest.good(); s.url = u{1};
                tc.verifyError(@() webpreview.webConfig(tc.writeJson(s)), 'webpreview:insecureUrl');
            end
        end

        function noArgUsesDefaultPathInHome(tc)
            tc.setHome(tc.Dir);
            s = WebConfigTest.good();
            fid = fopen(fullfile(tc.Dir, '.brainsaw_webpreview.json'), 'w');
            fwrite(fid, jsonencode(s)); fclose(fid);
            tc.verifyEqual(webpreview.webConfig().siteID, s.siteID);
        end

        function noArgErrorsWithoutHome(tc)
            tc.setHome('');
            tc.verifyError(@() webpreview.webConfig(), 'webpreview:noHome');
        end

        function propertiesCannotBeChangedAfterConstruction(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            tc.verifyError(@() WebConfigTest.setUrl(cfg, 'http://evil.example/'), ...
                'MATLAB:class:SetProhibited');
            tc.verifyEqual(cfg.url, 'https://example.org/upload.php');
        end

        % ---- token protection ----
        function tokenCannotBeRead(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            tc.verifyError(@() cfg.token, 'MATLAB:class:GetProhibited');
        end

        function tokenDoesNotAppearInDisplay(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            txt = evalc('disp(cfg)');
            tc.verifyThat(txt, ~matlab.unittest.constraints.ContainsSubstring('tok123'));
            txt = evalc('cfg');
            tc.verifyThat(txt, ~matlab.unittest.constraints.ContainsSubstring('tok123'));
        end

        function authHeaderCarriesTheToken(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            h = cfg.authHeader();
            tc.verifyClass(h, 'matlab.net.http.HeaderField');
            tc.verifyEqual(char(h.Name), 'Authorization');
            tc.verifyEqual(char(h.Value), 'Bearer tok123');
        end

        function scrubRemovesEveryOccurrence(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            msg = cfg.scrub('bad Bearer tok123 and again tok123 end');
            tc.verifyEmpty(strfind(msg, 'tok123'));
            tc.verifyEqual(msg, 'bad Bearer *** and again *** end');
        end

        function scrubNeverThrows(tc)
            cfg = webpreview.webConfig(tc.writeJson(WebConfigTest.good()));
            tc.verifyEqual(cfg.scrub('msg'), 'msg');
            tc.verifyEqual(cfg.scrub(''), '');
            tc.verifyEqual(cfg.scrub(5), '');
            tc.verifyEqual(cfg.scrub(['ab'; 'cd']), '');
        end

        function constructorErrorsAreScrubbed(tc)
            % The url error echoes the url, and here the url holds the token.
            s = WebConfigTest.good(); s.url = ['http://evil.example/' s.token];
            f = tc.writeJson(s);
            try
                webpreview.webConfig(f);
                tc.verifyFail('expected the constructor to error');
            catch err
                tc.verifyEqual(err.identifier, 'webpreview:insecureUrl');
                tc.verifyThat(err.message, ~matlab.unittest.constraints.ContainsSubstring(s.token));
                tc.verifySubstring(err.message, 'http://evil.example/***');
            end
        end

        function constructorErrorsAreScrubbedWhenTokenHasEscapedQuotes(tc)
            % The JSON token abc"def is written abc\"def in the file.
            f = fullfile(tc.Dir, 'cfg.json');
            fid = fopen(f, 'w');
            fwrite(fid, '{"url":"http://evil/abc\"def","siteID":"site-1","micID":"m","token":"abc\"def"}');
            fclose(fid);
            try
                webpreview.webConfig(f);
                tc.verifyFail('expected the constructor to error');
            catch err
                tc.verifyThat(err.message, ~matlab.unittest.constraints.ContainsSubstring('abc"def'));
                tc.verifySubstring(err.message, 'http://evil/***');
            end
        end

        function constructorErrorsAreScrubbedEvenIfTheJsonIsBroken(tc)
            % The token is found with a regexp on the raw text, so it is still removed
            % from the error message if the file cannot be parsed.
            f = fullfile(tc.Dir, 'broken.json');
            fid = fopen(f, 'w');
            fwrite(fid, '{"url":"https://x.example/tok123", "token":"tok123" "oops"}');
            fclose(fid);
            try
                webpreview.webConfig(f);
                tc.verifyFail('expected the constructor to error');
            catch err
                tc.verifyEqual(err.identifier, 'webpreview:configInvalid');
                tc.verifyThat(err.message, ~matlab.unittest.constraints.ContainsSubstring('tok123'));
            end
        end

        % ---- not config ----
        function extensionWhitelistMatchesServer(tc)
            libFile = fullfile(fileparts(mfilename('fullpath')), '..', '..', '..', 'brainsaw', 'lib.php');
            tc.assumeTrue(isfile(libFile), 'brainsaw/lib.php not present');
            txt = fileread(libFile);
            list = regexp(txt, 'BS_ZIP_ALLOWED_EXTENSIONS\s*=\s*\[([^\]]*)\]', 'tokens', 'once');
            tc.assertNotEmpty(list, 'BS_ZIP_ALLOWED_EXTENSIONS not found in lib.php');
            serverExts = regexp(list{1}, '''([^'']+)''', 'tokens');
            serverExts = cellfun(@(c) c{1}, serverExts, 'UniformOutput', false);
            tc.verifyEqual(sort(webpreview.allowedExtensions()), sort(serverExts));
        end
    end

    methods (Static, Access = private)
        function s = good()
            s = struct('url', 'https://example.org/upload.php', ...
                       'siteID', 'site_a-1', 'micID', 'mic_1', 'token', 'tok123');
        end

        function setUrl(cfg, value)
            % Anonymous functions cannot assign, so this wraps the assignment.
            cfg.url = value;
        end
    end

    methods (Access = private)
        function f = writeJson(tc, s)
            f = fullfile(tc.Dir, 'cfg.json');
            fid = fopen(f, 'w');
            fwrite(fid, jsonencode(s));
            fclose(fid);
        end

        function setHome(tc, folder)
            % Point both home variables at folder and restore them afterwards.
            for name = {'HOME', 'USERPROFILE'}
                old = getenv(name{1});
                setenv(name{1}, folder);
                tc.addTeardown(@() setenv(name{1}, old));
            end
        end
    end
end
