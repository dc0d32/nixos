#!/usr/bin/env python3
"""preset-headroom — offline gain-staging check for an EasyEffects preset.

Models a preset's LINEAR chain (convolver IR + LSP parametric EQs + fixed
gains) against pink noise and reports how close it runs to `limiter#0` and
to each enabled `multiband_compressor#1` band threshold. No audio hardware
and no playback required.

    preset-headroom hosts/pb-x1/audio-presets/X1Yoga7-Bass.json
    preset-headroom hosts/<h>/audio-presets/*.json --gain 3

Why this exists: while tuning pb-x1 by ear, several candidate presets were
built that sat AT or slightly OVER limiter#0's threshold, i.e. permanently
limiting. That is inaudible as "clipping" but squashes dynamics, and it is
trivially predictable on paper. Run this before auditioning anything.

`--gain` models a proposed broadband boost, so you can ask "is +3 dB still
safe?" without editing the preset.

LIMITS
  * Linear model only. A nonlinear plugin in the chain (`bass_enhancer`,
    `exciter`, `crystalizer`, compressors actually compressing) cannot be
    predicted; the tool warns and models the rest. Its real peak will be
    HIGHER than reported.
  * Pink noise is a stand-in for programme material. Treat the margins as
    indicative, and prefer a few dB of slack over zero.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audio_ess import wread  # noqa: E402

SR = 48000
NFFT = 1 << 16
# Signal GENERATORS whose output cannot be predicted from a linear model.
# Compressors/gates are deliberately absent: they are level-dependent but we
# report their margins directly, so flagging them would just be noise.
NONLINEAR = ('bass_enhancer', 'exciter', 'crystalizer', 'maximizer', 'crusher',
             'autotune', 'pitch')

f = np.fft.rfftfreq(NFFT, 1 / SR)
f[0] = 1e-9


# ---- LSP RLC filters, bilinear with prewarp (lsp-plugins Filter.cpp) ----
def _p(f0):
    return 1j * np.tan(np.pi * f / SR) / np.tan(np.pi * f0 / SR)


def _casc(t, b, p):
    return (t[0] + t[1] * p + t[2] * p * p) / (b[0] + b[1] * p + b[2] * p * p)


def _hipass(f0, q, slope):
    p = _p(f0)
    H = np.ones_like(p)
    k = 2.0 / (1.0 + q)
    i = slope & 1
    if i:
        H *= _casc([0.0, 1.0, 0.0], [1.0, 1.0, 0.0], p)
    for _ in range(i, slope, 2):
        H *= _casc([0.0, 0.0, 1.0], [1.0, k, 1.0], p)
    return H


def _lopass(f0, q, slope):
    p = _p(f0)
    H = np.ones_like(p)
    k = 2.0 / (1.0 + q)
    i = slope & 1
    if i:
        H *= _casc([1.0, 0.0, 0.0], [1.0, 1.0, 0.0], p)
    for _ in range(i, slope, 2):
        H *= _casc([1.0, 0.0, 0.0], [1.0, k, 1.0], p)
    return H


def _bell(f0, q, slope, gain):
    p = _p(f0)
    fg = gain ** (1.0 / slope)
    ang = np.arctan(fg)
    k = 2.0 * (1.0 / fg + fg) / (1.0 + (2.0 * q) / slope)
    kt, kb = k * np.sin(ang), k * np.cos(ang)
    H = np.ones_like(p)
    for _ in range(slope):
        H *= _casc([1.0, kt, 1.0], [1.0, kb, 1.0], p)
    return H


def _shelf(f0, q, slope, gain, hi):
    p = _p(f0)
    g = np.sqrt(gain)
    fg = np.exp(np.log(g) / (slope * 2))
    H = np.ones_like(p)
    for _ in range(slope):
        t = [fg, 2.0 / (1.0 + q), 1.0 / fg]
        b = [1.0 / fg, 2.0 / (1.0 + q), fg]
        H *= _casc(t, b, p) if hi else _casc(b, t, p)
    return H * (gain if hi else 1.0) / (np.sqrt(gain) if hi else 1.0)


SLOPE = {'x1': 1, 'x2': 2, 'x3': 3, 'x4': 4}


def eq_response(eq, side='left'):
    H = np.ones(len(f), dtype=complex)
    for key in sorted(eq.get(side, {})):
        bd = eq[side][key]
        if bd.get('mute'):
            continue
        t = bd.get('type', 'Off')
        g = 10 ** (bd.get('gain', 0.0) / 20)
        q = bd.get('q', 0.707)
        n = SLOPE.get(bd.get('slope', 'x1'), 1)
        fr = bd.get('frequency', 1000.0)
        if t == 'Bell':
            H *= _bell(fr, q, n, g)
        elif t == 'Hi-pass':
            H *= _hipass(fr, q, n)
        elif t == 'Lo-pass':
            H *= _lopass(fr, q, n)
        elif t == 'Hi-shelf':
            H *= _shelf(fr, q, n, g, True)
        elif t == 'Lo-shelf':
            H *= _shelf(fr, q, n, g, False)
    return H * 10 ** ((eq.get('output-gain', 0.0) + eq.get('input-gain', 0.0)) / 20)


def load_ir(path):
    _sr, a = wread(path)
    return a[:, 0]


def analyse(preset_path, irs_dir, extra_gain_db=0.0, seed=11):
    p = json.load(open(preset_path))['output']
    order = p.get('plugins_order', [])
    warn = [q for q in order if q.split('#')[0] in NONLINEAR
            and not p.get(q, {}).get('bypass')]

    H = np.ones(len(f), dtype=complex)
    conv = p.get('convolver#0')
    if conv and not conv.get('bypass'):
        irp = os.path.join(irs_dir, conv['kernel-name'] + '.irs')
        if not os.path.exists(irp):
            raise FileNotFoundError(irp)
        H = np.fft.rfft(load_ir(irp), NFFT)
        H = H * 10 ** ((conv.get('output-gain', 0.0) + conv.get('input-gain', 0.0)) / 20)
    for key in ('equalizer#0', 'equalizer#1'):
        if key in p and not p[key].get('bypass'):
            H = H * eq_response(p[key])
    mbc0 = p.get('multiband_compressor#0')
    if mbc0 and 'multiband_compressor#0' in order and not mbc0.get('bypass'):
        H = H * 10 ** (mbc0.get('band0', {}).get('makeup', 0.0) / 20)
    H_pre = H * 10 ** (extra_gain_db / 20)
    mbc1 = p.get('multiband_compressor#1', {})
    H_post = H_pre * 10 ** (mbc1.get('output-gain', 0.0) / 20)

    n = 1 << 19
    ff = np.fft.rfftfreq(n, 1 / SR)
    ff[0] = ff[1]
    pink = np.fft.irfft(np.fft.rfft(np.random.default_rng(seed).normal(size=n))
                        / np.sqrt(ff), n)
    pink /= np.abs(pink).max()
    pink *= 10 ** (-0.5 / 20)
    fin = np.fft.rfftfreq(n, 1 / SR)

    def apply(Hx):
        Hi = np.interp(fin, f, Hx.real) + 1j * np.interp(fin, f, Hx.imag)
        return np.fft.irfft(np.fft.rfft(pink) * Hi, n)

    def db(x):
        return 20 * np.log10(np.abs(x) + 1e-20)

    peak = db(np.abs(apply(H_post)).max())
    thr = p.get('limiter#0', {}).get('threshold', 0.0)
    pre = apply(H_pre)
    bands = []
    if mbc1:
        edges = [0] + [mbc1[f'band{i}']['split-frequency'] for i in range(1, 5)] + [SR / 2]
        F = np.fft.rfft(pre)
        for i in range(4):
            bd = mbc1.get(f'band{i}', {})
            if not bd.get('compressor-enable'):
                continue
            m = (fin >= edges[i]) & (fin < edges[i + 1])
            Y = np.zeros(len(fin), dtype=complex)
            Y[m] = F[m]
            bands.append((edges[i], edges[i + 1],
                          bd['attack-threshold'] - db(np.abs(np.fft.irfft(Y, n)).max())))
    return peak, thr, bands, warn


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('presets', nargs='+')
    ap.add_argument('--irs-dir', default=None,
                    help='default: ../audio-irs relative to the preset')
    ap.add_argument('--gain', type=float, default=0.0,
                    help='model an extra broadband gain, dB')
    a = ap.parse_args()

    files = []
    for pat in a.presets:
        files.extend(sorted(glob.glob(pat)) if any(c in pat for c in '*?[') else [pat])

    print(f'{"preset":38} {"peak":>8} {"limiter":>8} {"margin":>8}  worst mbc band')
    rc = 0
    for path in files:
        irs = a.irs_dir or os.path.join(os.path.dirname(os.path.abspath(path)),
                                        '..', 'audio-irs')
        try:
            peak, thr, bands, warn = analyse(path, irs, a.gain)
        except Exception as exc:                       # noqa: BLE001
            print(f'{os.path.basename(path)[:-5]:38} ERROR: {exc}')
            rc = 1
            continue
        margin = thr - peak
        worst = min((b[2] for b in bands), default=float('inf'))
        verdict = 'OK' if (margin > 0.5 and worst > 3) else 'TIGHT' if margin > 0 else 'OVER'
        if verdict != 'OK':
            rc = 1
        ws = f'{worst:+.1f} dB' if bands else 'n/a'
        print(f'{os.path.basename(path)[:-5]:38} {peak:+8.2f} {thr:+8.2f} '
              f'{margin:+8.2f}  {ws:>9}  {verdict}')
        if warn:
            print(f'{"":38} note: nonlinear stage(s) not modelled: {", ".join(warn)}')
    return rc


if __name__ == '__main__':
    raise SystemExit(main())
