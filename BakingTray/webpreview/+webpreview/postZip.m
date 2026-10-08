function result = postZip(zipPath, cfg)
    % Upload a zip to the brainsaw server; never throws
    %
    % function result = BakingTray.webpreview.postZip(zipPath, cfg)
    %
    % Purpose
    % Uploads the zip with a bearer token. cfg is a webpreview.webConfig object, which has
    % already checked the url (https only), siteID, micID and token when it was created. Its
    % connectTimeout, responseTimeout and dataTimeout properties (seconds; defaults 15, 60,
    % 60) set the timeouts. The token is sent with cfg.authHeader, so it is never read here.
    %
    % The multipart body is assembled in memory (buildMultipart) so the request has a
    % Content-Length. The brainsaw server's PHP runs under FastCGI on IONOS and silently drops
    % every form field, including site_id, from a request sent without one (chunked transfer
    % encoding), which shows up as "unknown site_id". The whole zip is read into memory; real
    % preview zips are a few MB and the server limit is 200 MB.
    %
    % Redirects are never followed: the request carries a bearer token, and a redirect could
    % send it to an http:// or other host. A 3xx answer returns ok = false.
    %
    % The call is synchronous: it blocks until the server answers or a timeout fires, so a
    % dead or stalled server delays the caller by about the timeouts. Whether ResponseTimeout
    % and DataTimeout cover the transfer of the upload itself is unverified; a warning
    % (webpreview:postZip:noTimeout) is issued if this MATLAB release lacks either property.
    %
    % Deliberate catch-all: this runs during an acquisition, and a flaky network or bad config
    % must never interrupt imaging. Every failure is reported as result.ok = false instead.
    % The token is scrubbed from any message with cfg.scrub.
    %
    % Inputs
    % zipPath - path to the zip file to upload.
    % cfg - webpreview.webConfig object. Anything else is reported as result.ok = false.
    %
    % Outputs
    % result - structure with fields ok, httpStatus and message. httpStatus is NaN if no
    %          response arrived.

    result = struct('ok', false, 'httpStatus', NaN, 'message', '');
    cfgIsValid = isa(cfg, 'webpreview.webConfig') && isscalar(cfg) && isvalid(cfg);

    try
        if ~cfgIsValid
            error('webpreview:badConfig', 'cfg must be a webpreview.webConfig object.');
        end

        opts = makeOptions(cfg);
        if ~isfile(zipPath)
            error('webpreview:noZip', 'Zip file not found: %s', zipPath);
        end


        % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        % Build and send the request. The multipart body is built in memory, not streamed
        % from a MultipartFormProvider, so that the request carries a Content-Length (see
        % buildMultipart for why).
        [payload, contentType] = buildMultipart(cfg, zipPath);
        body = matlab.net.http.MessageBody();
        body.Payload = payload; % raw bytes; setting Data instead would be converted by Content-Type
        req = matlab.net.http.RequestMessage('POST', [cfg.authHeader, contentType], body);

        resp = req.send(cfg.url, opts);
        result = webpreview.interpretResponse(double(resp.StatusCode), resp.Body.Data);
    catch err
        result.message = err.message;
    end

    if cfgIsValid
        result.message = cfg.scrub(result.message);
    end
end % postZip


function opts = makeOptions(cfg)
    % Build HTTPOptions with no redirects and the timeouts from the config
    %
    % function opts = BakingTray.webpreview.postZip>makeOptions(cfg)
    %
    % Purpose
    % MaxRedirects = 0 is set unconditionally because it protects the bearer token. The
    % ResponseTimeout and DataTimeout properties are not present in every MATLAB release;
    % if one is missing a warning 'webpreview:postZip:noTimeout' is issued and that timeout
    % is not applied.
    %
    % Inputs
    % cfg - webpreview.webConfig object. Its connectTimeout, responseTimeout and
    %       dataTimeout properties are used.
    %
    % Outputs
    % opts - matlab.net.http.HTTPOptions object.

    opts = matlab.net.http.HTTPOptions();
    opts.MaxRedirects = 0; % security-relevant: set unconditionally
    opts.ConnectTimeout = cfg.connectTimeout;

    % These two names vary by release; warn rather than fail if absent
    optional = {'ResponseTimeout', cfg.responseTimeout; 'DataTimeout', cfg.dataTimeout};
    for ii = 1:size(optional, 1)
        if isprop(opts, optional{ii, 1})
            opts.(optional{ii, 1}) = optional{ii, 2};
        else
            warning('webpreview:postZip:noTimeout', ...
                ['HTTPOptions has no %s in this MATLAB release; ', ...
                'that timeout is not applied.'], optional{ii, 1});
        end
    end %for
end % makeOptions


function [payload, contentType] = buildMultipart(cfg, zipPath)
    % Build a multipart/form-data body in memory with the site and microscope IDs and the zip
    %
    % function [payload, contentType] = BakingTray.webpreview.postZip>buildMultipart(cfg, zipPath)
    %
    % Purpose
    % Streaming the body with matlab.net.http.io.MultipartFormProvider gives a request with no
    % Content-Length (chunked), and the brainsaw server's PHP (FastCGI) then receives none of
    % the form fields. Building the bytes here lets MATLAB send the length. The layout follows
    % RFC 7578: 'site_id' and 'microscope_id' text parts, then a 'data' file part (application/zip), each preceded
    % by a boundary line, with CRLF line endings, and a closing boundary.
    %
    % Inputs
    % cfg     - webpreview.webConfig object; its siteID and micID are sent.
    % zipPath - Path to the zip file to send. It is read into memory.
    %
    % Outputs
    % payload     - uint8 row vector holding the whole request body.
    % contentType - matlab.net.http.field.ContentTypeField with the multipart boundary.

    % A random boundary; with 16 hex digits it will not occur in the zip by accident.
    boundary = sprintf('----BrainsawBoundary%08x%08x', randi(2^31-1), randi(2^31-1));

    fid = fopen(zipPath, 'r');
    if fid < 0
        error('webpreview:noZip', 'Could not open zip file: %s', zipPath);
    end
    closer = onCleanup(@() fclose(fid));
    zipBytes = fread(fid, Inf, '*uint8')';
    clear closer

    textFields = {'site_id', cfg.siteID; 'microscope_id', cfg.micID};
    textParts = '';
    for ii = 1:size(textFields, 1)
        textParts = [textParts, sprintf( ...
            '--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n', ...
            boundary, textFields{ii, :})]; %#ok<AGROW>
    end
    siteField = unicode2native(textParts, 'UTF-8');
    fileHeader = unicode2native(sprintf( ...
        ['--%s\r\nContent-Disposition: form-data; name="data"; filename="system_data.zip"\r\n', ...
         'Content-Type: application/zip\r\n\r\n'], boundary), 'UTF-8');
    closing = unicode2native(sprintf('\r\n--%s--\r\n', boundary), 'UTF-8');

    payload = [siteField, fileHeader, zipBytes, closing];
    contentType = matlab.net.http.field.ContentTypeField(['multipart/form-data; boundary=', boundary]);
end % buildMultipart
