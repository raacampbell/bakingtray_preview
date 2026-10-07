function mask = renderNumberMask(n,scale)
    % Logical bitmap of a non-negative integer in a 3x5 pixel font
    %
    % function mask = simulate.renderNumberMask(n,scale)
    %
    % Purpose
    % Pure, no toolboxes (insertText needs the Computer Vision Toolbox). Each font
    % cell becomes a scale x scale block; digits are one cell apart.
    %
    % Inputs
    % n     - Non-negative integer to draw.
    % scale - Pixels per font cell, a positive integer.
    %
    % Outputs
    % mask - Logical bitmap, 5*scale rows high.


    narginchk(2,2)
    isIntScalar = @(x) (isnumeric(x) || islogical(x)) && isscalar(x) && isreal(x) && ...
                        isfinite(x) && x==round(x);
    if ~isIntScalar(n) || n<0
        error('simulate:renderNumberMask:badArgument','n must be a non-negative integer scalar');
    end
    if ~isIntScalar(scale) || scale<1
        error('simulate:renderNumberMask:badArgument','scale must be a positive integer scalar');
    end
    n = double(n);
    scale = double(scale);

    digits = sprintf('%d',n) - '0';
    glyphs = arrayfun(@(d) [digitBitmap(d), false(5,1)], digits, 'UniformOutput', false);
    small = horzcat(glyphs{:});
    mask = kron(small(:,1:end-1), ones(scale)) > 0;   % kron of logicals is double

end %renderNumberMask


function bitmap = digitBitmap(d)
    % Logical 5x3 bitmap of the single digit d
    %
    % function bitmap = digitBitmap(d)

    font = { ...
        {'111','101','101','101','111'}, {'010','110','010','010','111'}, ...
        {'111','001','111','100','111'}, {'111','001','111','001','111'}, ...
        {'101','101','111','001','001'}, {'111','100','111','001','111'}, ...
        {'111','100','111','101','111'}, {'111','001','001','001','001'}, ...
        {'111','101','111','101','111'}, {'111','101','111','001','111'}};
    bitmap = char(font{d+1}) == '1';
end %digitBitmap
