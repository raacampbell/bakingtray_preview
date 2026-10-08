function lim = serverLimits()
    % Limits and rules the client checks before sending, mirroring the server
    %
    % function lim = webupload.serverLimits()
    %
    % Purpose
    % Defaults of max_zip_entries and max_zip_size in brainsaw/lib.php. The server config may
    % set them lower, in which case the server's 413 still reports the problem. idRegexp is
    % the rule the server applies to site and microscope IDs. minUploadIntervalSec is the
    % default of min_upload_interval_seconds: the shortest gap between two uploads from
    % one site, microscope and source, which the server enforces with HTTP 429.
    %
    % Outputs
    % lim - structure with fields maxEntries (files per zip), maxZipBytes (zip size),
    %       idRegexp (pattern an ID must match) and minUploadIntervalSec.

    lim = struct('maxEntries', 500, 'maxZipBytes', 200 * 1024^2, ...
                 'idRegexp', '^[A-Za-z][A-Za-z0-9_-]*$', ...
                 'minUploadIntervalSec', 5);
end % serverLimits
