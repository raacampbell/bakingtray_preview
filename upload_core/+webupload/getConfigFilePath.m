function cfgPath = getConfigFilePath(verbose)
    % Return file path to the config (token) file
    %
    % function cfgPath = webupload.getConfigFilePath(verbose)
    %
    % Inputs (optional)
    % verbose - false by default. If true, reports the path to the file if found
    %

    if nargin<1
        verbose = false;
    end

    cfgPath = which('brainsaw_webpreview.json');

    if verbose
        if ~isempty(cfgPath)
            fpintf('webupload config file found at %s\n', cfgPath)
        else
            fprintf('No webupload config file found\n')
        end
    end

