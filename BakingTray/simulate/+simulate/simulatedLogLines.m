function lines = simulatedLogLines(k,N,startTime,durationSec)
    % The five log lines of one section, in the real log format
    %
    % function lines = simulate.simulatedLogLines(k,N,startTime,durationSec)
    %
    % Purpose
    % Pure (no clock, no random numbers). Returns a column cellstr, in the order
    % BakingTray writes them:
    %   <t0> -- STARTING section number k (k of N) at z=... in directory ...
    %   laser status: ...
    %   <t0+acquire> -- acquired T tile positions in M mins S secs
    %   laser status: ...
    %   <t0+durationSec> -- FINISHED section number k, section completed in M mins S secs
    % The timestamps and the durations in the text agree: the acquire time is
    % spec.AcquireFraction of durationSec (rounded down, at least 1 s, never more
    % than durationSec), and FINISHED is exactly durationSec after STARTING.
    % The caller may compress durationSec well below a real section time (about 285 s).
    %
    % Inputs
    % k           - Section number, a positive integer. Must not exceed N.
    % N           - Total number of sections, a positive integer.
    % startTime   - datetime of the STARTING line.
    % durationSec - Section duration in whole seconds, a positive integer.
    %
    % Outputs
    % lines - Column cellstr of the five log lines.
    %
    % See also simulate.simulationSpec


    narginchk(4,4)
    isCount = @(x) (isnumeric(x) || islogical(x)) && isscalar(x) && isreal(x) && ...
                    isfinite(x) && x==round(x) && x>0;
    if ~isCount(k) || ~isCount(N) || ~isCount(durationSec)
        error('simulate:simulatedLogLines:badArgument', ...
            'k, N and durationSec must be positive integer scalars');
    end
    if ~isa(startTime,'datetime') || ~isscalar(startTime)
        error('simulate:simulatedLogLines:badArgument','startTime must be a scalar datetime');
    end
    k = double(k);
    N = double(N);
    durationSec = double(durationSec);

    if k>N
        error('simulate:simulatedLogLines:badSection', 'section %d exceeds the total %d', k, N);
    end


    spec = simulate.simulationSpec();
    acquireSec = min(durationSec, max(1, floor(spec.AcquireFraction * durationSec)));
    stamp = @(t) char(t, spec.TimeFormat);
    z = spec.FirstZ + (k-1) * spec.ZStep;
    directory = [spec.DirectoryPrefix, sprintf('%04d',k)];

    lines = { ...
        sprintf('%s -- STARTING section number %d (%d of %d) at z=%.4f in directory %s', ...
            stamp(startTime), k, k, N, z, directory)
        laserLine(k,0)
        sprintf('%s -- acquired %d tile positions in %s', ...
            stamp(startTime + seconds(acquireSec)), spec.TilesAcquired, minsSecs(acquireSec))
        laserLine(k,1)
        sprintf('%s -- FINISHED section number %d, section completed in %s', ...
            stamp(startTime + seconds(durationSec)), k, minsSecs(durationSec))};

end %simulatedLogLines


function text = minsSecs(totalSec)
    % Format a number of seconds as 'M mins S secs'
    %
    % function text = minsSecs(totalSec)

    text = sprintf('%d mins %d secs', floor(totalSec/60), mod(totalSec,60));
end %minsSecs


function line = laserLine(k,phase)
    % Laser status line. Pump power drifts a little, deterministically, as in a real log.
    %
    % function line = laserLine(k,phase)

    pump = 12750 + mod(7*k + 3*phase, 19);
    line = sprintf(['laser status: wavelength=920nm,outputPower=2100mW,pumpPower=%dmW,', ...
        'pumpCurrent=97.1,humidity=2.0'], pump);
end %laserLine
