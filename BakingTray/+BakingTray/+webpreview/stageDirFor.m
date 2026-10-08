function d = stageDirFor(cfg,micID,stageRoot)
    % The managed stage folder <stageRoot>/brainsaw_webpreview/<siteID>/<micID>/acq
    %
    % function d = BakingTray.webpreview.stageDirFor(cfg,micID,stageRoot)
    %
    % Purpose
    % The one place that decides where staged files live. clearStage deletes the returned
    % folder recursively, so micID is checked against the server's ID rule here (siteID
    % was checked by webupload.webConfig); an ID such as '..' or 'a/b' is an error
    % (webpreview:badMicID). Callers pass a validated cfg and stageRoot. 'acq' is the
    % upload source.
    %
    % Inputs
    % cfg       - webupload.webConfig object.
    % micID     - Microscope ID, as returned by webupload.readRecipe.
    % stageRoot - Folder under which the stage folder lives (char or string).
    %
    % Outputs
    % d - Char path to the stage folder.
    %
    % See also: BakingTray.webpreview.clearStage, BakingTray.webpreview.clearStageDir

    if ~(ischar(micID) && isrow(micID) && ~isempty(regexp(micID,webupload.serverLimits().idRegexp,'once')))
        error('webpreview:badMicID', ...
            'The recipe has no usable microscope ID (SYSTEM.ID): "%s"', char(micID(:)'));
    end
    d = fullfile(char(stageRoot),'brainsaw_webpreview',cfg.siteID,micID,'acq');
end % stageDirFor
