function result = postZip(zipPath, cfg)
    % Upload a zip to the brainsaw server; never throws
    %
    % function result = BakingTray.webpreview.postZip(zipPath, cfg)
    %
    % Purpose
    % Uploads the zip with a bearer token. cfg is a webpreview.webConfig object, which has
    % already checked the url (https only), siteID and token when it was created. Its
    % connectTimeout, responseTimeout and dataTimeout properties (seconds; defaults 15, 60,
    % 60) set the timeouts. The token is sent with cfg.authHeader, so it is never read here.
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
        % Build and send the request
        body = matlab.net.http.io.MultipartFormProvider( ...
            'site_id', cfg.siteID, ...
            'data', matlab.net.http.io.FileProvider(zipPath));
        req = matlab.net.http.RequestMessage('POST', cfg.authHeader, body);

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
