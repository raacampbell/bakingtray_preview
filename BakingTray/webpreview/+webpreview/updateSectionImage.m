function result = updateSectionImage(img,recipePath,logPath,varargin)
    % Stage and upload the web preview after a section. Never throws
    %
    % function result = BakingTray.webpreview.updateSectionImage(img,recipePath,logPath,'Param1',val1,...)
    %
    % Purpose
    % The call BakingTray makes when a section completes. It loads the config
    % (webpreview.webConfig; default location unless 'ConfigFile' is given), stages
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
    % TOKEN: the config is held in a webpreview.webConfig object, which keeps the token
    % private. An error raised while the config is being loaded is scrubbed of the token by
    % webConfig itself. Once the config has been read, the token is also scrubbed from
    % result and warning messages with webConfig.scrub. Messages from a custom Poster are
    % scrubbed only after the config was read.
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
    %                message, where cfg is a webpreview.webConfig object. Default is
    %                @webpreview.zipAndPost; tests inject a fake.
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
    cfg = [];
    caught = [];

    try
        % Parse the optional param/val pairs with the local function parseOptions
        opts = parseOptions(varargin{:});


        % Load the config file from the default location unless the user has supplied another
        if isempty(opts.ConfigFile)
            cfg = webpreview.webConfig();
        else
            cfg = webpreview.webConfig(opts.ConfigFile);
        end


        result = runPipeline(result,img,recipePath,logPath,cfg,opts);
    catch err
        caught = err;
    end %try

    result = finalise(result,caught,cfg);
    notify(result)
end % updateSectionImage


function result = runPipeline(result,img,recipePath,logPath,cfg,opts)
    % Stage the files, then upload the stage folder, recording what happened in result
    %
    % function result = BakingTray.webpreview.updateSectionImage>runPipeline(result,img,recipePath,logPath,cfg,opts)
    %
    % Purpose
    % The part of updateSectionImage that runs inside its try/catch. Builds the stage folder
    % path from cfg.siteID and opts.StageRoot (siteID is charset-checked by webConfig, so
    % it is safe to use as a folder name), empties it if opts.ClearStage is true, stages the
    % files with webpreview.stageFiles and uploads the folder with opts.Poster.
    %
    % Anything that goes wrong before staging has finished is thrown and caught by
    % updateSectionImage. After that, failures are written to result.error instead, so the
    % stage information survives into the returned result. If staging did not complete
    % nothing is uploaded.
    %
    % Inputs
    % result     - Structure from emptyResult, to be filled in.
    % img        - Numeric HxW or HxWx3 image of the section.
    % recipePath - Path to the recipe file or to a folder containing it.
    % logPath    - Path to the acquisition log file.
    % cfg        - webpreview.webConfig object.
    % opts       - Options structure from parseOptions.
    %
    % Outputs
    % result - The input structure with stage, stageDir, recipeFresh, logFresh and stale
    %          filled in. post and ok are set once the poster has returned. error is set if
    %          staging was incomplete or the poster threw.

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
end % runPipeline


function opts = parseOptions(varargin)
    % Parse and validate the param/val options of updateSectionImage
    %
    % function opts = BakingTray.webpreview.updateSectionImage>parseOptions(varargin)
    %
    % Purpose
    % Uses inputParser, so unknown names and values of the wrong type throw. Text options
    % may arrive as strings; they are converted to char because everything downstream uses
    % char paths.
    %
    % Inputs
    % varargin - The 'Param1',val1,... pairs documented in updateSectionImage.
    %
    % Outputs
    % opts - Structure with fields ConfigFile (char), Montage, Range, Poster,
    %        StageRoot (char) and ClearStage (logical).

    % Define anon functions

    % True for a char row vector, an empty char or a string scalar
    isTextScalar = @(x) (ischar(x) && (isrow(x) || isequal(size(x),[0 0]))) || (isstring(x) && isscalar(x));

    % True if x is a char row vector or string scalar with at least one character.
    isNonEmptyText = @(x) ((ischar(x) && isrow(x)) || (isstring(x) && isscalar(x))) && strlength(x)>0;

    % true if x is a logical scalar or a real, non-NaN numeric scalar.
    isLogicalScalar = @(x) isscalar(x) && (islogical(x) || (isnumeric(x) && isreal(x) && ~isnan(x)));


    params = inputParser;
    params.FunctionName = 'webpreview.updateSectionImage';
    params.CaseSensitive = false;

    params.addParameter('ConfigFile', '', isTextScalar) % empty means the default location
    params.addParameter('Montage', [], @isnumeric)
    params.addParameter('Range', [], @isnumeric)
    params.addParameter('Poster', @webpreview.zipAndPost, ...
                        @(x) isa(x,'function_handle') && isscalar(x))
    params.addParameter('StageRoot', tempdir, isNonEmptyText)
    params.addParameter('ClearStage', false, isLogicalScalar)
    params.parse(varargin{:});

    opts = params.Results;

    % Text options may arrive as strings; everything downstream uses char paths
    opts.ConfigFile = char(opts.ConfigFile);
    opts.StageRoot = char(opts.StageRoot);
    opts.ClearStage = logical(opts.ClearStage);
end % parseOptions




function post = callPoster(poster,stageDir,cfg)
    % Call the poster and check that its reply has the expected form
    %
    % function post = BakingTray.webpreview.updateSectionImage>callPoster(poster,stageDir,cfg)
    %
    % Purpose
    % A poster that throws propagates to the catch in updateSectionImage. Errors with
    % 'webpreview:updateSectionImage:badReply' if the reply is not a scalar structure with
    % the fields ok (logical scalar), httpStatus and message (char).
    %
    % Inputs
    % poster   - Function handle, poster(stageDir,cfg), as for the 'Poster' option.
    % stageDir - Char path to the folder to upload.
    % cfg      - webpreview.webConfig object.
    %
    % Outputs
    % post - The poster's reply: structure with fields ok, httpStatus and message.

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
end % callPoster


function result = finalise(result,caught,cfg)
    % Scrub the token from the message and fill result.error for every kind of failure
    %
    % function result = BakingTray.webpreview.updateSectionImage>finalise(result,caught,cfg)
    %
    % Purpose
    % The error reported is, in order of preference, the error caught by updateSectionImage,
    % then result.error set by runPipeline, then a 'webpreview:updateSectionImage:postFailed'
    % error built from the poster's message. On success only result.post.message is scrubbed.
    % The reported error is rebuilt from the scrubbed text and its message is copied to
    % result.post.message.
    %
    % Inputs
    % result - Result structure as left by runPipeline (or emptyResult if it was not reached).
    % caught - MException caught by updateSectionImage, or [] if there was none.
    % cfg    - webpreview.webConfig object used to scrub the token from messages, or [] if
    %          the config was not loaded.
    %
    % Outputs
    % result - The input with a scrubbed post.message, and error set if ok is false.

    result.post.message = scrubMessage(result.post.message,cfg);
    if ~isempty(caught)
        err = caught;
    elseif ~result.ok && ~isempty(result.error)
        err = result.error;
    elseif ~result.ok
        err = MException('webpreview:updateSectionImage:postFailed','%s',result.post.message);
    else
        return
    end

    result.post.message = scrubMessage(err.message,cfg);
    result.error = scrubbedException(err.identifier,result.post.message);
end % finalise


function msg = scrubMessage(msg,cfg)
    % Remove the token from a message, if there is a config object to say what it is
    %
    % function msg = BakingTray.webpreview.updateSectionImage>scrubMessage(msg,cfg)
    %
    % Purpose
    % If the config could not be loaded no token is known. Errors from loading the config
    % have already been scrubbed by webpreview.webConfig.
    %
    % Inputs
    % msg - Message text.
    % cfg - webpreview.webConfig object, or [] if the config was not loaded.
    %
    % Outputs
    % msg - The message with the token replaced by '***' if cfg is a config object,
    %       otherwise the input.

    if isa(cfg,'webpreview.webConfig')
        msg = cfg.scrub(msg);
    end
end % scrubMessage


function ex = scrubbedException(id,message)
    % Make an MException from an identifier and an already-scrubbed message
    %
    % function ex = BakingTray.webpreview.updateSectionImage>scrubbedException(id,message)
    %
    % Purpose
    % An existing MException keeps its original message, so a scrubbed one has to be rebuilt
    % from the scrubbed text. A third-party error can carry an identifier that MException
    % rejects; in that case 'webpreview:updateSectionImage:unidentified' is used instead of
    % throwing.
    %
    % Inputs
    % id      - Identifier of the original error.
    % message - Message text with the token already removed.
    %
    % Outputs
    % ex - MException with the given identifier (or the fallback) and message.

    fallback = 'webpreview:updateSectionImage:unidentified';
    try
        ex = MException(id,'%s',message);
    catch
        ex = MException(fallback,'%s',message);
    end
end % scrubbedException


function notify(result)
    % Issue at most one warning describing a failed or stale upload
    %
    % function BakingTray.webpreview.updateSectionImage>notify(result)
    %
    % Purpose
    % Warns 'webpreview:updateSectionImage:failed' if result.ok is false. If the upload
    % worked but result.stale is true, warns 'webpreview:updateSectionImage:stale'. If both
    % apply the failed warning is issued, with the names of the stale files added to its
    % text. stageFiles may already have issued its own warnings. The warning call is
    % guarded because with warning('error',...) in force it throws, and that must not
    % escape.
    %
    % Inputs
    % result - Result structure returned by updateSectionImage.

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
end % notify


function names = staleNames(result)
    % Describe which of the recipe and log were not refreshed
    %
    % function names = BakingTray.webpreview.updateSectionImage>staleNames(result)
    %
    % Inputs
    % result - Result structure with the logical fields recipeFresh and logFresh.
    %
    % Outputs
    % names - 'recipe', 'acq log' or 'recipe and acq log'. '' if both are fresh.

    parts = {};
    if ~result.recipeFresh
        parts{end+1} = 'recipe';
    end
    if ~result.logFresh
        parts{end+1} = 'acq log';
    end
    names = strjoin(parts,' and ');
end % staleNames


function result = emptyResult
    % The result structure as it stands before anything has been done
    %
    % function result = BakingTray.webpreview.updateSectionImage>emptyResult
    %
    % Outputs
    % result - Structure with the fields documented in updateSectionImage, set to their
    %          "nothing happened" values: ok false, stage [], post.ok false with
    %          post.httpStatus NaN and an empty post.message, stageDir '', recipeFresh,
    %          logFresh and stale false, and error [].

    result = struct('ok', false, 'stage', [], ...
        'post', struct('ok',false,'httpStatus',NaN,'message',''), ...
        'stageDir', '', 'recipeFresh', false, 'logFresh', false, 'stale', false, ...
        'error', []);
end % emptyResult
