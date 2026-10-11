% Bit-true model of the Verilog FFT, test vectors, SQNR. Works in MATLAB and Octave.
% Run before the RTL simulation (makes the data files) and again after it (compares rtl_*.mem).
% Per butterfly: y0 = floor((x0*2^15 + W*x1 + 2^15) / 2^16), y1 = same with W*x1 subtracted.

clear;
N = 1024;
STAGES = 10;
here    = fileparts(mfilename('fullpath'));
dataDir = fullfile(here, '..', 'data');
repDir  = fullfile(here, '..', 'reports');
if ~exist(dataDir, 'dir'), mkdir(dataDir); end
if ~exist(repDir,  'dir'), mkdir(repDir);  end

% twiddle ROM, {cos, -sin} in Q1.15 (+1.0 becomes 32767)
t  = 0:N/2-1;
wr = round( cos(2*pi*t/N) * 32768);
wi = round(-sin(2*pi*t/N) * 32768);
wr = min(max(wr, -32768), 32767);
wi = min(max(wi, -32768), 32767);
fid = fopen(fullfile(dataDir, 'twiddle.mem'), 'w');
fprintf(fid, '%04x%04x\n', [mod(wr, 65536); mod(wi, 65536)]);
fclose(fid);

% test vectors (Q1.15 integers)
try, rng(1); catch, rand('state', 1); end
n = 0:N-1;
names  = {'random', 'tone', 'impulse'};
vec_re = zeros(3, N);
vec_im = zeros(3, N);
vec_re(1,:) = round(0.7*32768*(2*rand(1,N)-1));      % parts within +-0.7, so |x| < 1
vec_im(1,:) = round(0.7*32768*(2*rand(1,N)-1));
tone = 0.9*exp(1j*2*pi*100*n/N);                     % tone at bin 100
vec_re(2,:) = round(32768*real(tone));
vec_im(2,:) = round(32768*imag(tone));
vec_re(3,1) = round(0.9*32768);                      % impulse at n = 0

br = bin2dec(fliplr(dec2bin(0:N-1, 10)))';           % bit-reversed addresses

report = {};
for v = 1:3
    name = names{v};
    xr = vec_re(v,:);
    xi = vec_im(v,:);

    fid = fopen(fullfile(dataDir, ['in_' name '.mem']), 'w');
    fprintf(fid, '%04x%04x\n', [mod(xr, 65536); mod(xi, 65536)]);
    fclose(fid);

    % bit-true fixed-point model
    yr = zeros(1,N);  yi = zeros(1,N);
    yr(br+1) = xr;
    yi(br+1) = xi;
    overflow = false;
    k = 0:N/2-1;
    for s = 0:STAGES-1
        half = 2^s;
        j  = mod(k, half);
        i0 = floor(k/half)*2*half + j;
        i1 = i0 + half;
        tw = j * 2^(9-s);

        a = yr(i1+1);   b = yi(i1+1);
        c = wr(tw+1);   d = wi(tw+1);
        t_re = a.*c - b.*d;
        t_im = a.*d + b.*c;
        x0r = yr(i0+1) * 32768;
        x0i = yi(i0+1) * 32768;

        nr = zeros(1,N);  ni = zeros(1,N);
        nr(i0+1) = floor((x0r + t_re + 32768) / 65536);
        nr(i1+1) = floor((x0r - t_re + 32768) / 65536);
        ni(i0+1) = floor((x0i + t_im + 32768) / 65536);
        ni(i1+1) = floor((x0i - t_im + 32768) / 65536);

        % the RTL wraps to 16 bits (no saturation), so do the same and flag it
        if any(nr > 32767 | nr < -32768 | ni > 32767 | ni < -32768)
            overflow = true;
        end
        yr = mod(nr + 32768, 65536) - 32768;
        yi = mod(ni + 32768, 65536) - 32768;
    end

    fid = fopen(fullfile(dataDir, ['model_' name '.mem']), 'w');
    fprintf(fid, '%04x%04x\n', [mod(yr, 65536); mod(yi, 65536)]);
    fclose(fid);

    % floating-point reference
    xf  = (xr + 1j*xi) / 32768;
    ref = fft(xf) / N;
    yf  = (yr + 1j*yi) / 32768;
    err = yf - ref;
    sqnr = 10*log10( sum(abs(ref).^2) / sum(abs(err).^2) );

    report{end+1} = sprintf('[%s]', name);
    report{end+1} = sprintf('  SQNR (fixed point vs floating point fft/1024) = %.2f dB', sqnr);
    if overflow
        report{end+1} = '  WARNING: overflow happened in the model (input too large)';
    else
        report{end+1} = '  no overflow in any stage';
    end

    rtlfile = fullfile(dataDir, ['rtl_' name '.mem']);
    if exist(rtlfile, 'file')
        words = regexp(fileread(rtlfile), '[0-9A-Fa-f]{8}', 'match');
        if numel(words) ~= N
            report{end+1} = sprintf('  RTL file problem: found %d valid lines, need %d', numel(words), N);
        else
            val = hex2dec(words)';
            rr = floor(val/65536);   ri = mod(val, 65536);
            rr = rr - 65536*(rr >= 32768);
            ri = ri - 65536*(ri >= 32768);
            nbad = sum(rr ~= yr | ri ~= yi);
            if nbad == 0
                report{end+1} = sprintf('  RTL vs bit-true model: EXACT MATCH (%d of %d samples equal)', N, N);
            else
                report{end+1} = sprintf('  RTL vs bit-true model: MISMATCH in %d of %d samples', nbad, N);
            end
        end
    else
        report{end+1} = '  RTL output not found yet (run the simulation, then run this script again)';
    end
end

fid = fopen(fullfile(repDir, 'matlab_results.txt'), 'w');
for i = 1:numel(report)
    disp(report{i});
    fprintf(fid, '%s\n', report{i});
end
fclose(fid);
