function s = stageSpec
    % Output file names and the server's glob patterns, defined once
    %
    % function s = BakingTray.webpreview.stageSpec
    %
    % Purpose
    % The Globs are the literal patterns brainsaw/lib.php uses to find files in a site
    % folder; the staged Names must match them. Used by stageFiles (to find stale
    % files) and by the tests.
    %
    % Outputs
    % s - Structure with fields Names (Main, Montage, Log, Recipe), Globs (Main,
    %     Montage, Recipe, Log), JpegQuality and PartSuffix. The recipe is always staged
    %     as recipe.yml, whatever the extension of the source, as the server expects.
    %     PartSuffix marks in-progress files, which match no server glob.

    s.Names.Main = 'LastCompleteSection.jpg';
    s.Names.Montage = 'montage.jpg';
    s.Names.Log = 'acqLog.txt';
    s.Names.Recipe = 'recipe.yml';
    s.Globs.Main = 'LastCompleteSection*.jp*g';
    s.Globs.Montage = '*[Mm]ontage*.jp*g';
    s.Globs.Recipe = '*ecipe*.y*ml';
    s.Globs.Log = '*cqLog*.txt';
    s.JpegQuality = 85;
    s.PartSuffix = '.part';
end % stageSpec
