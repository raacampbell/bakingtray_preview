function sec = loggedDurationSec(durationSec,timeScale)
    % Duration written to the log: durationSec times timeScale
    %
    % function sec = simulate.loggedDurationSec(durationSec,timeScale)
    %
    % Purpose
    % Pure, whole seconds, at least 1. timeScale 1 logs the true duration.
    % A larger scale (60) makes the server's chart, which is in minutes, readable
    % from a run lasting seconds; the log timestamps then lie in the past
    % (STARTING is earlier than the real time the section took).
    %
    % Inputs
    % durationSec - True duration in whole seconds, a positive integer.
    % timeScale   - Multiplier, a finite number > 0.
    %
    % Outputs
    % sec - Logged duration in whole seconds, at least 1.


    narginchk(2,2)
    isNumScalar = @(x) (isnumeric(x) || islogical(x)) && isscalar(x) && isreal(x) && isfinite(x);
    if ~isNumScalar(durationSec) || durationSec~=round(durationSec) || durationSec<1
        error('simulate:loggedDurationSec:badArgument', ...
            'durationSec must be a positive integer scalar');
    end
    if ~isNumScalar(timeScale) || timeScale<=0
        error('simulate:loggedDurationSec:badArgument', ...
            'timeScale must be a finite number > 0');
    end

    sec = max(1, round(double(durationSec) * double(timeScale)));

end %loggedDurationSec
