function result = stageFiles(img,recipePath,logPath,stageDir,varargin)
    % Assemble the files for one web-preview upload in stageDir
    %
    % function result = BakingTray.webpreview.stageFiles(img,recipePath,logPath,stageDir,'Param1',val1,...)
    %
    % Purpose
    % Files written (names from BakingTray.webpreview.stageSpec, chosen to match the server's
    % globs in brainsaw/lib.php):
    %   LastCompleteSection.jpg   from img
    %   montage.jpg               from the 'Montage' image, if given
    %   recipe.yml                copy of the recipe, whatever the source extension
    %   acqLog.txt                copy of the log
    %
    % recipePath may be a file or a folder; for a folder the newest file matching the
    % server's recipe glob (*ecipe*.y*ml) is used.
    %
    % Image conversion (classes, autoscaling, 'Range') is documented in
    % BakingTray.webpreview.toUint8. Invalid images or Range throw, before stageDir is touched.
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
    % img        - Numeric HxW or HxWx3 image of the section (see BakingTray.webpreview.toUint8).
    % recipePath - Path to the recipe file or to a folder containing it.
    % logPath    - Path to the acquisition log file.
    % stageDir   - Non-empty text scalar. Folder to assemble the files in. Created if
    %              absent.
    %
    % Inputs (optional param/val pairs)
    % 'Montage' - Numeric montage image to stage as montage.jpg. Default is [] (none).
    % 'Range'   - Numeric [lo hi] used to scale both images. Default is [] (see
    %             BakingTray.webpreview.toUint8).
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
    % See also: BakingTray.webpreview.toUint8, BakingTray.webpreview.stageSpec, BakingTray.webpreview.updateSectionImage


    narginchk(4,Inf)

    isText = (ischar(stageDir) && isrow(stageDir)) || (isstring(stageDir) && isscalar(stageDir));
    if ~isText || ~(strlength(stageDir)>0)
        error('webpreview:stageFiles:badStageDir', ...
            'stageDir must be a non-empty text scalar.')
    end
    stageDir = char(stageDir);

    params = inputParser;
    params.FunctionName = 'BakingTray.webpreview.stageFiles';
    params.CaseSensitive = false;
    params.addParameter('Montage', [], @isnumeric)
    params.addParameter('Range', [], @isnumeric)
    params.parse(varargin{:});
    montage = params.Results.Montage;
    range = params.Results.Range;


    % Pure conversion first: programming errors throw here, before any I/O.
    mainImg = BakingTray.webpreview.toUint8(img,range);
    montageImg = [];
    if ~isempty(montage)
        montageImg = BakingTray.webpreview.toUint8(montage,range);
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
end % stageFiles


function result = stageOnDisk(result,mainImg,montageImg,recipePath,logPath,stageDir)
    % Write the part files, rename them into place and clear stale files
    %
    % function result = BakingTray.webpreview.stageFiles>stageOnDisk(result,mainImg,montageImg,recipePath,logPath,stageDir)
    %
    % Purpose
    % The file-system half of stageFiles. Resolves the recipe and log sources first, before
    % anything is deleted; an unusable source only warns and the previously staged copy is
    % kept. Then writes the images and copies the sources under '.part' names, renames each
    % into place (commitParts) and deletes stale files of other names that the server
    % would match. If a montage was not given, any previously staged montage is stale and
    % is deleted.
    %
    % File-system failures in ensureFolder and writeImagePart are thrown as
    % 'webpreview:stageFiles:ioFailure' and handled by stageFiles. Failures to rename or to
    % delete stale files warn 'webpreview:stageFiles:stageFailed' and set result.stageOk to
    % false.
    %
    % Inputs
    % result     - Result structure from stageFiles, to be filled in.
    % mainImg    - uint8 image to write as the main image.
    % montageImg - uint8 montage image, or [] for no montage.
    % recipePath - Path to the recipe file or to a folder containing it.
    % logPath    - Path to the acquisition log file.
    % stageDir   - Char path to the stage folder. Created if absent.
    %
    % Outputs
    % result - The input with files, montageStaged, recipeStaged, logStaged and
    %          recipeSource filled in, and stageOk set to false if anything failed.

    spec = BakingTray.webpreview.stageSpec;
    hasMontage = ~isempty(montageImg);

    ensureFolder(stageDir)
    stageAbs = canonicalPath(stageDir);


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Resolve sources before anything is deleted
    [recipeFile,recipeProblem] = resolveRecipe(recipePath,spec.Globs.Recipe);
    recipeName = spec.Names.Recipe;
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
end % stageOnDisk


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Sources

function tf = isTextPath(p)
    % True for a non-empty char row vector or a non-empty string scalar
    %
    % function tf = BakingTray.webpreview.stageFiles>isTextPath(p)
    %
    % Inputs
    % p - Any value.
    %
    % Outputs
    % tf - true if p can be used as a path, i.e. it is text with at least one character.

    tf = (ischar(p) && isrow(p) && ~isempty(p)) || (isstring(p) && isscalar(p) && strlength(p)>0);
end % isTextPath


function [file,problem] = resolveRecipe(recipePath,glob)
    % Work out which file to copy as the recipe
    %
    % function [file,problem] = BakingTray.webpreview.stageFiles>resolveRecipe(recipePath,glob)
    %
    % Purpose
    % If recipePath is a file it is used as is. If it is a folder, the newest file in it
    % matching glob is used (see newestIn). If no file is found the reason is returned in
    % problem rather than thrown.
    %
    % Inputs
    % recipePath - Path to a recipe file or to a folder containing one.
    % glob       - Server glob for recipe files, used when recipePath is a folder.
    %
    % Outputs
    % file    - Path of the recipe to copy, or '' if none was found.
    % problem - Human-readable reason if file is empty, otherwise ''.

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
end % resolveRecipe


function [file,problem] = resolveLog(logPath)
    % Check that the acquisition log exists
    %
    % function [file,problem] = BakingTray.webpreview.stageFiles>resolveLog(logPath)
    %
    % Purpose
    % Unlike resolveRecipe, logPath must be a file; a folder is not accepted. A problem is
    % returned rather than thrown.
    %
    % Inputs
    % logPath - Path to the acquisition log file.
    %
    % Outputs
    % file    - Char path of the log to copy, or '' if it is unusable.
    % problem - Human-readable reason if file is empty, otherwise ''.

    file = '';
    problem = '';
    if ~isTextPath(logPath)
        problem = 'logPath is not a non-empty text path';
    elseif isfile(char(logPath))
        file = char(logPath);
    else
        problem = sprintf('"%s" is not an existing file', char(logPath));
    end
end % resolveLog


function [file,problem] = rejectSourceInStage(file,problem,targetName,stageAbs)
    % Refuse a source file that lies inside the stage folder under the wrong name
    %
    % function [file,problem] = BakingTray.webpreview.stageFiles>rejectSourceInStage(file,problem,targetName,stageAbs)
    %
    % Purpose
    % A source inside the stage folder is only safe if it has the same name as the staged
    % copy that will replace it. Otherwise deleting stale files could delete the source.
    % Such a source is dropped and the reason is returned in problem.
    %
    % Inputs
    % file       - Path of the source from resolveRecipe or resolveLog. May be ''.
    % problem    - The problem reported by that function. Passed through if file is accepted.
    % targetName - Name the source will have once staged.
    % stageAbs   - Canonical path of the stage folder (see canonicalPath).
    %
    % Outputs
    % file    - The input file, or '' if it was rejected.
    % problem - The input problem, or a description of why file was rejected.

    if isempty(file)
        return
    end

    [folder,name,ext] = fileparts(canonicalPath(file));
    if samePath(folder,stageAbs) && ~samePath([name ext],targetName)
        problem = sprintf('source "%s" lies inside the stage folder under a different name', file);
        file = '';
    end
end % rejectSourceInStage


function file = newestIn(folder,names)
    % Full path of the most recently modified file out of those named
    %
    % function file = BakingTray.webpreview.stageFiles>newestIn(folder,names)
    %
    % Purpose
    % Files with the same modification time are ordered as they appear in names, so the
    % result is deterministic.
    %
    % Inputs
    % folder - Folder holding the files.
    % names  - Non-empty cell row of file names in folder.
    %
    % Outputs
    % file - Full path of the newest file.

    d = cellfun(@(n) dir(fullfile(folder,n)), names);
    [~,order] = sortrows([-[d.datenum]' (1:numel(d))']);
    file = fullfile(folder,names{order(1)});
end % newestIn


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Paths

function p = canonicalPath(p)
    % Absolute path with symlinks resolved where possible
    %
    % function p = BakingTray.webpreview.stageFiles>canonicalPath(p)
    %
    % Purpose
    % With the JVM the path also has symlinks (and, on case-insensitive systems, case)
    % resolved. Without the JVM, or if resolution fails, the fileattrib result is used, so
    % two spellings of one folder may then compare unequal. Only a java.io.IOException is
    % tolerated; any other error is rethrown.
    %
    % Inputs
    % p - Path to an existing file or folder.
    %
    % Outputs
    % p - The canonical path.

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
end % canonicalPath


function tf = samePath(a,b)
    % True if two names or paths are the same, using the platform's case rules
    %
    % function tf = BakingTray.webpreview.stageFiles>samePath(a,b)
    %
    % Purpose
    % File systems on Windows and macOS are case-insensitive by default, so the comparison
    % ignores case there and is case-sensitive elsewhere. Does not resolve paths: use
    % canonicalPath first if needed.
    %
    % Inputs
    % a, b - Char row vectors to compare.
    %
    % Outputs
    % tf - true if a and b match.

    if ispc || ismac
        tf = strcmpi(a,b);
    else
        tf = strcmp(a,b);
    end
end % samePath


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% Listing and deleting

function names = listMatching(folder,glob)
    % Names of regular files in a folder that match a server glob
    %
    % function names = BakingTray.webpreview.stageFiles>listMatching(folder,glob)
    %
    % Inputs
    % folder - Folder to list.
    % glob   - Server glob pattern, translated with BakingTray.webpreview.globToRegexp.
    %
    % Outputs
    % names - Cell row of file names (not paths). Subfolders are not included. Empty if
    %         nothing matches.

    d = dir(folder);
    d = d(~[d.isdir]);
    names = {d.name};
    names = names(~cellfun(@isempty, regexp(names,BakingTray.webpreview.globToRegexp(glob),'once')));
end % listMatching


function remaining = removeMatching(folder,glob,keepName)
    % Delete files matching a server glob, except one, and report any that survive
    %
    % function remaining = BakingTray.webpreview.stageFiles>removeMatching(folder,glob,keepName)
    %
    % Purpose
    % Used to delete stale files that the server would otherwise pick up. delete only warns
    % on locked or read-only files, so each file is checked afterwards.
    %
    % Inputs
    % folder   - Folder to clear.
    % glob     - Server glob pattern for the files to delete.
    % keepName - Name of the file to leave alone (compared with samePath). Use '' to keep
    %            nothing.
    %
    % Outputs
    % remaining - Cell array of the names that matched but were still present after the
    %             delete. Empty if all were removed.

    remaining = {};
    for thisName = listMatching(folder,glob)
        if ~samePath(thisName{1},keepName)
            delete(fullfile(folder,thisName{1}));
            if isfile(fullfile(folder,thisName{1}))
                remaining{end+1} = thisName{1}; %#ok<AGROW>
            end
        end
    end %for
end % removeMatching


function f = staleFailure(remaining)
    % Turn a list of undeletable stale files into an entry for the failures list
    %
    % function f = BakingTray.webpreview.stageFiles>staleFailure(remaining)
    %
    % Inputs
    % remaining - Cell array of names returned by removeMatching.
    %
    % Outputs
    % f - Empty cell if remaining is empty, otherwise a cell holding one message that
    %     names the files.

    f = {};
    if ~isempty(remaining)
        f = {sprintf('could not delete stale file(s): %s', strjoin(remaining,', '))};
    end
end % staleFailure


function deleteFiles(paths)
    % Delete those of the given files that exist
    %
    % function BakingTray.webpreview.stageFiles>deleteFiles(paths)
    %
    % Inputs
    % paths - Cell array of full file paths.

    for kk = 1:numel(paths)
        if isfile(paths{kk})
            delete(paths{kk});
        end
    end
end % deleteFiles


% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
% File-system writes: every failure is reported as ioFailure

function ensureFolder(folder)
    % Create a folder if it does not exist
    %
    % function BakingTray.webpreview.stageFiles>ensureFolder(folder)
    %
    % Purpose
    % Errors with 'webpreview:stageFiles:ioFailure' (see throwIo) if it cannot be created.
    %
    % Inputs
    % folder - Char path of the folder.

    if isfolder(folder)
        return
    end

    [ok,msg] = mkdir(folder);
    if ~ok
        throwIo('create folder "%s": %s', folder, msg)
    end
end % ensureFolder


function p = writeImagePart(img8,kind,finalName,glob,stageAbs,spec)
    % Write a uint8 image as a JPEG under its '.part' name
    %
    % function p = BakingTray.webpreview.stageFiles>writeImagePart(img8,kind,finalName,glob,stageAbs,spec)
    %
    % Purpose
    % The file is renamed to finalName later by commitParts. Errors with
    % 'webpreview:stageFiles:ioFailure' (see throwIo) if the write fails.
    %
    % Inputs
    % img8      - uint8 image to write.
    % kind      - 'main' or 'montage'.
    % finalName - Name the file will have once renamed into place.
    % glob      - Server glob matching stale versions of this file.
    % stageAbs  - Canonical path of the stage folder.
    % spec      - Structure from BakingTray.webpreview.stageSpec.
    %
    % Outputs
    % p - Structure with fields kind, final, part (full path written) and glob, as used
    %     by commitParts.

    part = fullfile(stageAbs,[finalName spec.PartSuffix]);
    try
        % Explicit format: '.part' is not an image extension
        imwrite(img8,part,'jpg','Quality',spec.JpegQuality);
    catch ME
        throwIo('write "%s": %s', part, ME.message)
    end
    p = struct('kind', kind, 'final', finalName, 'part', part, 'glob', glob);
end % writeImagePart


function p = copyPart(src,kind,finalName,glob,stageAbs,spec)
    % Copy a source file to its '.part' name
    %
    % function p = BakingTray.webpreview.stageFiles>copyPart(src,kind,finalName,glob,stageAbs,spec)
    %
    % Purpose
    % The file is renamed to finalName later by commitParts. A failed copy warns
    % 'webpreview:stageFiles:copyFailed' and returns [] so the previous staged copy
    % survives; it is not a stage failure.
    %
    % Inputs
    % src       - Path of the file to copy, or '' if there is nothing to copy.
    % kind      - 'recipe' or 'log'.
    % finalName - Name the file will have once renamed into place.
    % glob      - Server glob matching stale versions of this file.
    % stageAbs  - Canonical path of the stage folder.
    % spec      - Structure from BakingTray.webpreview.stageSpec.
    %
    % Outputs
    % p - Structure with fields kind, final, part (full path written) and glob, as used
    %     by commitParts. [] if src was empty or the copy failed.

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
end % copyPart


function [committed,failures] = commitParts(parts,stageAbs)
    % Rename each part file over its final name, then delete stale files of other names
    %
    % function [committed,failures] = BakingTray.webpreview.stageFiles>commitParts(parts,stageAbs)
    %
    % Purpose
    % The same-named old file is never deleted beforehand, so a failed rename leaves it
    % intact. Stale files matching the part's glob under other names are deleted only after
    % that part has been renamed successfully.
    %
    % Inputs
    % parts    - Structure array from writeImagePart and copyPart, with fields kind, final,
    %            part and glob. May be empty.
    % stageAbs - Canonical path of the stage folder.
    %
    % Outputs
    % committed - Structure array with fields kind and path, listing what was actually
    %             renamed into place.
    % failures  - Cell row of messages for renames that failed and for stale files that
    %             could not be deleted. Empty if all went well.

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
end % commitParts


function throwIo(fmt,varargin)
    % Raise the error that stageFiles treats as a tolerated file-system failure
    %
    % function BakingTray.webpreview.stageFiles>throwIo(fmt,varargin)
    %
    % Purpose
    % Always errors with 'webpreview:stageFiles:ioFailure'. stageFiles catches this one
    % identifier and turns it into a warning; any other error is rethrown.
    %
    % Inputs
    % fmt      - Format string for the message, as for sprintf.
    % varargin - Values for fmt.

    error('webpreview:stageFiles:ioFailure',fmt,varargin{:})
end % throwIo
