function [img,montage] = simulatedImages(k,N)
    % Synthetic section image (RGB) and montage (gray) for section k of N
    %
    % function [img,montage] = simulate.simulatedImages(k,N)
    %
    % Purpose
    % Pure and deterministic (a private random stream seeded by k, so the global
    % stream is untouched). Both are uint8: img is HxWx3 (smooth gradient whose
    % colour shifts with k/N, plus noise, with the section number stamped white on
    % a dark box at the top left); montage is HxW gray (gradient, blob, noise).
    % Sizes come from simulate.simulationSpec.
    %
    % Inputs
    % k - Section number, a positive integer.
    % N - Total number of sections, a positive integer.
    %
    % Outputs
    % img     - uint8 HxWx3 section image.
    % montage - uint8 HxW montage image.
    %
    % See also simulate.simulationSpec, simulate.renderNumberMask


    narginchk(2,2)
    isCount = @(x) (isnumeric(x) || islogical(x)) && isscalar(x) && isreal(x) && ...
                    isfinite(x) && x==round(x) && x>0;
    if ~isCount(k) || ~isCount(N)
        error('simulate:simulatedImages:badArgument','k and N must be positive integer scalars');
    end
    k = double(k);
    N = double(N);

    spec = simulate.simulationSpec();
    stream = RandStream('mt19937ar', 'Seed', k);
    img = stampNumber(gradientRgb(spec.ImageSize, k/N, stream), k, spec);
    montage = grayMontage(spec.MontageSize, stream);

end %simulatedImages


function rgb = gradientRgb(sz,progress,stream)
    % Smooth RGB gradient, blue channel set by progress, plus noise
    %
    % function rgb = gradientRgb(sz,progress,stream)

    [x,y] = meshgrid(linspace(0,1,sz(2)), linspace(0,1,sz(1)));
    rgb = cat(3, x, y, progress * ones(sz));
    rgb = 0.15 + 0.7*rgb + 0.06*(rand(stream,[sz 3]) - 0.5);
end %gradientRgb


function out = stampNumber(rgb,k,spec)
    % Stamp k in white on a dark box (so the digits read on any background), return uint8
    %
    % function out = stampNumber(rgb,k,spec)

    mask = simulate.renderNumberMask(k, spec.DigitScale);
    pad = spec.DigitPad;
    boxRows = pad + (1:size(mask,1) + 2*pad);
    boxCols = pad + (1:size(mask,2) + 2*pad);
    if boxRows(end)>size(rgb,1) || boxCols(end)>size(rgb,2)
        error('simulate:simulatedImages:tooSmall', ...
            'section number %d does not fit in a %dx%d image', k, size(rgb,1), size(rgb,2));
    end

    box = false(size(rgb,1), size(rgb,2));
    box(boxRows,boxCols) = true;
    digits = false(size(box));
    digits(2*pad + (1:size(mask,1)), 2*pad + (1:size(mask,2))) = mask;

    out = rgb;
    out(repmat(box,[1 1 3])) = 0.05;
    out(repmat(digits,[1 1 3])) = 1;
    out = uint8(round(255 * min(max(out,0),1)));
end %stampNumber


function gray = grayMontage(sz,stream)
    % Gray montage: a Gaussian blob plus noise, as uint8
    %
    % function gray = grayMontage(sz,stream)

    [x,y] = meshgrid(linspace(-1,1,sz(2)), linspace(-1,1,sz(1)));
    blob = exp(-4 * (x.^2 + 1.5*y.^2));
    gray = 0.1 + 0.7*blob + 0.05*rand(stream,sz);
    gray = uint8(round(255 * min(max(gray,0),1)));
end %grayMontage
