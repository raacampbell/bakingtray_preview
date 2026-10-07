function zipPath = zipFolder(dirPath)
    % Zip the recognised preview files in a folder into a temporary .zip
    %
    % function zipPath = BakingTray.webpreview.zipFolder(dirPath)
    %
    % Purpose
    % Only files the server keeps (see webpreview.selectUploadable) are included, and the
    % archive is flat: subfolders are ignored and entries carry no path. Filtering here keeps
    % the upload small; the server filters again, so this is an optimisation, not a security
    % boundary.
    %
    % Errors if the folder does not exist, holds no recognised files, has more files than the
    % server accepts (webpreview.serverLimits), or the zip would exceed the server's size
    % limit. The caller owns the returned file and should delete it after posting
    % (webpreview.zipAndPost does this).
    %
    % Inputs
    % dirPath - path to the folder to zip.
    %
    % Outputs
    % zipPath - path to the temporary zip file.


    if ~isfolder(dirPath)
        error('webpreview:noSuchFolder', 'Folder not found: %s', dirPath);
    end

    names = webpreview.selectUploadable(dirPath);
    if isempty(names)
        error('webpreview:noFiles', ...
            'No files with a recognised extension (%s) in %s', ...
            strjoin(webpreview.allowedExtensions(), ' '), dirPath);
    end

    lim = webpreview.serverLimits();
    if numel(names) > lim.maxEntries
        error('webpreview:tooManyFiles', ...
            '%d files in %s; the server accepts at most %d per upload.', ...
            numel(names), dirPath, lim.maxEntries);
    end


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Names relative to dirPath (the rootfolder argument) make the archive flat
    zipPath = [tempname, '.zip'];
    try
        zip(zipPath, names, dirPath);
    catch err
        deleteQuietly(zipPath); % do not leave a partial archive in tmp
        rethrow(err);
    end

    if ~isfile(zipPath)
        error('webpreview:zipFailed', 'zip() did not create %s', zipPath);
    end

    info = dir(zipPath);
    if info.bytes > lim.maxZipBytes
        delete(zipPath);
        error('webpreview:zipTooLarge', ...
            'Zip is %.1f MB; the server accepts at most %.0f MB.', ...
            info.bytes / 1024^2, lim.maxZipBytes / 1024^2);
    end
end


function deleteQuietly(path)
    % Delete a file if it exists
    %
    % function BakingTray.webpreview.zipFolder>deleteQuietly(path)

    if isfile(path)
        delete(path);
    end
end
