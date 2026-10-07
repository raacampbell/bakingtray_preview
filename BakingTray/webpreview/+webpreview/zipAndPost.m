function result = zipAndPost(folder, cfg)
    % Zip a folder's preview files, upload them and clean up; never throws
    %
    % function result = BakingTray.webpreview.zipAndPost(folder, cfg)
    %
    % Purpose
    % The entry point for acquisition code. Any failure (missing folder, no files, too large,
    % network, bad cfg) is returned as result.ok = false with a message, with the token
    % scrubbed, so imaging is never interrupted. The temp zip is always deleted. Blocks for up
    % to the postZip timeouts.
    %
    % Inputs
    % folder - path to the folder holding the preview files.
    % cfg - upload configuration structure (see webpreview.loadConfig).
    %
    % Outputs
    % result - structure with fields ok, httpStatus and message.

    result = struct('ok', false, 'httpStatus', NaN, 'message', '');
    try
        zipPath = webpreview.zipFolder(folder);
        cleaner = onCleanup(@() deleteQuietly(zipPath)); %#ok<NASGU> runs on scope exit
        result = webpreview.postZip(zipPath, cfg);
    catch err
        result.message = err.message;
    end
    result.message = webpreview.scrubToken(result.message, webpreview.tokenOf(cfg));
end


function deleteQuietly(path)
    % Delete a file if it exists
    %
    % function BakingTray.webpreview.zipAndPost>deleteQuietly(path)

    if isfile(path)
        delete(path);
    end
end
