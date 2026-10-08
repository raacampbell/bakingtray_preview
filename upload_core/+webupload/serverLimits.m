function lim = serverLimits()
    % Upload size limits the client checks before sending
    %
    % function lim = BakingTray.webpreview.serverLimits()
    %
    % Purpose
    % Defaults of max_zip_entries and max_zip_size in brainsaw/lib.php. The server config may
    % set them lower, in which case the server's 413 still reports the problem.
    %
    % Outputs
    % lim - structure with fields maxEntries (files per zip) and maxZipBytes (zip size).

    lim = struct('maxEntries', 500, 'maxZipBytes', 200 * 1024^2);
end % serverLimits
