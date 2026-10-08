classdef ToUint8Test < matlab.unittest.TestCase
    % Tests for webupload.toUint8, which is pure (no files, no JPEG).
    % Run: runtests(fullfile(<repo>, 'upload_core', 'tests'))

    methods (TestClassSetup)
        function addPackageToPath(tc)
            root = fileparts(fileparts(mfilename('fullpath')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(root));
        end
    end

    methods (Test)
        function toUint8RoundsFloatHalfUp(tc)
            tc.verifyEqual(webupload.toUint8(0.5 * ones(2)), uint8(128 * ones(2)));
        end

        function toUint8Uint8IsIdentity(tc)
            img = uint8([0 1 127 255; 3 4 5 6]);
            tc.verifyEqual(webupload.toUint8(img), img);
        end

        function toUint8Uint16AutoscalesToMax(tc)
            out = webupload.toUint8(uint16([0 1000; 2000 2000]));
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8Uint16AllZeroIsBlack(tc)
            tc.verifyEqual(webupload.toUint8(zeros(3, 3, 'uint16')), zeros(3, 3, 'uint8'));
        end

        function toUint8Uint16ExplicitFullRangeKeepsAbsoluteScale(tc)
            out = webupload.toUint8(uint16([0 2047; 2047 2047]), [0 65535]);
            tc.verifyLessThan(double(out(1,2)), 10);
        end

        function toUint8Int16ClampsNegativesAndAutoscales(tc)
            out = webupload.toUint8(int16([-5 0; 100 200]));
            tc.verifyEqual(out, uint8([0 0; 128 255]));
        end

        function toUint8RangeScalesAndClamps(tc)
            out = webupload.toUint8([-1 5; 10 20], [0 10]);
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8IntegerClassRangeIsUsedAsDouble(tc)
            out = webupload.toUint8(uint16([0 2048; 4095 4095]), uint16([0 4095]));
            tc.verifyEqual(out, uint8([0 128; 255 255]));
        end

        function toUint8NegativeLoRange(tc)
            out = webupload.toUint8(int16([-100 0; 100 300]), int16([-100 300]));
            tc.verifyEqual(out, uint8([0 64; 128 255]));
        end

        function toUint8SingleAccepted(tc)
            tc.verifyEqual(webupload.toUint8(0.5 * ones(2, 'single')), uint8(128 * ones(2)));
        end

        function toUint8BadRangeErrors(tc)
            img = uint8(ones(4));
            tc.verifyError(@() webupload.toUint8(img, [5 1]), 'webupload:toUint8:badRange');
            tc.verifyError(@() webupload.toUint8(img, [1 NaN]), 'webupload:toUint8:badRange');
            tc.verifyError(@() webupload.toUint8(img, [1 2 3]), 'webupload:toUint8:badRange');
        end

        function toUint8FloatOutOfRangeErrorsWithoutRange(tc)
            tc.verifyError(@() webupload.toUint8(2 * ones(4)), 'webupload:toUint8:badImage');
        end

        function toUint8NanAndInfError(tc)
            bad = ones(4); bad(3) = NaN;
            tc.verifyError(@() webupload.toUint8(bad), 'webupload:toUint8:badImage');
            tc.verifyError(@() webupload.toUint8(bad, [0 1]), 'webupload:toUint8:badImage');
            bad(3) = Inf;
            tc.verifyError(@() webupload.toUint8(bad), 'webupload:toUint8:badImage');
        end

        function toUint8UnsupportedClassErrors(tc)
            tc.verifyError(@() webupload.toUint8(int32(ones(4))), 'webupload:toUint8:badImage');
        end

        function toUint8BadDimsError(tc)
            tc.verifyError(@() webupload.toUint8(uint8(ones(4,4,3,2))), 'webupload:toUint8:badImage');
            tc.verifyError(@() webupload.toUint8(uint8(ones(4,4,2))), 'webupload:toUint8:badImage');
            tc.verifyError(@() webupload.toUint8(uint8([])), 'webupload:toUint8:badImage');
            tc.verifyError(@() webupload.toUint8(uint8(1:10)), 'webupload:toUint8:badImage');
            tc.verifyError(@() webupload.toUint8(uint8((1:10)')), 'webupload:toUint8:badImage');
        end
    end
end
