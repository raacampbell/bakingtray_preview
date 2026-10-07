function result = stageFiles(img,recipePath,logPath,stageDir,varargin)
    % Assemble the files for one web-preview upload in stageDir
    %
    % function result = BakingTray.webpreview.stageFiles(img,recipePath,logPath,stageDir,'Param1',val1,...)
    %
    % Purpose
    % Files written (names from webpreview.stageSpec, chosen to match the server's
    % globs in brainsaw/lib.php):
    %   LastCompleteSection.jpg   from img
    %   montage.jpg               from the 'Montage' image, if given
    %   recipe.yml / recipe.yaml  copy of the recipe (extension follows the source)
    %   acqLog.txt                copy of the log
    %
    % recipePath may be a file or a folder; for a folder the newest file matching the
    % server's recipe glob (*ecipe*.y*ml) is used.
    %
    % Image conversion (classes, autoscaling, 'Range') is documented in
    % webpreview.toUint8. Invalid images or Range throw, before stageDir is touched.
    %
    % FAILURE POLICY: a preview must never abort an acquisition, so
    %  - a recipe or log that is missing, not a path, or fails to copy only WARNS; the
    %    previously staged recipe/log (if any) is kept, because a kind of file is only
    %    replaced when its new version was obtained;
    %  - a source inside stageDir under a name other than the staged one is skipped
    %    with a warning, so no source is ever deleted;
    %  - file-system failures while staging (cannot create or write stageDir, cannot
    %    rename files) warn 'webpreview:stageFiles:stageFailed' and set
    %    result.stageOk = false; the stage may then be incomplete.
    %
    % FILE HANDLING: new files are written under '.part' names (matched by no server
    % glob) and then renamed into place, so a zip taken meanwhile does not see a
    % half-written file. The four names <staged name>.part (for example
    % LastCompleteSection.jpg.part) are reserved for this and are deleted when the call
    % ends; other '.part' files are left alone. Sources are only read. Hidden files
    % (leading '.') are never touched.
    %
    % PARTIAL STATES: each kind of file is renamed into place on its own, and only after
    % its rename succeeds are stale files of other names that the server would match
    % deleted. If a later step fails the stage can therefore hold a mix of new and old
    % files; stageOk is false, a stageFailed warning is issued, and files / *Staged
    % describe exactly what was renamed into place. A stale file that cannot be deleted
    % (locked, read-only) also sets stageOk false, since the server would pick it up.
    %
    % Inputs
    % img        - Numeric HxW or HxWx3 image of the section (see webpreview.toUint8).
    % recipePath - Path to the recipe file or to a folder containing it.
    % logPath    - Path to the acquisition log file.
    % stageDir   - Non-empty text scalar. Folder to assemble the files in. Created if
    %              absent.
    %
    % Inputs (optional param/val pairs)
    % 'Montage' - Numeric montage image to stage as montage.jpg. Default is [] (none).
    % 'Range'   - Numeric [lo hi] used to scale both images. Default is [] (see
    %             webpreview.toUint8).
    %
    % Outputs
    % result - Structure with fields:
    %   files         - full paths renamed into place.
    %   montageStaged - logical.
    %   recipeStaged  - logical.
    %   logStaged     - logical.
    %   recipeSource  - path of the recipe used, or ''.
    %   stageOk       - logical.
    %
    % See also: webpreview.toUint8, webpreview.stageSpec, webpreview.updateSectionImage


    narginchk(4,Inf)

    isText = (ischar(stageDir) && isrow(stageDir)) || (isstring(stageDir) && isscalar(stageDir));
    if ~isText || ~(strlength(stageDir)>0)
        error('webpreview:stageFiles:badStageDir', ...
            'stageDir must be a non-empty text scalar.')
    end
    stageDir = char(stageDir);

    params = inputParser;
    params.FunctionName = 'webpreview.stageFiles';
    params.CaseSensitive = false;
    params.addParameter('Montage', [], @isnumeric)
    params.addParameter('Range', [], @isnumeric)
    params.parse(varargin{:});
    montage = params.Results.Montage;
    range = params.Results.Range;


    % Pure conversion first: programming errors throw here, before any I/O.
    mainImg = webpreview.toUint8(img,range);
    montageImg = [];
    if ~isempty(montage)
        montageImg = webpreview.toUint8(montage,range);
    end

    result = struct('files', {{}}, 'montageStaged', false, 'recipeStaged', false, ...
                    'logStaged', false, 'recipeSource', '', 'stageOk', true);
    try
        result = stageOnDisk(result,mainImg,montageImg,recipePath,logPath,stageDir);
    catch ME
        % Only failures raised by our own file-system wrappers are tolerated
        if ~strcmp(ME.identifier,'webpreview:stageFiles:ioFailure')
            rethrow(ME);
        end
        warning('webpreview:stageFiles:stageFailed', ...
            'Staging in "%s" failed: %s', stageDir, ME.message)
        result.stageOk = false;
    end %try
end


function result = stageOnDisk(result,mainImg,montageImg,recipePath,logPath,stageDir)
    % Write the part files, rename them into place and clear stale files
    spec = webpreview.stageSpec;
    hasMontage = ~isempty(montageImg);

    ensureFolder(stageDir)
    stageAbs = canonicalPath(stageDir);


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Resolve sources before anything is deleted
    [recipeFile,recipeProblem] = resolveRecipe(recipePath,spec.Globs.Recipe);
    recipeName = [spec.Names.RecipeBase recipeExtension(recipeFile)];
    [recipeFile,recipeProblem] = rejectSourceInStage(recipeFile,recipeProblem,recipeName,stageAbs);
    if ~isempty(recipeProblem)
        warning('webpreview:stageFiles:missingRecipe', ...
            'Recipe not staged (%s); keeping any previous recipe.', recipeProblem)
    end

    [logFile,logProblem] = resolveLog(logPath);
    [logFile,logProblem] = rejectSourceInStage(logFile,logProblem,spec.Names.Log,stageAbs);
    if ~isempty(logProblem)
        warning('webpreview:stageFiles:missingLog', ...
            'Acq log not staged (%s); keeping any previous log.', logProblem)
    end


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Delete only the in-progress files this call can create
    partNames = {spec.Names.Main, spec.Names.Montage, recipeName, spec.Names.Log};
    partPaths = fullfile(stageAbs,strcat(partNames,spec.PartSuffix));
    cleanup = onCleanup(@() deleteFiles(partPaths)); %#ok<NASGU>

    parts = struct('kind', {}, 'final', {}, 'part', {}, 'glob', {});
    parts = [parts, writeImagePart(mainImg,'main',spec.Names.Main,spec.Globs.Main,stageAbs,spec)];
    if hasMontage
        parts = [parts, writeImagePart(montageImg,'montage',spec.Names.Montage, ...
                                       spec.Globs.Montage,stageAbs,spec)];
    end
    recipePart = copyPart(recipeFile,'recipe',recipeName,spec.Globs.Recipe,stageAbs,spec);
    logPart = copyPart(logFile,'log',spec.Names.Log,spec.Globs.Log,stageAbs,spec);
    parts = [parts, recipePart, logPart];


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    [committed,failures] = commitParts(parts,stageAbs);
    if ~hasMontage
        % A dropped montage is stale
        stale = removeMatching(stageAbs,spec.Globs.Montage,'');
        failures = [failures, staleFailure(stale)];
    end

    kinds = {committed.kind};
    result.files = {committed.path};
    result.montageStaged = any(strcmp(kinds,'montage'));
    result.recipeStaged = any(strcmp(kinds,'recipe'));
    result.logStaged = any(strcmp(kinds,'log'));
    if result.recipeStaged
        result.recipeSource = recipeFile;
    end

    if ~isempty(failures)
        result.stageOk = false;
        warning('webpreview:stageFiles:stageFailed', ...
            'Staging in "%s" incomplete: %s', stageDir, strjoin(failures,'; '))
    end
end


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Sources

function ext = recipeExtension(file)
    % '.yaml' if the source says so, otherwise '.yml'; both match the server glob
    ext = '.yml';
    if ~isempty(file)
        [~,~,thisExt] = fileparts(file);
        if strcmpi(thisExt,'.yaml')
            ext = '.yaml';
        end
    end
end


function tf = isTextPath(p)
    tf = (ischar(p) && isrow(p) && ~isempty(p)) || (isstring(p) && isscalar(p) && strlength(p)>0);
end


function [file,problem] = resolveRecipe(recipePath,glob)
    % File to copy as the recipe, or '' plus a human-readable problem
    file = '';
    problem = '';
    if ~isTextPath(recipePath)
        problem = 'recipePath is not a non-empty text path';
        return
    end

    recipePath = char(recipePath);
    if isfile(recipePath)
        file = recipePath;
    elseif isfolder(recipePath)
        names = listMatching(recipePath,glob);
        if isempty(names)
            problem = sprintf('folder "%s" contains no file matching %s', recipePath, glob);
        else
            file = newestIn(recipePath,names);
        end
    else
        problem = sprintf('path "%s" does not exist', recipePath);
    end
end


function [file,problem] = resolveLog(logPath)
    file = '';
    problem = '';
    if ~isTextPath(logPath)
        problem = 'logPath is not a non-empty text path';
    elseif isfile(char(logPath))
        file = char(logPath);
    else
        problem = sprintf('"%s" is not an existing file', char(logPath));
    end
end


function [file,problem] = rejectSourceInStage(file,problem,targetName,stageAbs)
    % A source inside stageDir is only safe if replacing it by its own staged copy
    % (same name); otherwise clearing stale files could delete it.
    if isempty(file)
        return
    end

    [folder,name,ext] = fileparts(canonicalPath(file));
    if samePath(folder,stageAbs) && ~samePath([name ext],targetName)
        problem = sprintf('source "%s" lies inside the stage folder under a different name', file);
        file = '';
    end
end


function file = newestIn(folder,names)
    % Newest by modification time; ties broken by name for determinism
    d = cellfun(@(n) dir(fullfile(folder,n)), names);
    [~,order] = sortrows([-[d.datenum]' (1:numel(d))']);
    file = fullfile(folder,names{order(1)});
end


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Paths

function p = canonicalPath(p)
    % Absolute path; with the JVM also with symlinks (and, on case-insensitive
    % systems, case) resolved. Without the JVM, or if resolution fails, the fileattrib
    % result is used, so two spellings of one folder may then compare unequal.
    [ok,info] = fileattrib(p);
    if ok
        p = info.Name;
    end

    if usejava('jvm')
        try
            f = java.io.File(p);
            if ~f.isAbsolute()
                f = java.io.File(fullfile(pwd,p)); % Java would resolve against its own cwd
            end
            p = char(f.getCanonicalPath());
        catch ME
            if ~strcmp(ME.identifier,'MATLAB:Java:GenericException')
                rethrow(ME); % only a java.io.IOException is tolerated
            end
        end %try
    end
end


function tf = samePath(a,b)
    % File systems on Windows and macOS are case-insensitive by default
    if ispc || ismac
        tf = strcmpi(a,b);
    else
        tf = strcmp(a,b);
    end
end


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Listing and deleting

function names = listMatching(folder,glob)
    % Names of regular files in folder matching a server glob
    d = dir(folder);
    d = d(~[d.isdir]);
    names = {d.name};
    names = names(~cellfun(@isempty, regexp(names,webpreview.globToRegexp(glob),'once')));
end


function remaining = removeMatching(folder,glob,keepName)
    % Delete matching files other than keepName; return those still present afterwards
    % (delete only warns on locked or read-only files).
    remaining = {};
    for thisName = listMatching(folder,glob)
        if ~samePath(thisName{1},keepName)
            delete(fullfile(folder,thisName{1}));
            if isfile(fullfile(folder,thisName{1}))
                remaining{end+1} = thisName{1}; %#ok<AGROW>
            end
        end
    end %for
end


function f = staleFailure(remaining)
    f = {};
    if ~isempty(remaining)
        f = {sprintf('could not delete stale file(s): %s', strjoin(remaining,', '))};
    end
end


function deleteFiles(paths)
    for kk = 1:numel(paths)
        if isfile(paths{kk})
            delete(paths{kk});
        end
    end
end


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% File-system writes: every failure is reported as ioFailure

function ensureFolder(folder)
    if isfolder(folder)
        return
    end

    [ok,msg] = mkdir(folder);
    if ~ok
        throwIo('create folder "%s": %s', folder, msg)
    end
end


function p = writeImagePart(img8,kind,finalName,glob,stageAbs,spec)
    part = fullfile(stageAbs,[finalName spec.PartSuffix]);
    try
        % Explicit format: '.part' is not an image extension
        imwrite(img8,part,'jpg','Quality',spec.JpegQuality);
    catch ME
        throwIo('write "%s": %s', part, ME.message)
    end
    p = struct('kind', kind, 'final', finalName, 'part', part, 'glob', glob);
end


function p = copyPart(src,kind,finalName,glob,stageAbs,spec)
    % Copy a source to a temporary name. A failed copy warns and returns [] so the
    % previous staged copy survives; it is not a stage failure.
    p = [];
    if isempty(src)
        return
    end

    part = fullfile(stageAbs,[finalName spec.PartSuffix]);
    try
        [ok,msg] = copyfile(src,part,'f');
    catch ME
        ok = false;
        msg = ME.message;
    end

    if ~ok
        warning('webpreview:stageFiles:copyFailed', ...
            'Could not copy "%s": %s; keeping any previous staged copy.', src, msg)
        return
    end
    p = struct('kind', kind, 'final', finalName, 'part', part, 'glob', glob);
end


function [committed,failures] = commitParts(parts,stageAbs)
    % Rename each part over its final name (the same-named old file is never
    % pre-deleted, so a failed rename leaves it intact), and only then delete stale
    % files of other names. Returns what was actually renamed into place.
    committed = struct('kind', {}, 'path', {});
    failures = {};
    for kk = 1:numel(parts)
        final = fullfile(stageAbs,parts(kk).final);
        [ok,msg] = movefile(parts(kk).part,final,'f');
        if ~ok
            failures{end+1} = sprintf('could not rename "%s" to "%s": %s', ...
                                parts(kk).part, final, msg); %#ok<AGROW>
            continue
        end
        committed(end+1) = struct('kind', parts(kk).kind, 'path', final); %#ok<AGROW>
        stale = removeMatching(stageAbs,parts(kk).glob,parts(kk).final);
        failures = [failures, staleFailure(stale)]; %#ok<AGROW>
    end %for
end


function throwIo(fmt,varargin)
    error('webpreview:stageFiles:ioFailure',fmt,varargin{:})
end
