classdef ZipFolderTest < matlab.unittest.TestCase
    % Tests for webupload.zipFolder and selectUploadable. Each test builds
    % its own tiny folder.

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
        function keepsOnlyRecognisedExtensions(tc)
            keep = {'a.jpg', 'b.JPEG', 'c.png', 'd.txt', 'e.yml', 'f.yaml', 'g.json', 'h.csv', 'i.log'};
            drop = {'evil.php', '.htaccess', 'raw.tif', 'noext'};
            ZipFolderTest.touch(tc.Dir, [keep, drop]);

            zipPath = webupload.zipFolder(tc.Dir);
            tc.addTeardown(@() delete(zipPath));

            tc.verifyEqual(sort(ZipFolderTest.listZip(zipPath)), sort(keep(:)));
        end

        function dotfilesAreSkippedEvenWithGoodExtension(tc)
            ZipFolderTest.touch(tc.Dir, {'.hidden.txt', '.env.json', 'ok.txt'});
            tc.verifyEqual(webupload.selectUploadable(tc.Dir), {'ok.txt'});
        end

        function bracketNamesAreKept(tc)
            ZipFolderTest.touch(tc.Dir, {'a[1].txt', 'a1.txt'});
            zipPath = webupload.zipFolder(tc.Dir);
            tc.addTeardown(@() delete(zipPath));
            tc.verifyEqual(sort(ZipFolderTest.listZip(zipPath)), {'a1.txt'; 'a[1].txt'});
        end

        function wildcardNamesAreSkipped(tc)
            % '*' and '?' are illegal in Windows file names; only test where possible.
            tc.assumeFalse(ispc);
            ZipFolderTest.touch(tc.Dir, {'we*ird.txt', 'we?ird.txt', 'ok.txt'});
            tc.verifyEqual(webupload.selectUploadable(tc.Dir), {'ok.txt'});
        end

        function zipIsFlatAndIgnoresSubfolders(tc)
            ZipFolderTest.touch(tc.Dir, {'top.txt'});
            sub = fullfile(tc.Dir, 'sub');
            mkdir(sub);
            ZipFolderTest.touch(sub, {'nested.txt'});

            zipPath = webupload.zipFolder(tc.Dir);
            tc.addTeardown(@() delete(zipPath));

            tc.verifyEqual(ZipFolderTest.listZip(zipPath), {'top.txt'});
        end

        function zipEndsInDotZipAndExists(tc)
            ZipFolderTest.touch(tc.Dir, {'a.txt'});
            zipPath = webupload.zipFolder(tc.Dir);
            tc.addTeardown(@() delete(zipPath));
            tc.verifyTrue(endsWith(zipPath, '.zip'));
            tc.verifyEqual(exist(zipPath, 'file'), 2);
        end

        function emptyDirErrors(tc)
            tc.verifyError(@() webupload.zipFolder(tc.Dir), 'webpreview:noFiles');
        end

        function dirWithOnlyUnrecognisedFilesErrors(tc)
            ZipFolderTest.touch(tc.Dir, {'evil.php', 'raw.tif'});
            tc.verifyError(@() webupload.zipFolder(tc.Dir), 'webpreview:noFiles');
        end

        function missingDirErrors(tc)
            tc.verifyError(@() webupload.zipFolder(fullfile(tc.Dir, 'nope')), ...
                'webpreview:noSuchFolder');
        end

        function tooManyFilesErrorsBeforeZipping(tc)
            lim = webupload.serverLimits();
            names = arrayfun(@(k) sprintf('f%d.txt', k), 1:lim.maxEntries + 1, 'UniformOutput', false);
            ZipFolderTest.touch(tc.Dir, names);
            tc.verifyError(@() webupload.zipFolder(tc.Dir), 'webpreview:tooManyFiles');
        end
    end

    methods (Static, Access = private)
        function touch(folder, names)
            for ii = 1:numel(names)
                fid = fopen(fullfile(folder, names{ii}), 'w');
                fwrite(fid, 'x');
                fclose(fid);
            end
        end

        function names = listZip(zipPath)
            % Unzip to a scratch folder; return the file names as a column.
            % Any extracted folder means the archive was not flat.
            out = tempname;
            mkdir(out);
            cleaner = onCleanup(@() rmdir(out, 's')); %#ok<NASGU>
            unzip(zipPath, out);
            d = dir(out);
            d = d(~ismember({d.name}, {'.', '..'}));
            assert(~any([d.isdir]), 'zip contained a folder');
            names = {d.name}';
        end
    end
end
