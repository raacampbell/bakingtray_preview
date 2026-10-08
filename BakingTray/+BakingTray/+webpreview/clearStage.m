function ok = clearStage(cfg,micID,varargin)
    % Empty the managed stage folder without uploading. Never throws
    %
    % function ok = BakingTray.webpreview.clearStage(cfg,micID,'Param1',val1,...)
    %
    % Purpose
    % Call once at the start of a new acquisition so a previous run's recipe and log can
    % never be sent with the first section. The config and micID give the folder.
    % Removes just <StageRoot>/brainsaw_webpreview/<siteID>/<micID>/acq, never its
    % siblings. Any failure (including a cfg that is not a valid webConfig) warns
    % 'webpreview:clearStage:failed' ("id: message") and returns false. The warning call is
    % guarded so warning('error',...) cannot make this throw. A symlink planted inside
    % StageRoot is not guarded against, so StageRoot should be a per-user folder.
    %
    % Inputs
    % cfg   - webupload.webConfig object.
    % micID - Microscope ID, as returned by webupload.readRecipe.
    %
    % Inputs (optional param/val pairs)
    % 'StageRoot'  - Non-empty text scalar. Folder holding the stage folders. Default is
    %                tempdir.
    %
    % Outputs
    % ok - true when the folder is gone (or never existed), false otherwise.
    %
    % See also: BakingTray.webpreview.updateSectionImage, BakingTray.webpreview.clearStageDir


    ok = false;

    try
        if ~(isa(cfg,'webupload.webConfig') && isscalar(cfg) && isvalid(cfg))
            error('webpreview:clearStage:badConfig','cfg must be a webupload.webConfig object.')
        end

        isNonEmptyText = @(x) ((ischar(x) && isrow(x)) || (isstring(x) && isscalar(x))) ...
                              && strlength(x)>0;
        params = inputParser;
        params.FunctionName = 'BakingTray.webpreview.clearStage';
        params.CaseSensitive = false;
        params.addParameter('StageRoot', tempdir, isNonEmptyText)
        params.parse(varargin{:});

        stageDir = BakingTray.webpreview.stageDirFor(cfg,micID,params.Results.StageRoot);
        BakingTray.webpreview.clearStageDir(stageDir);
        ok = true;
    catch err
        try
            warning('webpreview:clearStage:failed', 'Stage folder not cleared (%s: %s)', ...
                err.identifier, err.message)
        catch
            % Deliberately ignored: warning('error',...) must not escape
        end
    end %try
end % clearStage
