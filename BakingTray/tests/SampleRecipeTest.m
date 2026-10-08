classdef SampleRecipeTest < matlab.unittest.TestCase
    % The core's recipe reader against the real BakingTray recipe and the simulator's
    % patched copy of it. The core's own tests use synthetic recipes only.

    properties
        Dir
        SampleText
    end

    methods (TestClassSetup)
        function addPackagesToPath(tc)
            root = fileparts(fileparts(mfilename('fullpath')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(root), 'upload_core')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(root, 'simulate')));
            tc.SampleText = fileread(fullfile(root, 'simulate', 'sample_data', ...
                'recipe_SW_FG12_3_FG_12_2_191209_120354.yml'));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fx.Folder;
        end
    end

    methods (Test)
        function readsTheSampleRecipe(tc)
            [micID, sampleID] = webupload.readRecipe(tc.writeRecipe(tc.SampleText));
            tc.verifyEqual(micID, 'brainsaw');
            tc.verifyEqual(sampleID, 'SW_FG12_3_FG_12_2');
        end

        function readsTheSimulatedRecipe(tc)
            text = simulate.simulatedRecipeText(tc.SampleText, 5, datetime(2026,1,1));
            [micID, sampleID] = webupload.readRecipe(tc.writeRecipe(text));
            tc.verifyEqual(micID, 'brainsaw');
            tc.verifyEqual(sampleID, simulate.simulationSpec().SampleID);
        end
    end

    methods (Access = private)
        function f = writeRecipe(tc, text)
            f = fullfile(tc.Dir, 'recipe.yml');
            fid = fopen(f, 'w');
            fwrite(fid, text);
            fclose(fid);
        end
    end
end
