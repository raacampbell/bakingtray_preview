classdef FakePoster < handle
    % Poster for dry runs: never touches the network, records what it would send
    %
    % simulate.FakePoster
    %
    % Purpose
    % Same contract as webpreview.zipAndPost: post(folder,cfg) returns
    % struct(ok, httpStatus, message). Calls is a struct array with fields
    % folder, names (sorted file names), bytes (matching sizes) and logText
    % (contents of the staged acqLog.txt, '' if absent), captured at call time
    % because the next section overwrites the stage folder.
    %
    % Example
    % p = simulate.FakePoster();
    % webpreview.updateSectionImage(..., 'Poster', @p.post)
    % p.Calls(end).names     % files in the stage folder at the last call
    %
    % See also webpreview.zipAndPost, webpreview.updateSectionImage

    properties (SetAccess = private)
        Calls = struct('folder', {}, 'names', {}, 'bytes', {}, 'logText', {})
    end %properties

    methods
        function reply = post(obj,folder,~)
            % Record the files in folder and return a successful reply without sending anything
            %
            % function reply = post(obj,folder,cfg)

            d = dir(folder);
            d = d(~[d.isdir]);
            [names,order] = sort({d.name});

            logFile = fullfile(folder, webpreview.stageSpec().Names.Log);
            logText = '';
            if isfile(logFile)
                logText = fileread(logFile);
            end

            obj.Calls(end+1) = struct('folder', folder, 'names', {names}, ...
                'bytes', [d(order).bytes], 'logText', logText);
            reply = struct('ok', true, 'httpStatus', 200, 'message', 'dry run: nothing sent');
        end %post
    end %methods

end %classdef
