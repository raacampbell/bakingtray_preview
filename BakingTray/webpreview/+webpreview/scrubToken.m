function msg = scrubToken(msg, token)
    % Replace every occurrence of token in msg with '***'
    %
    % function msg = BakingTray.webpreview.scrubToken(msg, token)
    %
    % Purpose
    % Never throws: if msg is not a character vector the result is ''; if token is not a
    % non-empty character vector the message is returned unchanged.
    %
    % Inputs
    % msg - message text.
    % token - secret to remove from msg.
    %
    % Outputs
    % msg - the scrubbed message.

    if ~ischar(msg)
        msg = '';
        return
    end
    if ischar(token) && ~isempty(token)
        msg = strrep(msg, token, '***');
    end
end % scrubToken
