function exts = allowedExtensions()
    % Extensions (no dot, lower case) the brainsaw server keeps
    %
    % function exts = webupload.allowedExtensions()
    %
    % Purpose
    % Mirrors BS_ZIP_ALLOWED_EXTENSIONS in brainsaw/lib.php; a test checks the two stay in step.
    %
    % Outputs
    % exts - cell row of lower-case extensions without the leading dot.

    exts = {'jpg', 'jpeg', 'png', 'txt', 'yml', 'yaml', 'json', 'csv', 'log'};
end % allowedExtensions
