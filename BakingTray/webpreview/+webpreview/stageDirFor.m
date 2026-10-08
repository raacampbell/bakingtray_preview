function d = stageDirFor(siteID,stageRoot)
    % The managed stage folder <stageRoot>/brainsaw_webpreview/<siteID>
    %
    % function d = BakingTray.webpreview.stageDirFor(siteID,stageRoot)
    %
    % Purpose
    % The one place that decides where staged files live. siteID is re-checked against
    % [A-Za-z0-9_-] (loadConfig already does this) because clearStage deletes the
    % returned folder recursively.
    %
    % Inputs
    % siteID    - Non-empty text scalar: the site identifier from the config.
    % stageRoot - Optional non-empty text scalar. Folder under which the stage folder
    %             lives. Default is tempdir.
    %
    % Outputs
    % d - Char path to the stage folder.
    %
    % Errors
    % 'webpreview:stageDirFor:badArgument' if an input is not a non-empty text scalar.
    % 'webpreview:stageDirFor:badSiteID' if siteID contains other characters.
    %
    % See also: webpreview.clearStage, webpreview.clearStageDir


    narginchk(1,2)
    if nargin<2
        % Only an omitted argument selects the default; an empty one is rejected below.
        stageRoot = tempdir;
    end

    if ~isNonEmptyText(siteID)
        error('webpreview:stageDirFor:badArgument', ...
            'siteID must be a non-empty text scalar.')
    end
    if ~isNonEmptyText(stageRoot)
        error('webpreview:stageDirFor:badArgument', ...
            'stageRoot must be a non-empty text scalar.')
    end

    siteID = char(siteID);
    if isempty(regexp(siteID,'^[a-zA-Z0-9_-]+$','once'))
        error('webpreview:stageDirFor:badSiteID', ...
            'siteID "%s" may only contain letters, digits, "_" and "-".', siteID)
    end

    d = fullfile(char(stageRoot),'brainsaw_webpreview',siteID);
end % stageDirFor


function tf = isNonEmptyText(x)
    % True for a non-empty char row vector or a non-empty string scalar
    %
    % function tf = BakingTray.webpreview.stageDirFor>isNonEmptyText(x)
    %
    % Inputs
    % x - Any value.
    %
    % Outputs
    % tf - true if x is a char row vector or string scalar with at least one character.

    tf = (ischar(x) && isrow(x)) || (isstring(x) && isscalar(x));
    tf = tf && strlength(x)>0;
end % isNonEmptyText
