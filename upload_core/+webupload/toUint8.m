function out = toUint8(img,range)
    % Convert a gray (HxW) or RGB (HxWx3) numeric image to rounded uint8
    %
    % function out = webupload.toUint8(img,range)
    %
    % Purpose
    % Pure (no I/O). The image must be at least 2x2: vectors and scalars are not images.
    % Classes: uint8, uint16, int16, single, double; others error.
    %
    % Default mapping (no range given):
    %   uint8          - used as is.
    %   uint16, int16  - autoscaled to [0 max(img(:))] so 11-14 bit camera data is not
    %                    near-black. Negatives clamp to 0 and an all-zero (or
    %                    all-negative) image maps to black. Pass [0 65535] (or
    %                    [0 32767]) to keep the absolute class range instead.
    %   single, double - must be finite and within [0,1]; mapped to 0-255.
    % With an explicit range every class is scaled linearly and clamped.
    % NaN or Inf in a floating-point image always errors.
    %
    % CAVEAT: autoscaling is per image. One hot pixel darkens a whole frame, a
    % uniformly dim frame is stretched to white, and brightness therefore varies
    % between frames. For comparable brightness across a series pass a fixed range,
    % e.g. [0 4095] for 12-bit data.
    %
    % Inputs
    % img   - Numeric HxW or HxWx3 image.
    % range - Optional numeric [lo hi] with hi>lo: lo maps to 0 and hi to 255, with
    %         clamping. Empty (default) selects the class-dependent mapping above.
    %
    % Outputs
    % out - uint8 image the same size as img.
    %
    % Errors
    % 'webupload:toUint8:badImage' for non-numeric, wrongly shaped or unsupported-class
    %     images, for NaN or Inf in a floating-point image, and for floating-point
    %     images outside [0,1] when no range is given.
    % 'webupload:toUint8:badRange' if range is non-numeric, or is not empty or a
    %     finite [lo hi] with hi>lo.
    %
    % See also: webupload.stageFiles


    narginchk(1,2)
    if nargin<2
        % Only an omitted range selects the default; a non-numeric one is an error below.
        range = [];
    end

    if ~isnumeric(img)
        error('webupload:toUint8:badImage', ...
            'Image must be numeric; got class "%s".', class(img))
    end
    if ~isnumeric(range)
        error('webupload:toUint8:badRange', ...
            'Range must be numeric; got class "%s".', class(range))
    end

    % Integer-class ranges would saturate and integer-divide
    range = double(range);
    if ~isempty(range) && ~(numel(range)==2 && all(isfinite(range)) && range(2)>range(1))
        error('webupload:toUint8:badRange', ...
            'Range must be empty or a finite [lo hi] with hi > lo.')
    end

    validDims = (ndims(img)==2 || (ndims(img)==3 && size(img,3)==3)) ...
                && size(img,1)>=2 && size(img,2)>=2;
    if ~validDims
        error('webupload:toUint8:badImage', ...
            'Image must be at least 2x2, HxW or HxWx3; got size [%s].', num2str(size(img)))
    end
    if ~ismember(class(img),{'uint8','uint16','int16','single','double'})
        error('webupload:toUint8:badImage', 'Unsupported image class "%s".', class(img))
    end

    x = double(img);
    if isfloat(img) && any(~isfinite(x(:)))
        error('webupload:toUint8:badImage', 'Floating-point image contains NaN or Inf.')
    end

    if isempty(range)
        range = defaultRange(img,x);
    end

    scaled = (x-range(1)) / (range(2)-range(1));
    out = uint8(round(255 * min(max(scaled,0),1)));
end % toUint8


function range = defaultRange(img,x)
    % Class-dependent [lo hi] used when the caller gives no range
    %
    % function range = webupload.toUint8>defaultRange(img,x)
    %
    % Purpose
    % The mappings are described in toUint8. For uint16 and int16 the upper limit is the
    % image maximum, but at least 1 so that an all-zero image does not divide by zero.
    %
    % Inputs
    % img - The original image. Only its class is used.
    % x   - The same image converted to double.
    %
    % Outputs
    % range - [lo hi] to map to 0 and 255.
    %
    % Errors
    % 'webupload:toUint8:badImage' if a single or double image is not within [0,1].

    switch class(img)
        case 'uint8'
            range = [0 255];
        case {'uint16','int16'}
            range = [0 max(max(x(:)),1)]; % max 0 would divide by zero
        otherwise % single, double
            if min(x(:))<0 || max(x(:))>1
                error('webupload:toUint8:badImage', ...
                    'Floating-point images must lie within [0,1] (or pass a range).')
            end
            range = [0 1];
    end %switch
end % defaultRange
