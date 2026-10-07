classdef LoadConfigTest < matlab.unittest.TestCase
    % Tests for webpreview.loadConfig, defaultConfigPath, checkUrl and the
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
        function validFileReturnsFields(tc)
            f = tc.writeJson(LoadConfigTest.good());
            cfg = webpreview.loadConfig(f);
            tc.verifyEqual(cfg.url, 'https://example.org/upload.php');
            tc.verifyEqual(cfg.siteID, 'site_a-1');
            tc.verifyEqual(cfg.token, 'tok123');
        end

        function valuesAreTrimmed(tc)
            s = LoadConfigTest.good();
            s.token = sprintf('  tok123\n');
            cfg = webpreview.loadConfig(tc.writeJson(s));
            tc.verifyEqual(cfg.token, 'tok123');
        end

        function missingFileErrors(tc)
            tc.verifyError(@() webpreview.loadConfig(fullfile(tc.Dir, 'absent.json')), ...
                'webpreview:configMissing');
        end

        function missingFieldErrorsAndNamesField(tc)
            s = rmfield(LoadConfigTest.good(), 'token');
            f = tc.writeJson(s);
            tc.verifyError(@() webpreview.loadConfig(f), 'webpreview:configIncomplete');
            try
                webpreview.loadConfig(f);
            catch err
                tc.verifySubstring(err.message, 'token');
            end
        end

        function emptyFieldErrors(tc)
            s = LoadConfigTest.good(); s.token = '';
            tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:configIncomplete');
        end

        function whitespaceOnlyFieldErrors(tc)
            s = LoadConfigTest.good(); s.token = '   ';
            tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:configIncomplete');
        end

        function nonTextFieldErrorsWithWrongType(tc)
            s = LoadConfigTest.good(); s.siteID = 42;
            tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:configWrongType');
        end

        function malformedJsonErrors(tc)
            f = fullfile(tc.Dir, 'bad.json');
            fid = fopen(f, 'w'); fwrite(fid, '{not json'); fclose(fid);
            tc.verifyError(@() webpreview.loadConfig(f), 'webpreview:configInvalid');
        end

        function jsonArrayRootErrors(tc)
            f = fullfile(tc.Dir, 'arr.json');
            fid = fopen(f, 'w');
            fwrite(fid, '[{"url":"https://a.b/c","siteID":"x","token":"t"},{"url":"https://a.b/c","siteID":"y","token":"u"}]');
            fclose(fid);
            tc.verifyError(@() webpreview.loadConfig(f), 'webpreview:configInvalid');
        end

        function badSiteIDErrors(tc)
            for bad = {'has space', 'a/b', '../x', 'a.b'}
                s = LoadConfigTest.good(); s.siteID = bad{1};
                tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:configInvalid');
            end
        end

        function optionalTimeoutsPassThroughAndAreValidated(tc)
            s = LoadConfigTest.good(); s.responseTimeout = 300;
            tc.verifyEqual(webpreview.loadConfig(tc.writeJson(s)).responseTimeout, 300);
            s.responseTimeout = 'soon';
            tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:configWrongType');
        end

        function httpUrlIsRejected(tc)
            s = LoadConfigTest.good(); s.url = 'http://example.org/upload.php';
            tc.verifyError(@() webpreview.loadConfig(tc.writeJson(s)), 'webpreview:insecureUrl');
        end

        function localhostHttpIsAllowed(tc)
            for u = {'http://localhost/u.php', 'http://localhost:8080/u.php', 'http://127.0.0.1:8000/upload.php'}
                s = LoadConfigTest.good(); s.url = u{1};
                cfg = webpreview.loadConfig(tc.writeJson(s));
                tc.verifyEqual(cfg.url, u{1});
            end
        end

        function lookalikeLocalhostHostIsRejected(tc)
            tc.verifyError(@() webpreview.checkUrl('http://localhost.evil.com/u'), 'webpreview:insecureUrl');
            tc.verifyError(@() webpreview.checkUrl('http://127.0.0.1.evil.com/u'), 'webpreview:insecureUrl');
        end

        function defaultPathIsExactlyHomeJson(tc)
            tc.setHome(tc.Dir);
            tc.verifyEqual(webpreview.defaultConfigPath(), ...
                fullfile(tc.Dir, '.brainsaw_webpreview.json'));
        end

        function defaultPathErrorsWithoutHome(tc)
            tc.setHome('');
            tc.verifyError(@() webpreview.defaultConfigPath(), 'webpreview:noHome');
        end

        function loadConfigWithNoArgUsesDefaultPath(tc)
            tc.setHome(tc.Dir);
            s = LoadConfigTest.good();
            fid = fopen(fullfile(tc.Dir, '.brainsaw_webpreview.json'), 'w');
            fwrite(fid, jsonencode(s)); fclose(fid);
            tc.verifyEqual(webpreview.loadConfig().siteID, s.siteID);
        end

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
                       'siteID', 'site_a-1', 'token', 'tok123');
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
