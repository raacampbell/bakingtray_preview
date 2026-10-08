function result = postZip(zipPath, cfg)
    % Upload a zip to the brainsaw server; never throws
    %
    % function result = BakingTray.webpreview.postZip(zipPath, cfg)
    %
    % Purpose
    % Uploads the zip with a bearer token. cfg needs url, siteID and token (see
    % webpreview.loadConfig); the url must be https (webpreview.checkUrl). Optional
    % cfg.connectTimeout, responseTimeout and dataTimeout (seconds; defaults 15, 60, 60; see
    % webpreview.timeouts).
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
    % The token is scrubbed from any message.
    %
    % Inputs
    % zipPath - path to the zip file to upload.
    % cfg - upload configuration structure with fields url, siteID, token and optional
    %       timeouts.
    %
    % Outputs
    % result - structure with fields ok, httpStatus and message. httpStatus is NaN if no
    %          response arrived.

    result = struct('ok', false, 'httpStatus', NaN, 'message', '');
    token = webpreview.tokenOf(cfg);
    try
        mustHave = {'url', 'siteID', 'token'};
        if ~isstruct(cfg) || ~isscalar(cfg) || ~all(isfield(cfg, mustHave))
            error('webpreview:badConfig', ...
                'cfg must be a struct with fields: %s', strjoin(mustHave, ', '));
        end
        if ~ischar(cfg.siteID) || isempty(token)
            error('webpreview:badConfig', 'cfg.siteID and cfg.token must be non-empty text.');
        end
        webpreview.checkUrl(cfg.url);
        opts = makeOptions(webpreview.timeouts(cfg));
        if ~isfile(zipPath)
            error('webpreview:noZip', 'Zip file not found: %s', zipPath);
        end


        % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
        % Build and send the request
        body = matlab.net.http.io.MultipartFormProvider( ...
            'site_id', cfg.siteID, ...
            'data', matlab.net.http.io.FileProvider(zipPath));
        auth = matlab.net.http.HeaderField('Authorization', ['Bearer ', token]);
        req = matlab.net.http.RequestMessage('POST', auth, body);

        resp = req.send(cfg.url, opts);
        result = webpreview.interpretResponse(double(resp.StatusCode), resp.Body.Data);
    catch err
        result.message = err.message;
    end

    result.message = webpreview.scrubToken(result.message, token);
end % postZip


function opts = makeOptions(t)
    % Build HTTPOptions with no redirects and the given timeouts
    %
    % function opts = BakingTray.webpreview.postZip>makeOptions(t)
    %
    % Purpose
    % MaxRedirects = 0 is set unconditionally because it protects the bearer token. The
    % ResponseTimeout and DataTimeout properties are not present in every MATLAB release;
    % if one is missing a warning 'webpreview:postZip:noTimeout' is issued and that timeout
    % is not applied.
    %
    % Inputs
    % t - Structure with fields connect, response and data (seconds), as returned by
    %     webpreview.timeouts.
    %
    % Outputs
    % opts - matlab.net.http.HTTPOptions object.

    opts = matlab.net.http.HTTPOptions();
    opts.MaxRedirects = 0; % security-relevant: set unconditionally
    opts.ConnectTimeout = t.connect;

    % These two names vary by release; warn rather than fail if absent
    optional = {'ResponseTimeout', t.response; 'DataTimeout', t.data};
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
