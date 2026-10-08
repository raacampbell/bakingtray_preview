function names = allowedNames()
    % File names (exact, case-sensitive) the brainsaw server keeps
    %
    % function names = webupload.allowedNames()
    %
    % Purpose
    % Mirrors BS_ZIP_ALLOWED_NAMES in brainsaw/lib.php; a test checks the two stay in step.
    %
    % Outputs
    % names - cell row of the five file names the server extracts from an upload.

    names = {'LastCompleteSection.jpg', 'montage.jpg', 'recipe.yml', 'acqLog.txt', 'status.json'};
end % allowedNames
