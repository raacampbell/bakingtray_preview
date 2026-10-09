classdef ContractPinTest < matlab.unittest.TestCase
    % The client's copy of the shared contract (upload_contract.json, from tests/web/ in the
    % server repo) must be the version pinned here. To change the contract, copy the new file
    % in, update the hash below, and update tests/web/upload_contract.sha256 in the server repo.

    methods (Test)
        function copyIsThePinnedVersion(tc)
            pinned = '6457f1beec63fe182e9afadad392f107b4e7db098fd1847170abc78520d93773';
            f = fullfile(fileparts(mfilename('fullpath')), 'upload_contract.json');
            fid = fopen(f, 'r');
            bytes = fread(fid, inf, '*uint8');
            fclose(fid);
            md = java.security.MessageDigest.getInstance('SHA-256');
            md.update(typecast(bytes, 'int8'));
            digest = typecast(int8(md.digest()), 'uint8');
            tc.verifyEqual(lower(sprintf('%02x', digest)), pinned);
        end
    end
end
