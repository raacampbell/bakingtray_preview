function sec = simulatedDurationSec(k,interval)
    % Wall-clock duration of simulated section k, in whole seconds
    %
    % function sec = simulate.simulatedDurationSec(k,interval)
    %
    % Purpose
    % Pure. Tracks the interval between sections, shortened by 0-2 s in a fixed
    % pattern so the acquisition-time chart is not a flat line, and never longer
    % than the interval (so consecutive sections do not overlap) unless the
    % interval is under 1 s, where it is 1 s.
    %
    % Inputs
    % k        - Section number, a positive integer.
    % interval - Seconds between sections, a finite number >= 0.
    %
    % Outputs
    % sec - Duration in whole seconds, at least 1.


    narginchk(2,2)
    isNumScalar = @(x) (isnumeric(x) || islogical(x)) && isscalar(x) && isreal(x) && isfinite(x);
    if ~isNumScalar(k) || k~=round(k) || k<1
        error('simulate:simulatedDurationSec:badArgument','k must be a positive integer scalar');
    end
    if ~isNumScalar(interval) || interval<0
        error('simulate:simulatedDurationSec:badArgument', ...
            'interval must be a finite number >= 0');
    end

    sec = max(1, round(double(interval)) - mod(double(k),3));

end %simulatedDurationSec
