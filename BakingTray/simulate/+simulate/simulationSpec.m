function s = simulationSpec()
    % Constants for simulate.simulateAcquisition, defined once
    %
    % function s = simulate.simulationSpec()
    %
    % Purpose
    % The log text mirrors test_images/acqLog_*.txt (the format the server's
    % bs_parse_acqlogs() parses). MinInterval is the server's upload rate limit.
    %
    % Outputs
    % s - Structure of simulation constants.

    s.MinInterval = 5;                          % seconds between uploads the server accepts
    s.TimeFormat = 'yyyy/MM/dd HH:mm:ss';       % log timestamp format
    s.TilesAcquired = 274;
    s.FirstZ = 24.38;                           % z of section 1 (mm)
    s.ZStep = 0.04;                             % section thickness (mm)

    % Never used as a format string (it contains backslashes); the section number is appended.
    s.DirectoryPrefix = 'F:\SIMULATED\rawData\SIM-';
    s.SampleID = 'SIMULATED';                   % replaces the real sample in the recipe copy
    s.Objective = 'simulated objective';
    s.CanaryMarker = 'testserver';              % a real run's config url must contain this
    s.AcquireFraction = 0.8;                    % share of a section spent imaging; the rest is cutting
    s.ImageSize = [240 320];                    % section image [rows cols]
    s.MontageSize = [200 300];
    s.DigitScale = 6;                           % pixels per font cell when stamping the section number
    s.DigitPad = 8;                             % dark box padding around the stamped number


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Log header text
    s.HeaderBefore = {'Writing to volume F: which has 4784/11170 GB free'};
    s.HeaderStartLabel = 'STARTING NEW ACQUISITION';   % timestamped
    s.HeaderAfter = { ...
        'Using laser: Spectra Physics,MaiTai,20408/50405/40209,0245-2.00.31 / CD00000019 / 214-00.003.035'
        'Acquiring with: ScanImage v5.6.0 on MATLAB 9.3.0.713579 (R2017b)'
        'Laser set to switch off at the end of acquisition'
        'BakingTray will slice the final imaged section off the block'
        'Setting laser watchdog timer to 2400 seconds'};


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Never sent to a server: the https scheme only has to satisfy webupload.webConfig.
    s.DryRunConfig = struct('url', 'https://dry-run.invalid/upload.php', ...
        'siteID', 'dryrun', 'micID', 'dryrun', 'token', 'DRYRUNTOKEN');
    s.LogName = 'acqLog_simulated.txt';

end %simulationSpec
