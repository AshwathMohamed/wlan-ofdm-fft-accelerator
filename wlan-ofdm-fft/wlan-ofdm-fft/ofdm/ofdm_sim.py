# 802.11a-style OFDM simulation: Gray QAM-16/64, multipath + AWGN, LS estimate, ZF equalizer.
# Run: python ofdm/ofdm_sim.py   (add --quick for a fast but noisy test)

import argparse
import os
from math import erfc, sqrt, log2

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

N_FFT = 64
CP_LEN = 16
PILOT_SC = [-21, -7, 7, 21]
USED_SC = list(range(-26, 0)) + list(range(1, 27))      # DC (0) is null
DATA_SC = [k for k in USED_SC if k not in PILOT_SC]     # 48 data subcarriers
USED_BINS = np.array([k % N_FFT for k in USED_SC])      # subcarrier k is FFT bin k mod 64
DATA_BINS = np.array([k % N_FFT for k in DATA_SC])
PILOT_BINS = np.array([k % N_FFT for k in PILOT_SC])
PILOT_VALUES = np.array([1, 1, 1, -1])

# known training symbol: fixed random +-1 on the used bins (same at TX and RX)
TRAIN_FREQ = np.zeros(N_FFT, dtype=complex)
TRAIN_FREQ[USED_BINS] = np.random.default_rng(1).choice([-1.0, 1.0], size=len(USED_BINS))

TAP_DELAYS = np.array([0, 2, 5, 9])                     # all shorter than the CP
NORM = {4: 1 / np.sqrt(10), 6: 1 / np.sqrt(42)}         # average symbol power = 1


def gray_levels(m):
    """Amplitude for each m-bit group on one axis. m=2: 00->-3, 01->-1, 11->+1, 10->+3"""
    M = 2 ** m
    table = np.zeros(M)
    for i in range(M):
        table[i ^ (i >> 1)] = 2 * i - (M - 1)
    return table


def qam_map(bits, bps):
    m = bps // 2
    table = gray_levels(m)
    b = bits.reshape(-1, bps)
    weights = 2 ** np.arange(m - 1, -1, -1)
    i_idx = b[:, :m] @ weights
    q_idx = b[:, m:] @ weights
    return (table[i_idx] + 1j * table[q_idx]) * NORM[bps]


def qam_demap(symbols, bps):
    m = bps // 2
    M = 2 ** m
    s = symbols / NORM[bps]
    out = np.zeros((len(symbols), bps), dtype=int)
    for axis, part in enumerate([s.real, s.imag]):
        idx = np.clip(np.round((part + (M - 1)) / 2).astype(int), 0, M - 1)
        gray = idx ^ (idx >> 1)
        for j in range(m):
            out[:, axis * m + j] = (gray >> (m - 1 - j)) & 1
    return out.reshape(-1)


def freq_to_time(X):
    x = np.fft.ifft(X)
    return np.concatenate([x[-CP_LEN:], x])


def transmit(bits, bps):
    """One frame = training symbol + data symbols."""
    data = qam_map(bits, bps).reshape(-1, len(DATA_BINS))
    pieces = [freq_to_time(TRAIN_FREQ)]
    for row in data:
        X = np.zeros(N_FFT, dtype=complex)
        X[DATA_BINS] = row
        X[PILOT_BINS] = PILOT_VALUES
        pieces.append(freq_to_time(X))
    return np.concatenate(pieces)


def random_channel(rng):
    """4 complex Gaussian taps, power drops with delay, total power 1."""
    power = np.exp(-TAP_DELAYS / 4.0)
    power = power / power.sum()
    taps = np.sqrt(power / 2) * (rng.standard_normal(4) + 1j * rng.standard_normal(4))
    h = np.zeros(TAP_DELAYS.max() + 1, dtype=complex)
    h[TAP_DELAYS] = taps
    return h


def add_awgn(x, snr_db, rng):
    """snr_db is Es/N0 per used subcarrier. The 64-point FFT sums 64 noise samples,
    so each bin gets 64 * noise_var = 1/snr."""
    snr = 10 ** (snr_db / 10)
    noise_var = 1.0 / (snr * N_FFT)
    noise = np.sqrt(noise_var / 2) * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    return x + noise


def receive_fft(rx, n_syms):
    """Remove CP and FFT each symbol. Row 0 is the training symbol."""
    rows = rx.reshape(n_syms + 1, N_FFT + CP_LEN)
    return np.fft.fft(rows[:, CP_LEN:], axis=1)


def ls_estimate(Y_train):
    H = np.ones(N_FFT, dtype=complex)
    H[USED_BINS] = Y_train[USED_BINS] / TRAIN_FREQ[USED_BINS]
    return H


def zf_demap(Y_data, H, bps):
    eq = Y_data[:, DATA_BINS] / H[DATA_BINS]
    return qam_demap(eq.reshape(-1), bps)


def simulate_point(bps, snr_db, mode, max_frames, n_syms, rng):
    """Returns (BER with LS estimate, BER with perfect channel). Both receivers
    use the same received signal. mode: 'awgn' (h = 1) or 'multipath' (new h per frame)."""
    err_est = err_perf = total = 0
    min_frames = min(300, max_frames)
    for frame in range(1, max_frames + 1):
        bits = rng.integers(0, 2, n_syms * len(DATA_BINS) * bps)
        tx = transmit(bits, bps)
        h = np.array([1.0 + 0j]) if mode == "awgn" else random_channel(rng)
        rx = add_awgn(np.convolve(tx, h)[:len(tx)], snr_db, rng)

        Y = receive_fft(rx, n_syms)
        H_est = ls_estimate(Y[0])
        H_true = np.fft.fft(h, N_FFT)

        err_est += np.sum(zf_demap(Y[1:], H_est, bps) != bits)
        err_perf += np.sum(zf_demap(Y[1:], H_true, bps) != bits)
        total += len(bits)
        # stop early on many errors, but average over enough random channels first
        if frame >= min_frames and err_est >= 300 and err_perf >= 300:
            break
    return err_est / total, err_perf / total


def q_func(x):
    return 0.5 * erfc(x / sqrt(2))


def theory_ber(bps, esn0_db):
    """Gray-coded square M-QAM, nearest-neighbour approximation (tight below BER ~1e-2):
    Pb = 4/log2(M) * (1 - 1/sqrt(M)) * Q(sqrt(3*log2(M)/(M-1) * Eb/N0))"""
    M = 2 ** bps
    ebn0 = 10 ** (np.asarray(esn0_db) / 10) / bps
    arg = np.sqrt(3 * log2(M) / (M - 1) * ebn0)
    q = np.array([q_func(a) for a in np.atleast_1d(arg)])
    return 4 / log2(M) * (1 - 1 / sqrt(M)) * q


def self_check():
    """Noise-free tests: mapper round trip and full chain must give zero errors."""
    rng = np.random.default_rng(0)
    for bps in (4, 6):
        bits = rng.integers(0, 2, 48 * bps * 10)
        assert np.array_equal(qam_demap(qam_map(bits, bps), bps), bits)
        tx = transmit(bits, bps)
        rx = np.convolve(tx, random_channel(rng))[:len(tx)]
        Y = receive_fft(rx, 10)
        assert np.array_equal(zf_demap(Y[1:], ls_estimate(Y[0]), bps), bits)
    print("self check OK (mapper + noise-free chain)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    max_frames = 40 if args.quick else 6000
    n_syms = 10

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)

    self_check()
    rng = np.random.default_rng(42)
    snr_list = np.arange(0, 36, 2)
    mods = {"16-QAM": 4, "64-QAM": 6}

    awgn, multi_est, multi_perf = {}, {}, {}
    for name, bps in mods.items():
        a, m_e, m_p = [], [], []
        for snr in snr_list:
            # AWGN check uses the perfect channel so only mapper/FFT/demapper are tested
            _, ber = simulate_point(bps, snr, "awgn", max_frames, n_syms, rng)
            a.append(ber)
            e, p = simulate_point(bps, snr, "multipath", max_frames, n_syms, rng)
            m_e.append(e)
            m_p.append(p)
            print(f"{name} Es/N0={snr:2d} dB  AWGN={ber:.2e}  multipath est={e:.2e}  perfect={p:.2e}")
        awgn[name], multi_est[name], multi_perf[name] = np.array(a), np.array(m_e), np.array(m_p)

    with open(os.path.join(out_dir, "ber_results.csv"), "w") as f:
        f.write("mod,esn0_db,ber_awgn_sim,ber_awgn_theory,ber_multipath_ls_zf,ber_multipath_perfect_zf\n")
        for name, bps in mods.items():
            th = theory_ber(bps, snr_list)
            for i, snr in enumerate(snr_list):
                f.write(f"{name},{snr},{awgn[name][i]:.3e},{th[i]:.3e},"
                        f"{multi_est[name][i]:.3e},{multi_perf[name][i]:.3e}\n")

    floor = 1e-7
    fine = np.arange(0, 36.1, 0.5)
    colors = [("16-QAM", 4, "tab:blue"), ("64-QAM", 6, "tab:red")]

    plt.figure(figsize=(7, 5))
    for name, bps, color in colors:
        plt.semilogy(fine, theory_ber(bps, fine), "-", color=color, label=f"{name} theory")
        ok = awgn[name] > 0                              # log plot cannot show zero
        plt.semilogy(snr_list[ok], awgn[name][ok], "o", color=color, label=f"{name} simulation")
    plt.ylim(floor, 1)
    plt.xlabel("Es/N0 per subcarrier (dB)")
    plt.ylabel("BER")
    plt.title("AWGN only: simulation vs theory (Gray QAM)")
    plt.grid(True, which="both", alpha=0.3)
    plt.legend()
    plt.savefig(os.path.join(out_dir, "ber_awgn_vs_theory.png"), dpi=150, bbox_inches="tight")
    plt.close()

    plt.figure(figsize=(7, 5))
    for name, bps, color in colors:
        plt.semilogy(fine, theory_ber(bps, fine), ":", color=color, alpha=0.6, label=f"{name} AWGN theory")
        ok = multi_est[name] > 0
        plt.semilogy(snr_list[ok], multi_est[name][ok], "o-", color=color, label=f"{name} multipath, LS estimate + ZF")
        ok = multi_perf[name] > 0
        plt.semilogy(snr_list[ok], multi_perf[name][ok], "s--", color=color, label=f"{name} multipath, perfect channel + ZF")
    plt.ylim(floor, 1)
    plt.xlabel("Es/N0 per subcarrier (dB)")
    plt.ylabel("BER")
    plt.title("Multipath + AWGN: estimated vs perfect channel")
    plt.grid(True, which="both", alpha=0.3)
    plt.legend(fontsize=8)
    plt.savefig(os.path.join(out_dir, "ber_multipath.png"), dpi=150, bbox_inches="tight")
    plt.close()
    print("saved plots and ber_results.csv in", out_dir)


if __name__ == "__main__":
    main()
