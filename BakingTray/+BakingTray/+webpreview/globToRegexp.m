function rx = globToRegexp(glob)
    % Translate a simple glob to an anchored, case-sensitive regexp
    %
    % function rx = BakingTray.webpreview.globToRegexp(glob)
    %
    % Purpose
    % Supported: '*', '?', and [...] character classes written as regexp classes
    % (e.g. [Mm], [a-z]). Like PHP glob(), a leading '*' or '?' does not match a
    % leading dot, so hidden files such as macOS '._recipe.yml' never match.
    % Other characters match literally.
    %
    % Known divergences from PHP glob(): '[!x]' negation, '[[:alpha:]]' classes and
    % backslash escapes are not translated (they pass through as regexp syntax or
    % literals); an empty '[]' is not supported. The server's globs (see
    % BakingTray.webpreview.stageSpec) use none of these.
    %
    % Inputs
    % glob - Char row vector containing the glob pattern.
    %
    % Outputs
    % rx - Char row vector: the regular expression, for use with regexp.
    %
    % Errors
    % 'webpreview:globToRegexp:unterminated' if a '[' has no closing ']'.
    %
    % See also: BakingTray.webpreview.stageSpec


    rx = '^';
    if ~isempty(glob) && any(glob(1)=='*?')
        rx = '^(?!\.)';
    end

    ii = 1;
    nChars = numel(glob);
    while ii<=nChars
        thisChar = glob(ii);
        switch thisChar
            case '*'
                rx = [rx '.*']; %#ok<AGROW>
            case '?'
                rx = [rx '.']; %#ok<AGROW>
            case '['
                closeInd = find(glob(ii+1:end)==']',1);
                if isempty(closeInd)
                    error('webpreview:globToRegexp:unterminated', ...
                        'Unterminated [ in glob "%s".', glob)
                end
                rx = [rx glob(ii:ii+closeInd)]; %#ok<AGROW>
                ii = ii + closeInd;
            otherwise
                rx = [rx regexptranslate('escape',thisChar)]; %#ok<AGROW>
        end %switch
        ii = ii + 1;
    end %while

    rx = [rx '$'];
end % globToRegexp
