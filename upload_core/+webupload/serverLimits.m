function lim = serverLimits()
    % Limits and rules the client checks before sending, mirroring the server
    %
    % function lim = webupload.serverLimits()
    %
    % Purpose
    % Defaults of max_zip_entries and max_zip_size in brainsaw/lib.php. The server config may
    % set them lower, in which case the server's 413 still reports the problem. idRegexp is
    % the rule the server applies to site and microscope IDs. minUploadIntervalSec is this
    % client's copy of min_upload_interval_seconds in brainsaw/config.php (lib.php itself
    % falls back to 0 if unset; a test keeps the copy equal to config.php): the shortest
    % gap between two uploads from one site, microscope and source, which the server
    % enforces with HTTP 429. A site that raises it makes the client's copy too short.
    %
    % Outputs
    % lim - structure with fields maxEntries (files per zip), maxZipBytes (zip size),
    %       idRegexp (pattern an ID must match) and minUploadIntervalSec.

    lim = struct('maxEntries', 500, 'maxZipBytes', 200 * 1024^2, ...
                 'idRegexp', '^[A-Za-z][A-Za-z0-9_-]*$', ...
                 'minUploadIntervalSec', 5);
end % serverLimits
