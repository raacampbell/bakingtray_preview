function url = checkUrl(url)
    % Require https, so the bearer token is never sent in clear text
    %
    % function url = BakingTray.webpreview.checkUrl(url)
    %
    % Purpose
    % The one exception is plain http to localhost or 127.0.0.1 (optionally with a port), for
    % testing against a local dev server only. Errors with webpreview:insecureUrl otherwise.
    %
    % Inputs
    % url - character vector holding the server URL.
    %
    % Outputs
    % url - the input url, unchanged, if it is acceptable.

    if ~ischar(url) || isempty(url)
        error('webpreview:insecureUrl', 'url must be a non-empty character vector.');
    end

    isHttps = ~isempty(regexp(url, '^https://[^/\s]+', 'once'));
    isLocalDev = ~isempty(regexp(url, '^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)', 'once'));
    if ~(isHttps || isLocalDev)
        error('webpreview:insecureUrl', ...
            ['url must start with https:// ', ...
            '(http:// is allowed only for localhost/127.0.0.1): %s'], url);
    end
end % checkUrl
