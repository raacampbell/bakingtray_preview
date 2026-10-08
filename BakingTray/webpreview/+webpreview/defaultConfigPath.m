function p = defaultConfigPath()
    % Per-user config location, outside any repository
    %
    % function p = BakingTray.webpreview.defaultConfigPath()
    %
    % Outputs
    % p - full path to .brainsaw_webpreview.json in the user's home directory. Errors with
    %     webpreview:noHome if the home directory cannot be determined.

    if ispc
        home = getenv('USERPROFILE');
    else
        home = getenv('HOME');
    end

    if isempty(home)
        error('webpreview:noHome', 'Cannot determine the home directory.');
    end

    p = fullfile(home, '.brainsaw_webpreview.json');
end % defaultConfigPath
