function cfg = loadConfig(file)
    % Read upload settings (url, siteID, token) from a JSON file
    %
    % function cfg = BakingTray.webpreview.loadConfig(file)
    %
    % Purpose
    % The file holds the token, so it lives outside the repository. See
    % webpreview_config.example.json for the format. Errors if the file is missing or
    % malformed, a field is absent/empty/not text, siteID has characters outside
    % [A-Za-z0-9_-], or url is not https (see webpreview.checkUrl for the localhost
    % exception). Values are trimmed. Optional timeout fields are validated by
    % webpreview.timeouts.
    %
    % Inputs
    % file - [optional] path to the JSON config file. If omitted, the file at
    %        webpreview.defaultConfigPath (~/.brainsaw_webpreview.json) is used.
    %
    % Outputs
    % cfg - structure with fields url, siteID and token, plus connectTimeout,
    %       responseTimeout and dataTimeout if present in the file.

    if nargin < 1
        file = webpreview.defaultConfigPath();
    end

    if ~isfile(file)
        error('webpreview:configMissing', ...
            ['Config file not found: %s ', ...
            '(copy webpreview_config.example.json there and fill it in)'], file);
    end


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Read and check the structure of the file
    try
        raw = jsondecode(fileread(file));
    catch err
        error('webpreview:configInvalid', ...
            'Config file %s is not valid JSON: %s', file, err.message);
    end

    if ~(isstruct(raw) && isscalar(raw))
        error('webpreview:configInvalid', ...
            'Config file %s must contain a single JSON object.', file);
    end

    required = {'url', 'siteID', 'token'};
    absent = required(~isfield(raw, required));
    if ~isempty(absent)
        error('webpreview:configIncomplete', ...
            'Config file %s is missing field(s): %s', file, strjoin(absent, ', '));
    end


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Required fields: each must be a non-empty JSON string once trimmed
    cfg = struct();
    for ii = 1:numel(required)
        name = required{ii};
        value = raw.(name);
        if ~(ischar(value) && (isrow(value) || isempty(value)))
            error('webpreview:configWrongType', ...
                'Config field "%s" in %s must be a JSON string.', name, file);
        end
        value = strtrim(value);
        if isempty(value)
            error('webpreview:configIncomplete', ...
                'Config field "%s" in %s is empty.', name, file);
        end
        cfg.(name) = value;
    end %for


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Validate the site ID and URL
    if isempty(regexp(cfg.siteID, '^[a-zA-Z0-9_-]+$', 'once'))
        error('webpreview:configInvalid', ...
            'Config siteID in %s may only contain letters, digits, "_" and "-".', file);
    end
    cfg.url = webpreview.checkUrl(cfg.url);


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Optional timeouts (seconds); validated by webpreview.timeouts
    timeoutFields = {'connectTimeout', 'responseTimeout', 'dataTimeout'};
    for ii = 1:numel(timeoutFields)
        if isfield(raw, timeoutFields{ii})
            cfg.(timeoutFields{ii}) = raw.(timeoutFields{ii});
        end
    end %for

    try
        webpreview.timeouts(cfg);
    catch err
        error('webpreview:configWrongType', 'Config %s: %s', file, err.message);
    end
end % loadConfig
