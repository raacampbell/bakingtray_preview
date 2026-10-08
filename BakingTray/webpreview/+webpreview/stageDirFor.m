function d = stageDirFor(siteID,micID,stageRoot)
    % The managed stage folder <stageRoot>/brainsaw_webpreview/<siteID>/<micID>
    %
    % function d = BakingTray.webpreview.stageDirFor(siteID,micID,stageRoot)
    %
    % Purpose
    % The one place that decides where staged files live. Both IDs are re-checked against
    % [A-Za-z0-9_-] (webpreview.webConfig already does this) because clearStage deletes the
    % returned folder recursively.
    %
    % Inputs
    % siteID    - Non-empty text scalar: the site identifier from the config.
    % micID     - Non-empty text scalar: the microscope identifier from the config.
    % stageRoot - Optional non-empty text scalar. Folder under which the stage folder
    %             lives. Default is tempdir.
    %
    % Outputs
    % d - Char path to the stage folder.
    %
    % Errors
    % 'webpreview:stageDirFor:badArgument' if an input is not a non-empty text scalar.
    % 'webpreview:stageDirFor:badSiteID' / 'badMicID' if an ID contains other characters.
    %
    % See also: webpreview.clearStage, webpreview.clearStageDir


    narginchk(2,3)
    if nargin<3
        % Only an omitted argument selects the default; an empty one is rejected below.
        stageRoot = tempdir;
    end

    inputs = {'siteID', siteID; 'micID', micID; 'stageRoot', stageRoot};
    for ii = 1:size(inputs,1)
        x = inputs{ii,2};
        if ~(((ischar(x) && isrow(x)) || (isstring(x) && isscalar(x))) && strlength(x)>0)
            error('webpreview:stageDirFor:badArgument', ...
                '%s must be a non-empty text scalar.', inputs{ii,1})
        end
    end

    siteID = char(siteID);
    micID = char(micID);
    for id = {'siteID', siteID; 'micID', micID}'
        if isempty(regexp(id{2},'^[a-zA-Z0-9_-]+$','once'))
            error(['webpreview:stageDirFor:bad' upper(id{1}(1)) id{1}(2:end)], ...
                '%s "%s" may only contain letters, digits, "_" and "-".', id{1}, id{2})
        end
    end

    d = fullfile(char(stageRoot),'brainsaw_webpreview',siteID,micID);
end % stageDirFor
