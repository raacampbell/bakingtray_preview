function token = tokenOf(cfg)
    % Return the token in cfg if it is a non-empty character row, else ''
    %
    % function token = BakingTray.webpreview.tokenOf(cfg)
    %
    % Purpose
    % Never throws; used to scrub error messages whatever shape cfg has. A char matrix is
    % rejected because strrep would error on it.
    %
    % Inputs
    % cfg - the upload configuration structure (any other type is tolerated).
    %
    % Outputs
    % token - character row, or '' if cfg holds no usable token.

    token = '';
    if isstruct(cfg) && isscalar(cfg) && isfield(cfg, 'token') ...
            && ischar(cfg.token) && isrow(cfg.token)
        token = cfg.token;
    end
end
