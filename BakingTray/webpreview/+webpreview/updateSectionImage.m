function result = updateSectionImage(img,recipePath,logPath,varargin)
    % Stage and upload the web preview after a section. Never throws
    %
    % function result = BakingTray.webpreview.updateSectionImage(img,recipePath,logPath,'Param1',val1,...)
    %
    % Purpose
    % The call BakingTray makes when a section completes. It loads the config
    % (webpreview.loadConfig; default location unless 'ConfigFile' is given), stages
    % img, the optional 'Montage', the recipe and the acquisition log with
    % webpreview.stageFiles, and uploads the stage folder with webpreview.zipAndPost.
    % Image conversion and 'Range' are documented in webpreview.toUint8.
    %
    % The stage folder is <StageRoot>/brainsaw_webpreview/<siteID>, with StageRoot
    % defaulting to tempdir. It is reused between calls, so each section replaces the
    % previous files instead of accumulating them. If a new recipe or log cannot be
    % staged, the previous copy stays and is uploaded; this is reported (see
    % result.stale). 'ClearStage',true empties the managed stage folder first; to do
    % that at the start of a new acquisition without uploading anything, use
    % webpreview.clearStage.
    %
    % Deliberate catch-all: a section completing must never be interrupted by the
    % preview, so every failure inside the call (config, image or option problems,
    % staging, network, a throwing poster) is turned into a warning
    % 'webpreview:updateSectionImage:failed' ("id: message") and result.ok = false. The
    % warning call itself is guarded, so warning('error',...) settings cannot make this
    % function throw. Errors in the arguments img, recipePath and logPath are caught
    % too, but a path variable that does not exist in the CALLER is an error MATLAB
    % raises before this function runs, and cannot be caught here.
    %
    % TOKEN: the token is scrubbed from result and warning messages once the config has
    % been read, and, if the config cannot be parsed, by a best-effort regexp on the raw
    % file text. Messages from a custom Poster are scrubbed only after the config was
    % read; anything raised earlier is not guaranteed token-free.
    %
    % Inputs
    % img        - Numeric HxW or HxWx3 image of the section (see webpreview.toUint8).
    % recipePath - Path to the recipe file or to a folder containing it (see
    %              webpreview.stageFiles).
    % logPath    - Path to the acquisition log file.
    %
    % Inputs (optional param/val pairs)
    % 'ConfigFile' - Text scalar. Config file to use. Empty (default) means the default
    %                location.
    % 'Montage'    - Numeric montage image to stage as well. Default is [].
    % 'Range'      - Numeric [lo hi] used to scale the images. Default is [].
    % 'Poster'     - Function handle with the zipAndPost signature,
    %                poster(folder,cfg) -> struct(ok,httpStatus,message) with char
    %                message. Default is @webpreview.zipAndPost; tests inject a fake.
    % 'StageRoot'  - Non-empty text scalar. Folder holding the stage folders. Default is
    %                tempdir.
    % 'ClearStage' - Logical scalar. If true, empty the stage folder first. Default is
    %                false.
    %
    % Outputs
    % result - Structure with fields:
    %   ok          - true if the upload succeeded.
    %   stage       - stageFiles result; [] if not reached.
    %   post        - struct with ok, httpStatus and message.
    %   stageDir    - '' if not reached; a char path built from StageRoot, whereas
    %                 stage.files are canonical, symlink-resolved paths.
    %   recipeFresh - this call staged a new recipe.
    %   logFresh    - this call staged a new log.
    %   stale       - either of the above is false after staging. A notice
    %                 'webpreview:updateSectionImage:stale' names the file when the
    %                 upload otherwise succeeded.
    %   error       - scrubbed MException; [] on success.
    %
    % See also: webpreview.clearStage, webpreview.stageFiles, webpreview.zipAndPost


    result = emptyResult;
    token = '';
    opts = [];
    caught = [];

    try
        opts = parseOptions(varargin{:});
        cfg = loadCfg(opts.ConfigFile);
        token = webpreview.tokenOf(cfg);
        result = runPipeline(result,img,recipePath,logPath,cfg,opts);
    catch err
        caught = err;
        if isempty(token)
            token = rawToken(opts);
        end
    end %try

    result = finalise(result,caught,token);
    notify(result)
end


function result = runPipeline(result,img,recipePath,logPath,cfg,opts)
    % Stage, then post. siteID is charset-checked by loadConfig, so it is safe to use
    % as a folder name.
    stageDir = webpreview.stageDirFor(cfg.siteID,opts.StageRoot);
    if opts.ClearStage
        webpreview.clearStageDir(stageDir);
    end

    result.stage = webpreview.stageFiles(img,recipePath,logPath,stageDir, ...
                        'Montage',opts.Montage,'Range',opts.Range);
    result.stageDir = stageDir;
    result.recipeFresh = result.stage.recipeStaged;
    result.logFresh = result.stage.logStaged;
    result.stale = ~(result.recipeFresh && result.logFresh);


    % From here on failures are recorded in result.error rather than thrown, so the
    % stage information survives into the returned result.
    if ~result.stage.stageOk
        % stageFiles has already warned with the cause; do not upload a partial stage
        result.error = MException('webpreview:updateSectionImage:stageFailed', ...
            'staging in "%s" did not complete, nothing uploaded', stageDir);
        return
    end

    try
        result.post = callPoster(opts.Poster,stageDir,cfg);
        result.ok = result.post.ok;
    catch err
        result.error = err;
    end
end


function opts = parseOptions(varargin)
    % Parse the name/value options. Unknown names and values of the wrong type throw
    params = inputParser;
    params.FunctionName = 'webpreview.updateSectionImage';
    params.CaseSensitive = false;

    params.addParameter('ConfigFile', '', @isTextScalar) % empty means the default location
    params.addParameter('Montage', [], @isnumeric)
    params.addParameter('Range', [], @isnumeric)
    params.addParameter('Poster', @webpreview.zipAndPost, ...
                        @(x) isa(x,'function_handle') && isscalar(x))
    params.addParameter('StageRoot', tempdir, @isNonEmptyText)
    params.addParameter('ClearStage', false, @isLogicalScalar)
    params.parse(varargin{:});

    opts = params.Results;

    % Text options may arrive as strings; everything downstream uses char paths
    opts.ConfigFile = char(opts.ConfigFile);
    opts.StageRoot = char(opts.StageRoot);
    opts.ClearStage = logical(opts.ClearStage);
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


function tf = isLogicalScalar(x)
    % True for a logical scalar or a real, non-NaN numeric scalar (converted by logical)
    tf = isscalar(x) && (islogical(x) || (isnumeric(x) && isreal(x) && ~isnan(x)));
end


function cfg = loadCfg(file)
    if isempty(file)
        cfg = webpreview.loadConfig();
    else
        cfg = webpreview.loadConfig(char(file));
    end
end


function post = callPoster(poster,stageDir,cfg)
    % A poster that throws propagates to updateSectionImage's catch
    post = poster(stageDir,cfg);
    wellFormed = isstruct(post) && isscalar(post) ...
                 && all(isfield(post,{'ok','httpStatus','message'})) ...
                 && islogical(post.ok) && isscalar(post.ok) ...
                 && ischar(post.message);
    if ~wellFormed
        error('webpreview:updateSectionImage:badReply', ...
            ['poster did not return struct(ok, httpStatus, message) ', ...
             'with logical ok and char message'])
    end
end


function token = rawToken(opts)
    % Best effort: the token text from the raw config file, so that a parse error that
    % quotes the file is still scrubbed. Never throws
    token = '';
    try
        if isstruct(opts) && ~isempty(opts.ConfigFile)
            file = opts.ConfigFile;
        else
            file = webpreview.defaultConfigPath();
        end

        % The string may contain escaped quotes; decode it as JSON so the value matches
        % what loadConfig would have produced.
        tok = regexp(fileread(file),'"token"\s*:\s*"((?:[^"\\]|\\.)*)"','tokens','once');
        if ~isempty(tok)
            token = tok{1};
            try
                token = jsondecode(['"' tok{1} '"']);
            catch
                % Keep the undecoded text
            end
        end
    catch
        token = '';
    end %try
end


function result = finalise(result,caught,token)
    % Scrub the message and fill result.error for every kind of failure
    result.post.message = webpreview.scrubToken(result.post.message,token);
    if ~isempty(caught)
        err = caught;
    elseif ~result.ok && ~isempty(result.error)
        err = result.error;
    elseif ~result.ok
        err = MException('webpreview:updateSectionImage:postFailed','%s',result.post.message);
    else
        return
    end

    result.post.message = webpreview.scrubToken(err.message,token);
    result.error = scrubbedException(err.identifier,result.post.message);
end


function ex = scrubbedException(id,message)
    % Rebuilt from the scrubbed text: an MException keeps its original message.
    % A third-party error can carry an identifier MException rejects; fall back to a
    % fixed one rather than throw.
    fallback = 'webpreview:updateSectionImage:unidentified';
    try
        ex = MException(id,'%s',message);
    catch
        ex = MException(fallback,'%s',message);
    end
end


function notify(result)
    % One notice per call from this function (stageFiles may have warned first).
    % Guarded: with warning('error',...) in force the warning call throws, and that
    % must not escape.
    text = '';
    id = '';
    if ~result.ok
        id = 'webpreview:updateSectionImage:failed';
        text = sprintf('Web preview not updated (%s: %s)', ...
                result.error.identifier, result.error.message);
    end

    if result.stale
        if isempty(id)
            id = 'webpreview:updateSectionImage:stale';
            text = 'Web preview uploaded with stale metadata';
        end
        text = sprintf(['%s; %s not refreshed for this section ', ...
                        '(the previously staged copy, if any, was used)'], ...
                text, staleNames(result));
    end

    if isempty(id)
        return
    end

    try
        warning(id,'%s',text)
    catch
        % Deliberately ignored, see above
    end
end


function names = staleNames(result)
    parts = {};
    if ~result.recipeFresh
        parts{end+1} = 'recipe';
    end
    if ~result.logFresh
        parts{end+1} = 'acq log';
    end
    names = strjoin(parts,' and ');
end


function result = emptyResult
    result = struct('ok', false, 'stage', [], ...
        'post', struct('ok',false,'httpStatus',NaN,'message',''), ...
        'stageDir', '', 'recipeFresh', false, 'logFresh', false, 'stale', false, ...
        'error', []);
end
