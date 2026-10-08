function d = stageDirFor(cfg,stageRoot)
    % The managed stage folder <stageRoot>/brainsaw_webpreview/<siteID>/<micID>
    %
    % function d = BakingTray.webpreview.stageDirFor(cfg,stageRoot)
    %
    % Purpose
    % The one place that decides where staged files live. clearStage deletes the returned
    % folder recursively; this is safe because webupload.webConfig has already restricted
    % siteID and micID to [A-Za-z0-9_-]. Callers pass a validated cfg and stageRoot.
    %
    % Inputs
    % cfg       - webupload.webConfig object.
    % stageRoot - Folder under which the stage folder lives (char or string).
    %
    % Outputs
    % d - Char path to the stage folder.
    %
    % See also: BakingTray.webpreview.clearStage, BakingTray.webpreview.clearStageDir

    d = fullfile(char(stageRoot),'brainsaw_webpreview',cfg.siteID,cfg.micID);
end % stageDirFor
