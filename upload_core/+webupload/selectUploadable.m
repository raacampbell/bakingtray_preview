function names = selectUploadable(dirPath)
    % File names (not paths) in dirPath that the server will keep
    %
    % function names = webupload.selectUploadable(dirPath)
    %
    % Purpose
    % Returns a cell row; empty when nothing matches. Only files whose name is exactly one of
    % webupload.allowedNames are kept. Subfolders are skipped, and so is anything else, which
    % also rules out dotfiles and names containing '*' or '?' (zip() treats those as wildcards
    % and would match other files).
    %
    % Inputs
    % dirPath - path to the folder to scan.
    %
    % Outputs
    % names - cell row of file names.

    d = dir(dirPath);
    names = {d(~[d.isdir]).name};
    names = names(ismember(names, webupload.allowedNames()));
end % selectUploadable
