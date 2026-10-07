function lines = simulatedLogHeader(startTime)
    % The lines a real acquisition log has before section 1
    %
    % function lines = simulate.simulatedLogHeader(startTime)
    %
    % Purpose
    % Pure. Copies the header of test_images/acqLog_*.txt (see simulationSpec);
    % only the 'STARTING NEW ACQUISITION' line carries a timestamp.
    %
    % Inputs
    % startTime - datetime stamped on the 'STARTING NEW ACQUISITION' line.
    %
    % Outputs
    % lines - Column cellstr of header lines.
    %
    % See also simulate.simulationSpec


    narginchk(1,1)
    if ~isa(startTime,'datetime') || ~isscalar(startTime)
        error('simulate:simulatedLogHeader:badArgument','startTime must be a scalar datetime');
    end

    spec = simulate.simulationSpec();
    stamp = char(startTime, spec.TimeFormat);
    lines = [spec.HeaderBefore(:); {[stamp ' -- ' spec.HeaderStartLabel]}; spec.HeaderAfter(:)];

end %simulatedLogHeader
