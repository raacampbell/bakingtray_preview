function s = stageSpec
    % Staged file names and the other fixed settings of the stage folder, defined once
    %
    % function s = webupload.stageSpec
    %
    % Purpose
    % The Names are the exact file names the server keeps (webupload.allowedNames); the
    % recipe is always staged as recipe.yml whatever the extension of the source. Used by
    % stageFiles and by the tests.
    %
    % Outputs
    % s - Structure with fields Names (Main, Montage, Recipe, Log), JpegQuality and
    %     PartSuffix. PartSuffix marks in-progress files, which the server does not keep.

    s.Names.Main = 'LastCompleteSection.jpg';
    s.Names.Montage = 'montage.jpg';
    s.Names.Recipe = 'recipe.yml';
    s.Names.Log = 'acqLog.txt';
    s.JpegQuality = 85;
    s.PartSuffix = '.part';
end % stageSpec
