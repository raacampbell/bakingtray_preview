function ok = clearStage(varargin)
    % Empty the managed stage folder without uploading. Never throws
    %
    % function ok = BakingTray.webpreview.clearStage('Param1',val1,...)
    %
    % Purpose
    % Call once at the start of a new acquisition so a previous run's recipe and log can
    % never be sent with the first section. The config is needed only for the siteID.
    % Removes just <StageRoot>/brainsaw_webpreview/<siteID>, never its siblings.
    % Any failure warns 'webpreview:clearStage:failed' ("id: message") and returns false.
    % The warning call is guarded so warning('error',...) cannot make this throw.
    %
    % Inputs (optional param/val pairs)
    % 'ConfigFile' - Text scalar. Config file to read the siteID from. Empty (default)
    %                means the default location.
    % 'StageRoot'  - Non-empty text scalar. Folder holding the stage folders. Default is
    %                tempdir.
    %
    % Outputs
    % ok - true when the folder is gone (or never existed), false otherwise.
    %
    % See also: webpreview.updateSectionImage, webpreview.clearStageDir


    ok = false;

    try
        opts = parseOptions(varargin{:});

        if isempty(opts.ConfigFile)
            cfg = webpreview.loadConfig();
        else
            cfg = webpreview.loadConfig(opts.ConfigFile);
        end

        webpreview.clearStageDir(webpreview.stageDirFor(cfg.siteID,opts.StageRoot));
        ok = true;
    catch err
        try
            warning('webpreview:clearStage:failed', 'Stage folder not cleared (%s: %s)', ...
                err.identifier, err.message)
        catch
            % Deliberately ignored: warning('error',...) must not escape
        end
    end %try
end


function opts = parseOptions(varargin)
    % Parse the name/value options. Unknown names and values of the wrong type throw
    params = inputParser;
    params.FunctionName = 'webpreview.clearStage';
    params.CaseSensitive = false;

    params.addParameter('ConfigFile', '', @isTextScalar)
    params.addParameter('StageRoot', tempdir, @isNonEmptyText)
    params.parse(varargin{:});

    % Text options may arrive as strings; everything downstream uses char paths
    opts.ConfigFile = char(params.Results.ConfigFile);
    opts.StageRoot = char(params.Results.StageRoot);
end


function tf = isTextScalar(x)
    % True for a char row (or empty) or a string scalar
    tf = (ischar(x) && (isrow(x) || isequal(size(x),[0 0]))) || (isstring(x) && isscalar(x));
end


function tf = isNonEmptyText(x)
    % True for a non-empty char row or a non-empty string scalar
    tf = ((ischar(x) && isrow(x)) || (isstring(x) && isscalar(x)));
    tf = tf && strlength(x)>0;
end
