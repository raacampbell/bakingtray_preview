function out = simulatedRecipeText(text,numSections,startTime)
    % Make a sample recipe agree with the simulated acquisition
    %
    % function out = simulate.simulatedRecipeText(text,numSections,startTime)
    %
    % Purpose
    % Pure. Sets the 'numSections:' value (the key bs_parse_recipe() reads) to
    % numSections and, if present, acqStartTime to startTime, so the page shows a
    % total that matches the '(k of N)' in the log. The sample ID and objective
    % name are replaced by neutral fakes (simulationSpec) so a simulated site never
    % shows a real sample. Errors if there is no numSections line to patch, rather
    % than silently showing the wrong total.
    %
    % Inputs
    % text        - Recipe file contents, a char row or string scalar.
    % numSections - Total number of sections, a positive integer.
    % startTime   - datetime written to acqStartTime.
    %
    % Outputs
    % out - The patched recipe text, as char.
    %
    % See also simulate.simulationSpec


    narginchk(3,3)
    if ~((ischar(text) && (isrow(text) || isempty(text))) || (isstring(text) && isscalar(text)))
        error('simulate:simulatedRecipeText:badArgument', ...
            'text must be a char row or string scalar');
    end
    if ~((isnumeric(numSections) || islogical(numSections)) && isscalar(numSections) && ...
            isreal(numSections) && isfinite(numSections) && ...
            numSections==round(numSections) && numSections>0)
        error('simulate:simulatedRecipeText:badArgument', ...
            'numSections must be a positive integer scalar');
    end
    if ~isa(startTime,'datetime') || ~isscalar(startTime)
        error('simulate:simulatedRecipeText:badArgument','startTime must be a scalar datetime');
    end
    text = char(text);
    numSections = double(numSections);


    % Splice by position: a regexprep replacement like '$1289.0' would be read as token 128.
    extents = regexp(text, '^\s*numSections:\s*([\d.]+)', 'tokenExtents', 'once', 'lineanchors');
    if isempty(extents)
        error('simulate:simulatedRecipeText:noNumSections', ...
            'recipe has no "numSections:" line to set');
    end
    span = extents(1,:);   % with 'once' this is a numeric [first last] matrix
    out = [text(1:span(1)-1), sprintf('%d.0',numSections), text(span(2)+1:end)];


    % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    % Neutral sample ID and objective, and the start time
    spec = simulate.simulationSpec();
    stamp = char(startTime, spec.TimeFormat);
    out = regexprep(out, '(^sample:\s*\{[^}]*\bID:\s*)[^,}\s]+', ['$1' spec.SampleID], ...
                    'once', 'lineanchors');
    out = regexprep(out, '(^sample:\s*\{[^}]*objectiveName:\s*)[^,}]+', ['$1' spec.Objective], ...
                    'once', 'lineanchors');
    out = regexprep(out, '(acqStartTime:\s*)[''"]?[^,''"}]+[''"]?', ['$1''' stamp ''''], 'once');

end %simulatedRecipeText
