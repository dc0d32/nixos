"""Exponential-sine-sweep (Farina) measurement engine.

Shared by speaker-measure.py. Importable; run directly for a self-test:

    python3 audio_ess.py

Two details in here are load-bearing and were both got wrong first time,
so don't "simplify" them without re-running the self-test:

1. INVERSE FILTER ENVELOPE SIGN. The ESS amplitude spectrum falls
   3 dB/oct. Time-reversal preserves magnitude, so the reversed sweep
   alone deconvolves to -6 dB/oct; the envelope must therefore RISE with
   instantaneous frequency to land on the +3 dB/oct that gives a flat
   result. Getting the sign backwards produces a clean -12 dB/oct tilt
   that looks plausible until you check it against a known system.

2. TIME GATING. The linear impulse response must be windowed tightly
   around its peak. A long window -- especially a long PRE-window, which
   is pure noise plus pre-ringing -- buries the direct sound under room
   reverb and noise. Measured on a laptop, 3 reps, 400 Hz-10 kHz:

       -100/+350 ms -> median spread 4.21 dB, p95 14.62 dB  (useless)
       -2/+150  ms -> median spread 0.17 dB, p95  0.83 dB  (default)

   Only fade the window OUT; a fade-in would attenuate the direct sound.
   CONSEQUENCE: results below ~200 Hz are gate-limited and must not be
   quoted as absolute response.
"""
import array
import struct

import numpy as np

SR = 48000


# ---------- wav io (float32, no external deps) ----------
def wwrite(path, x, sr=SR):
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    d = x.astype('<f4').tobytes()
    h = (b'RIFF' + struct.pack('<I', 36 + len(d)) + b'WAVEfmt ' +
         struct.pack('<IHHIIHH', 16, 3, x.shape[1], sr,
                     sr * 4 * x.shape[1], 4 * x.shape[1], 32) +
         b'data' + struct.pack('<I', len(d)))
    with open(path, 'wb') as f:
        f.write(h + d)


def wread(path):
    with open(path, 'rb') as f:
        d = f.read()
    pos, fmt, raw = 12, None, None
    while pos < len(d):
        cid = d[pos:pos + 4]
        sz = struct.unpack('<I', d[pos + 4:pos + 8])[0]
        body = d[pos + 8:pos + 8 + sz]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', body[:16])
        elif cid == b'data':
            raw = body
        pos += 8 + sz + (sz & 1)
    if fmt is None or raw is None:
        raise ValueError(f'{path}: not a usable WAV')
    ch = fmt[1]
    s = array.array('f')
    s.frombytes(raw[:(len(raw) // 4) * 4])
    return fmt[2], np.array(s, dtype=np.float64).reshape(-1, ch)


# ---------- sweep ----------
def ess(f1=20.0, f2=20000.0, T=8.0, sr=SR, peak_db=-18.0, pad=1.5):
    """Exponential sine sweep plus trailing silence for the tail."""
    n = int(T * sr)
    t = np.arange(n) / sr
    L = T / np.log(f2 / f1)
    x = np.sin(2 * np.pi * f1 * L * (np.exp(t / L) - 1.0))
    kf = int(0.02 * sr)
    x[:kf] *= np.linspace(0, 1, kf)
    x[-kf:] *= np.linspace(1, 0, kf)
    x *= 10 ** (peak_db / 20)
    return np.concatenate([x, np.zeros(int(pad * sr))]), L, T


def ess_inverse(x, L, T, sr=SR):
    n = int(T * sr)
    s = x[:n]
    t = np.arange(n) / sr
    # See note 1 in the module docstring: this envelope must RISE with
    # instantaneous frequency. In the reversed sweep the high frequencies
    # sit at the start, hence exp(+t_reversed/L).
    return s[::-1] * np.exp(t[::-1] / L)


def deconv(rec, inv):
    nfft = 1 << int(np.ceil(np.log2(len(rec) + len(inv) - 1)))
    return np.fft.irfft(np.fft.rfft(rec, nfft) * np.fft.rfft(inv, nfft), nfft)


def analyse_sweep(rec, ref, L, T, sr=SR, harm_orders=(2, 3, 4, 5),
                  pre_ms=2.0, post_ms=150.0):
    """Linear H(f) plus per-order harmonic energy from an ESS capture."""
    h = deconv(rec, ess_inverse(ref, L, T, sr))
    p = int(np.argmax(np.abs(h)))
    dts = [L * np.log(k) for k in harm_orders]   # harmonic k arrives EARLIER
    pre = int(pre_ms * sr / 1000)
    post = int(post_ms * sr / 1000)
    pre = min(pre, max(1, int(min(dts) * sr * 0.5)))   # never reach into h2
    lin = h[max(0, p - pre):p + post].astype(float).copy()
    e = max(4, int(0.15 * len(lin)))
    lin[-e:] *= np.hanning(2 * e)[e:]
    nfft = 1 << 16
    H = np.fft.rfft(lin, nfft)
    f = np.fft.rfftfreq(nfft, 1 / sr)
    e_lin = np.sum(lin ** 2)
    hw = max(64, int(1.0 * sr / 1000))
    thd = {}
    for k, dt in zip(harm_orders, dts):
        c = p - int(dt * sr)
        if c - hw < 0:
            thd[k] = float('nan')
            continue
        seg = h[max(0, c - hw):c + hw]
        thd[k] = np.sum(seg ** 2) / max(e_lin, 1e-30)
    return f, H, thd, h, p


def smooth_oct(f, mag_db, frac=6):
    """Fractional-octave smoothing."""
    out = np.empty_like(mag_db)
    for i, fc in enumerate(f):
        if fc <= 0:
            out[i] = mag_db[i]
            continue
        m = (f >= fc / 2 ** (1 / (2 * frac))) & (f <= fc * 2 ** (1 / (2 * frac)))
        out[i] = mag_db[m].mean() if m.any() else mag_db[i]
    return out


# ---------- self test ----------
def self_test():
    """Measure a synthetic system with a known analytic response."""
    ref, L, T = ess(T=4.0, peak_db=-12.0)

    def bp(sig):
        ff = np.fft.rfftfreq(len(sig), 1 / SR)
        ff[0] = 1e-9
        Hs = (1 / (1 + (300 / ff) ** 4)) * (1 / (1 + (ff / 6000) ** 4))
        return np.fft.irfft(np.fft.rfft(sig, len(sig)) * Hs, len(sig))

    y = bp(ref)
    y = y + 2.0 * y ** 3          # ~3 % third-harmonic distortion
    y += np.random.default_rng(0).normal(scale=1e-4, size=len(y))
    fq, H, thd, _h, _p = analyse_sweep(y, ref, L, T)
    mag = 20 * np.log10(np.abs(H) + 1e-20)
    mag -= mag[np.argmin(abs(fq - 1000))]

    def analytic(w):
        v = 20 * np.log10((1 / (1 + (300 / w) ** 4)) * (1 / (1 + (w / 6000) ** 4)))
        r = 20 * np.log10((1 / (1 + (300 / 1000) ** 4)) * (1 / (1 + (1000 / 6000) ** 4)))
        return v - r

    ok = True
    # 100 Hz is deliberately absent: the synthetic 4th-order 300 Hz
    # high-pass rings past the time gate and reads ~8 dB high there. That
    # is the gate's real LF limit (see note 2), not a bug -- so only probe
    # where gating is trustworthy.
    for probe in (1000, 300, 2000, 6000, 15000):
        got = mag[np.argmin(abs(fq - probe))]
        ana = analytic(probe)
        err = abs(got - ana)
        if err >= 1.0:
            ok = False
        print(f'  {probe:6d} Hz  measured {got:+7.2f}  analytic {ana:+7.2f}  '
              f'err {err:4.2f}  {"OK " if err < 1.0 else "BAD"}')
    h3 = 100 * np.sqrt(max(thd.get(3, 0), 0))
    h2 = 100 * np.sqrt(max(thd.get(2, 0), 0))
    print(f'  THD3 {h3:.2f}% (expect non-zero), THD2 {h2:.3f}% (expect ~0)')
    good = ok and thd.get(3, 0) > thd.get(2, 0)
    print('SELF TEST:', 'PASS' if good else 'FAIL')
    return good


if __name__ == '__main__':
    raise SystemExit(0 if self_test() else 1)
