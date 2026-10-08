classdef (Sealed) webConfig < handle

    % Handles loading and parsing of the web preview config file.
    %
    % Purpose
    % Reads the config file once, validates every field, and then holds the values as
    % read-only properties, so an existing webConfig object is always valid. The secret
    % token is kept out of sight: it is a private, transient property that cannot be read
    % by property access, disp or save. (struct(cfg) can still expose it; that is a MATLAB
    % limitation. A webConfig loaded from a MAT file has no token: build it from the JSON
    % file, never save and load it.) Code that needs the token asks the object:
    %   authHeader - returns the HTTP Authorization header carrying the token
    %   scrub      - removes the token from a message that is going to be shown or logged
    %
    % Any error raised while constructing the object has the token removed from its
    % message, because such errors can quote the file or the values it holds (for example
    % a bad url that contains the token).
    %
    % Rob Campbell - SWC, 2026

    properties (SetAccess = private)
        url     % String defining the URL of the webserver
        siteID  % String defining the site (location) of the microscope
        micID   % String defining the microscope name

        % The following are timeouts in seconds that have default values defined in a
        % hidden constant property. The defaults are used if the values are missing from
        % the file. A value that is present but not a positive finite number is an error.
        connectTimeout
        responseTimeout
        dataTimeout
    end % properties

    properties (Access = private, Transient)
        % String defining the secret token for the transfer. Private so it cannot be read
        % or displayed from outside, and transient so it is never written to a MAT file.
        % The empty default means scrub still works on an object loaded from one.
        token = ''
    end % private properties

    properties (Constant, Hidden)
        defaultTimeouts = {'connectTimeout', 15; 'responseTimeout', 60; 'dataTimeout', 60};
    end % hidden constant properties


    methods
        function obj = webConfig(jsonFile)
            % Read upload settings for web preview from the config JSON file
            %
            % function cfgObj = webupload.webConfig(jsonFile)
            %
            % Purpose
            % Errors if the file is missing or malformed, a field is absent/empty/not
            % text, siteID or micID have characters outside [A-Za-z0-9_-], url is not https
            % (except localhost, for testing), or a timeout is not a positive finite
            % number. Values are trimmed. Required fields: url, siteID, micID, token. See
            % webpreview_config.example.json. The token is removed from any error raised.
            %
            % Inputs
            % jsonFile - [optional] path to the JSON config file. If omitted, the
            %        file at ~/.brainsaw_webpreview.json is used.
            %
            % Outputs
            % cfgObj - returns an instance of the webConfig object

            if nargin < 1
                jsonFile = defaultConfigPath;
            end

            try
                obj.loadFromFile(jsonFile);
            catch err
                % The token is not known to the object if loading failed, so look for it
                % in the raw file text
                throwAsCaller(MException(err.identifier, '%s', ...
                    scrubText(err.message, tokenFromFile(jsonFile))));
            end
        end % constructor


        function header = authHeader(obj)
            % The HTTP Authorization header carrying the token
            %
            % function header = webupload.webConfig.authHeader
            %
            % Purpose
            % The way to send the token without reading it. Use this rather than building
            % a header by hand.
            %
            % Outputs
            % header - matlab.net.http.HeaderField 'Authorization: Bearer <token>'.

            header = matlab.net.http.HeaderField('Authorization', ['Bearer ', obj.token]);
        end % authHeader


        function msg = scrub(obj, msg)
            % Replace every occurrence of the token in a message with '***'
            %
            % function msg = webupload.webConfig.scrub(msg)
            %
            % Purpose
            % Call this on any text that may be shown to the user or logged and that could
            % contain the token: error messages, warnings, replies from the server. Never
            % throws. If msg is not a character row vector the result is ''.
            %
            % Inputs
            % msg - message text.
            %
            % Outputs
            % msg - the scrubbed message.

            msg = scrubText(msg, obj.token);
        end % scrub

    end % methods


    methods (Access = private)

        function loadFromFile(obj, jsonFile)
            % Read the file, validate the contents and set the properties
            %
            % function webupload.webConfig>loadFromFile(jsonFile)
            %
            % Purpose
            % Called by the constructor. Errors here are given the token-scrubbing
            % treatment by the constructor, so it is fine for messages to quote the file.
            %
            % Inputs
            % jsonFile - path to the JSON config file.

            if ~isfile(jsonFile)
                error('webpreview:configMissing', ...
                    ['Config file not found: %s ', ...
                    '(copy webpreview_config.example.json there and fill it in)'], jsonFile);
            end


            % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
            % Read and check the structure of the file
            try
                raw = jsondecode(fileread(jsonFile));
            catch err
                error('webpreview:configInvalid', ...
                    'Config file %s is not valid JSON: %s', jsonFile, err.message);
            end

            if ~(isstruct(raw) && isscalar(raw))
                error('webpreview:configInvalid', ...
                    'Config file %s must contain a single JSON object.', jsonFile);
            end

            required = {'url', 'siteID', 'micID', 'token'};
            absent = required(~isfield(raw, required));
            if ~isempty(absent)
                error('webpreview:configIncomplete', ...
                    'Config file %s is missing field(s): %s', jsonFile, strjoin(absent, ', '));
            end


            % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
            % Text fields: each must be a non-empty JSON string once trimmed. The two IDs
            % are used in folder names, so they are restricted to a safe character set.
            for ii = 1:numel(required)
                name = required{ii};
                value = raw.(name);
                if ~(ischar(value) && (isrow(value) || isempty(value)))
                    error('webpreview:configWrongType', ...
                        'Config field "%s" in %s must be a JSON string.', name, jsonFile);
                end
                value = strtrim(value);
                if isempty(value)
                    error('webpreview:configIncomplete', ...
                        'Config field "%s" in %s is empty.', name, jsonFile);
                end
                if ismember(name, {'siteID', 'micID'}) && isempty(regexp(value, '^[a-zA-Z][a-zA-Z0-9_-]*$', 'once'))
                    error('webpreview:configInvalid', ...
                        'Config field "%s" in %s must start with a letter and contain only letters, digits, "_" and "-".', ...
                        name, jsonFile);
                end
                obj.(name) = value;
            end %for

            checkUrl(obj.url);


            % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
            % Optional timeouts (seconds): use the default if absent, error if not a
            % positive finite number
            for ii = 1:size(obj.defaultTimeouts, 1)
                [name, value] = obj.defaultTimeouts{ii, :};
                if isfield(raw, name)
                    value = raw.(name);
                    if ~(isnumeric(value) && isscalar(value) && isfinite(value) && value > 0)
                        error('webpreview:configWrongType', ...
                            'Config field "%s" in %s must be a positive finite number of seconds.', ...
                            name, jsonFile);
                    end
                end
                obj.(name) = double(value);
            end %for

        end % loadFromFile

    end % private methods

end % classdef



% -----
% Local functions follow

function p = defaultConfigPath()
    % Per-user config location, outside any repository
    %
    % function p = webupload.webConfig>defaultConfigPath()
    %
    % Outputs
    % p - full path to .brainsaw_webpreview.json in the user's home directory. Errors with
    %     webpreview:noHome if the home directory cannot be determined.

    % TODO -- will eventually change this so it looks in the BakingTray SETTINGS path
    if ispc
        home = getenv('USERPROFILE');
    else
        home = getenv('HOME');
    end

    if isempty(home)
        error('webpreview:noHome', 'Cannot determine the home directory.');
    end

    p = fullfile(home, '.brainsaw_webpreview.json');
end % defaultConfigPath


function checkUrl(url)
    % Require https, so the bearer token is never sent in clear text
    %
    % function webupload.webConfig>checkUrl(url)
    %
    % Purpose
    % The one exception is plain http to localhost or 127.0.0.1 (optionally with a port), for
    % testing against a local dev server only. Errors with webpreview:insecureUrl otherwise.
    %
    % Inputs
    % url - non-empty character row vector holding the server URL.

    isHttps = ~isempty(regexp(url, '^https://[^/\s]+', 'once'));
    isLocalDev = ~isempty(regexp(url, '^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)', 'once'));
    if ~(isHttps || isLocalDev)
        error('webpreview:insecureUrl', ...
            ['url must start with https:// ', ...
            '(http:// is allowed only for localhost/127.0.0.1): %s'], url);
    end
end % checkUrl


function msg = scrubText(msg, token)
    % Replace every occurrence of token in msg with '***'
    %
    % function msg = webupload.webConfig>scrubText(msg, token)
    %
    % Purpose
    % Never throws: if msg is not a character row vector the result is ''.
    %
    % Inputs
    % msg   - message text.
    % token - secret to remove from msg.
    %
    % Outputs
    % msg - the scrubbed message.

    if ~ischar(msg) || ~(isrow(msg) || isempty(msg))
        msg = '';
        return
    end
    msg = strrep(msg, token, '***');
end % scrubText


function token = tokenFromFile(file)
    % Best-effort read of the token straight from the raw config file. Never throws
    %
    % function token = webupload.webConfig>tokenFromFile(file)
    %
    % Purpose
    % Used when loading failed, so that an error message which quotes the file or one of
    % its values can still have the token scrubbed from it. The token is found with a
    % regexp on the file text rather than by parsing the JSON, since the JSON may be the
    % problem. Surrounding white space is removed, as it is when the config is loaded.
    %
    % Inputs
    % file - path to the config file.
    %
    % Outputs
    % token - char row vector, or '' if no token could be found.

    token = '';
    try
        tok = regexp(fileread(file),'"token"\s*:\s*"((?:[^"\\]|\\.)*)"','tokens','once');
        if ~isempty(tok)
            token = tok{1};
            try
                % The string may contain escaped quotes; decode it as JSON so the value
                % matches what the constructor would have produced.
                token = jsondecode(['"' tok{1} '"']);
            catch
                % Keep the undecoded text
            end
            token = strtrim(token);
        end
    catch
        % Unreadable file: no token to find
    end %try
end % tokenFromFile

