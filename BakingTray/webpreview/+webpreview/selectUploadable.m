function names = selectUploadable(dirPath)
    % File names (not paths) in dirPath that the server will keep
    %
    % function names = BakingTray.webpreview.selectUploadable(dirPath)
    %
    % Purpose
    % Returns a cell row; empty when nothing matches. Skipped:
    %   - subfolders
    %   - dotfiles (the server drops basenames starting with '.')
    %   - extensions not in webpreview.allowedExtensions
    %   - names containing '*' or '?': zip() treats those as wildcards and would match other
    %     files. Other special-looking characters such as [ ] are not wildcards for zip().
    %
    % Inputs
    % dirPath - path to the folder to scan.
    %
    % Outputs
    % names - cell row of file names.

    d = dir(dirPath);
    names = {d(~[d.isdir]).name};
    [~, ~, ext] = cellfun(@fileparts, names, 'UniformOutput', false);
    ext = lower(strrep(ext, '.', ''));
    keep = ismember(ext, webpreview.allowedExtensions()) ...
        & ~startsWith(names, '.') ...
        & ~contains(names, {'*', '?'});
    names = names(keep);
end
