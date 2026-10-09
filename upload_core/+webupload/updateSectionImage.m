function result = updateSectionImage(img,recipePath,logPath,cfg,varargin)
    % Stage and upload the web preview for one section or run. Never throws
    %
    % function result = webupload.updateSectionImage(img,recipePath,logPath,cfg, ...
    %                                                 'Param1',val1,...)
    %
    % Purpose
    % The call that instrument and analysis code make to update the web preview: BakingTray
    % when it starts, after each section and when it finishes (source 'acq'), StitchIt for
    % its analysis (source 'analysis'). It stages the image (with its card thumbnail,
    % tile_thumbnail.jpg, see webupload.stageFiles), the optional 'Montage', the
    % recipe and the acquisition log with webupload.stageFiles, writes status.json, and
    % uploads the stage folder with webupload.zipAndPost. The microscope ID is SYSTEM.ID of
    % the recipe passed in (webupload.readRecipe). If it cannot be read, or is not a valid
    % ID, nothing is staged or uploaded and the call fails. The config is a
    % webupload.webConfig object that the caller builds once and passes in.
    %
    % img is [], a numeric array or the path of a jpg:
    %   []             - no image. Any image staged by an earlier call is deleted (after
    %                    the new files are in place, before the upload), so an old
    %                    sample's image can never go up with a new recipe. Use it for the
    %                    call at the start of a run, so the page shows the new recipe.
    %   numeric array  - converted with webupload.toUint8 (see 'Range').
    %   path of a jpg  - copied in as LastCompleteSection.jpg.
    % Anything else fails the call. 'Montage' takes the same kinds of value, but only with
    % Source 'analysis': with 'acq' the call fails and nothing is staged or sent.
    %
    % The stage folder is <StageRoot>/brainsaw_webpreview/<siteID>/<micID>/<source>, with
    % StageRoot defaulting to tempdir. It is reused between calls, so each call replaces
    % the previous files instead of accumulating them. The recipe is always staged afresh
    % from recipePath. If a new log cannot be staged, the previous copy stays and is
    % uploaded only if the previously staged recipe has the same sample ID as the new
    % one; otherwise no log is uploaded. Either way this is reported (see result.stale).
    % 'ClearStage',true empties the managed stage folder first, once the arguments have
    % been checked; to do that without uploading anything, use webupload.clearStage. On a
    % machine where tempdir is shared between users (Linux /tmp) pass a private folder
    % as 'StageRoot'.
    %
    % 'Finished',true marks the run as ended in status.json. The server answers HTTP 429
    % to an upload that follows another from the same site, microscope and source within
    % its minimum interval. A Finished call must not be lost, so it waits that interval
    % plus one second and tries once more; other calls are not retried. The interval is
    % this client's copy of the server setting (webupload.serverLimits); a site that
    % raises it will answer the retry with another 429, and the Finished flag is lost
    % (ok is false, with the usual warning).
    %
    % Deliberate catch-all: a section completing must never be interrupted by the
    % preview, so every failure inside the call (config, image or option problems,
    % staging, network, a throwing poster) is turned into a warning
    % 'webupload:updateSectionImage:failed' ("id: message") and result.ok = false. The
    % warning call itself is guarded, so warning('error',...) settings cannot make this
    % function throw. Errors in the arguments img, recipePath, logPath and cfg (which must
    % be a scalar, valid webConfig; a missing cfg is a failure too) are caught too, but a
    % path variable that does not exist in the CALLER is an error MATLAB raises before this
    % function runs, and cannot be caught here.
    %
    % TOKEN: webConfig keeps the token private. It is scrubbed from result and warning
    % messages, including those from a custom Poster, with webConfig.scrub.
    %
    % Inputs
    % img        - [], a numeric HxW or HxWx3 image of the section (see
    %              webupload.toUint8) or the path of a jpg.
    % recipePath - Path to the recipe file.
    % logPath    - Path to the acquisition log file.
    % cfg        - webupload.webConfig object.
    %
    % Inputs (optional param/val pairs)
    % 'Source'     - 'acq' (default) or 'analysis'.
    % 'Montage'    - Image to stage as montage.jpg, as for img. Only with Source
    %                'analysis'. Default is [].
    % 'Range'      - Numeric [lo hi] used to scale numeric images. Default is [].
    % 'Finished'   - Logical scalar written to status.json. Default is false.
    % 'ConnectTimeout', 'ResponseTimeout', 'DataTimeout' - Seconds. Passed to the upload
    %                for this call only, and again to the retry (see webupload.postZip).
    %                Default is the config values.
    % 'Poster'     - Function handle with the zipAndPost signature,
    %                poster(folder,cfg,micID,source,...) -> struct(ok,httpStatus,message) with
    %                char message, where cfg is a webupload.webConfig object. Default is
    %                @webupload.zipAndPost; tests inject a fake.
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
    %   stageDir    - '' if not reached; a char path built from StageRoot.
    %   recipeFresh - this call staged a new recipe. If not, nothing is uploaded.
    %   logFresh    - this call staged a new log.
    %   stale       - either of the above is false after staging. A notice
    %                 'webupload:updateSectionImage:stale' names the file when the
    %                 upload otherwise succeeded.
    %   error       - scrubbed MException; [] on success.
    %
    % See also: webupload.clearStage, webupload.stageFiles, webupload.zipAndPost


    result = struct('ok', false, 'stage', [], ...
        'post', struct('ok',false,'httpStatus',NaN,'message',''), ...
        'stageDir', '', 'recipeFresh', false, 'logFresh', false, 'stale', false, ...
        'error', []);
    caught = [];

    % From here on cfg is [] unless it is a usable config; finalise relies on that
    if nargin<4 || ~(isa(cfg,'webupload.webConfig') && isscalar(cfg) && isvalid(cfg))
        cfg = [];
    end

    try
        if isempty(cfg)
            error('webupload:updateSectionImage:badConfig', ...
                'cfg must be a webupload.webConfig object.')
        end

        % Parse the optional param/val pairs with the local function parseOptions
        opts = parseOptions(varargin{:});

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
    % function result = webupload.updateSectionImage>runPipeline(result,img,recipePath,logPath,cfg,opts)
    %
    % Purpose
    % The part of updateSectionImage that runs inside its try/catch. Refuses a montage
    % for source 'acq'. Reads the microscope ID from the recipe, builds the stage folder
    % path from cfg.siteID, the ID, opts.StageRoot and opts.Source (webupload.stageDirFor
    % checks the IDs, so they are safe as folder names), stages the files with
    % webupload.stageFiles (which empties the folder first if opts.ClearStage is true, but
    % only after checking the images), writes status.json and uploads the folder with
    % opts.Poster, once more after a 429 if opts.Finished.
    %
    % Anything that goes wrong before staging has finished is thrown and caught by
    % updateSectionImage. After that, failures are written to result.error instead, so the
    % stage information survives into the returned result. If staging did not complete,
    % or left no recipe (the server refuses an upload without one), nothing is uploaded.
    %
    % Inputs
    % result     - Result structure of updateSectionImage as it stands before anything
    %              has been done, to be filled in.
    % img        - [], a numeric image or the path of a jpg.
    % recipePath - Path to the recipe file.
    % logPath    - Path to the acquisition log file.
    % cfg        - webupload.webConfig object.
    % opts       - Options structure from parseOptions.
    %
    % Outputs
    % result - The input structure with stage, stageDir, recipeFresh, logFresh and stale
    %          filled in. post and ok are set once the poster has returned. error is set if
    %          staging was incomplete or the poster threw.

    noMontage = isa(opts.Montage,'double') && isequal(size(opts.Montage),[0 0]);
    if ~noMontage && ~strcmp(opts.Source,'analysis')
        error('webupload:updateSectionImage:montageNotAllowed', ...
            'A montage can only be sent with Source ''analysis'', not ''%s''.', opts.Source)
    end

    % Read from the source recipe, never from a copy left in the stage by an earlier call
    micID = webupload.readRecipe(char(recipePath));
    stageDir = webupload.stageDirFor(cfg,micID,opts.StageRoot,opts.Source);

    result.stage = webupload.stageFiles(img,recipePath,logPath,stageDir, ...
                        'Montage',opts.Montage,'Range',opts.Range,'ClearStage',opts.ClearStage);
    result.stageDir = stageDir;
    result.recipeFresh = result.stage.recipeStaged;
    result.logFresh = result.stage.logStaged;
    result.stale = ~(result.recipeFresh && result.logFresh);


    if ~result.stage.stageOk || ~result.recipeFresh
        % stageFiles has already warned with the cause; do not upload a partial stage
        result.error = MException('webupload:updateSectionImage:stageFailed', ...
            'staging in "%s" did not complete, nothing uploaded', stageDir);
        return
    end

    try
        webupload.writeStatus(stageDir,opts.Finished);
        result.post = callPoster(opts,stageDir,cfg,micID);
        if opts.Finished && isequal(result.post.httpStatus,429)
            pause(webupload.serverLimits().minUploadIntervalSec + 1)
            result.post = callPoster(opts,stageDir,cfg,micID);
        end
        result.ok = result.post.ok;
    catch err
        result.error = err;
    end %try
end % runPipeline


function opts = parseOptions(varargin)
    % Parse and validate the param/val options of updateSectionImage
    %
    % function opts = webupload.updateSectionImage>parseOptions(varargin)
    %
    % Purpose
    % Uses inputParser, so unknown names and values of the wrong type throw. Text options
    % may arrive as strings; they are converted to char because everything downstream uses
    % char paths. Montage is checked further by webupload.stageFiles.
    %
    % Inputs
    % varargin - The 'Param1',val1,... pairs documented in updateSectionImage.
    %
    % Outputs
    % opts - Structure with fields Source and StageRoot (char), Montage, Range, Finished
    %        and ClearStage (logical), Poster, and the timeouts given as PosterArgs: a
    %        cell row of 'Name',value pairs to append to the poster call.

    % True if x is a char row vector or string scalar with at least one character.
    isNonEmptyText = @(x) ((ischar(x) && isrow(x)) || (isstring(x) && isscalar(x))) && strlength(x)>0;

    % true if x is a logical scalar or a real, non-NaN numeric scalar.
    isLogicalScalar = @(x) isscalar(x) && (islogical(x) || (isnumeric(x) && isreal(x) && ~isnan(x)));

    % true if x is [] (not given) or a positive finite scalar number.
    isTimeout = @(x) isnumeric(x) && (isempty(x) || (isscalar(x) && isreal(x) && isfinite(x) && x>0));


    params = inputParser;
    params.FunctionName = 'webupload.updateSectionImage';
    params.CaseSensitive = false;

    params.addParameter('Source', 'acq', @(x) isNonEmptyText(x) && ismember(char(x),{'acq','analysis'}))
    params.addParameter('Montage', [], @(x) isnumeric(x) || ischar(x) || isstring(x))
    params.addParameter('Range', [], @isnumeric)
    params.addParameter('Finished', false, isLogicalScalar)
    params.addParameter('ConnectTimeout', [], isTimeout)
    params.addParameter('ResponseTimeout', [], isTimeout)
    params.addParameter('DataTimeout', [], isTimeout)
    params.addParameter('Poster', @webupload.zipAndPost, ...
                        @(x) isa(x,'function_handle') && isscalar(x))
    params.addParameter('StageRoot', tempdir, isNonEmptyText)
    params.addParameter('ClearStage', false, isLogicalScalar)
    params.parse(varargin{:});

    opts = params.Results;

    opts.Source = char(opts.Source);
    opts.StageRoot = char(opts.StageRoot);
    opts.Finished = logical(opts.Finished);
    opts.ClearStage = logical(opts.ClearStage);

    opts.PosterArgs = {};
    for name = {'ConnectTimeout','ResponseTimeout','DataTimeout'}
        if ~isempty(opts.(name{1}))
            opts.PosterArgs = [opts.PosterArgs, name, {opts.(name{1})}];
        end
    end %for
end % parseOptions


function post = callPoster(opts,stageDir,cfg,micID)
    % Call the poster and check that its reply has the expected form
    %
    % function post = webupload.updateSectionImage>callPoster(opts,stageDir,cfg,micID)
    %
    % Purpose
    % A poster that throws propagates to the catch in updateSectionImage. Errors with
    % 'webupload:updateSectionImage:badReply' if the reply is not a scalar structure with
    % the fields ok (logical scalar), httpStatus and message (char). The timeouts are
    % appended to the call only when the caller gave them.
    %
    % Inputs
    % opts     - Options structure from parseOptions: the Poster, Source and PosterArgs
    %            fields are used.
    % stageDir - Char path to the folder to upload.
    % cfg      - webupload.webConfig object.
    % micID    - Microscope ID read from the recipe.
    %
    % Outputs
    % post - The poster's reply: structure with fields ok, httpStatus and message.

    post = opts.Poster(stageDir,cfg,micID,opts.Source,opts.PosterArgs{:});
    wellFormed = isstruct(post) && isscalar(post) ...
                 && all(isfield(post,{'ok','httpStatus','message'})) ...
                 && islogical(post.ok) && isscalar(post.ok) ...
                 && ischar(post.message) && (isrow(post.message) || isempty(post.message));
    if ~wellFormed
        error('webupload:updateSectionImage:badReply', ...
            ['poster did not return struct(ok, httpStatus, message) ', ...
             'with logical ok and char message'])
    end
end % callPoster


function result = finalise(result,caught,cfg)
    % Scrub the token from the message and fill result.error for every kind of failure
    %
    % function result = webupload.updateSectionImage>finalise(result,caught,cfg)
    %
    % Purpose
    % The error reported is, in order of preference, the error caught by updateSectionImage,
    % then result.error set by runPipeline, then a 'webupload:updateSectionImage:postFailed'
    % error built from the poster's message. On success only result.post.message is scrubbed.
    % The reported error is rebuilt from the scrubbed text and its message is copied to
    % result.post.message.
    %
    % Inputs
    % result - Result structure as left by runPipeline (or its initial state if runPipeline was not reached).
    % caught - MException caught by updateSectionImage, or [] if there was none.
    % cfg    - webupload.webConfig used to scrub the token from messages, or [] if the
    %          caller did not supply a usable one.
    %
    % Outputs
    % result - The input with a scrubbed post.message, and error set if ok is false.

    if ~isempty(cfg)
        result.post.message = cfg.scrub(result.post.message);
    end
    if ~isempty(caught)
        err = caught;
    elseif ~result.ok && ~isempty(result.error)
        err = result.error;
    elseif ~result.ok
        err = MException('webupload:updateSectionImage:postFailed','%s',result.post.message);
    else
        return
    end

    result.post.message = err.message;
    if ~isempty(cfg)
        result.post.message = cfg.scrub(err.message);
    end
    % An existing MException keeps its original message, so rebuild it from the scrubbed text
    result.error = MException(err.identifier,'%s',result.post.message);
end % finalise


function notify(result)
    % Issue at most one warning describing a failed or stale upload
    %
    % function webupload.updateSectionImage>notify(result)
    %
    % Purpose
    % Warns 'webupload:updateSectionImage:failed' if result.ok is false. If the upload
    % worked but result.stale is true, warns 'webupload:updateSectionImage:stale'. If both
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
        id = 'webupload:updateSectionImage:failed';
        text = sprintf('Web preview not updated (%s: %s)', ...
                result.error.identifier, result.error.message);
    end

    if result.stale
        if isempty(id)
            id = 'webupload:updateSectionImage:stale';
            text = 'Web preview uploaded with stale metadata';
        end
        names = {};
        if ~result.recipeFresh
            names{end+1} = 'recipe';
        end
        if ~result.logFresh
            names{end+1} = 'acq log';
        end
        text = sprintf('%s; %s not refreshed for this section', text, strjoin(names,' and '));
        % The recipe is never kept, so only the log has a fallback to describe
        if result.ok
            if result.stage.logKept
                text = [text ' (the previously staged copy was uploaded)'];
            else
                text = [text ' (no log was uploaded)'];
            end
        end
    end

    if isempty(id)
        return
    end

    try
        warning(id,'%s',text)
    catch
        % Deliberately ignored, see above
    end %try
end % notify
