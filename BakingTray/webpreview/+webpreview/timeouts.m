function t = timeouts(cfg)
    % HTTP timeouts in seconds from optional cfg fields, with defaults
    %
    % function t = BakingTray.webpreview.timeouts(cfg)
    %
    % Purpose
    % Reads the optional cfg fields connectTimeout (default 15), responseTimeout (60) and
    % dataTimeout (60). Raise them for slow uplinks. Each must be a positive finite scalar;
    % otherwise errors with webpreview:badConfig.
    %
    % Inputs
    % cfg - the upload configuration structure. Anything that is not a scalar structure
    %       yields the defaults.
    %
    % Outputs
    % t - structure with fields connect, response and data (seconds, double).

    names = {'connectTimeout', 15; 'responseTimeout', 60; 'dataTimeout', 60};
    t = struct();
    for ii = 1:size(names, 1)
        value = names{ii, 2};
        if isstruct(cfg) && isscalar(cfg) && isfield(cfg, names{ii, 1})
            value = cfg.(names{ii, 1});
            if ~(isnumeric(value) && isscalar(value) && isfinite(value) && value > 0)
                error('webpreview:badConfig', ...
                    'cfg.%s must be a positive finite number of seconds.', names{ii, 1});
            end
        end
        t.(erase(names{ii, 1}, 'Timeout')) = double(value);
    end %for
end
