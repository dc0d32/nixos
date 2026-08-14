#!/usr/bin/env python3
"""speaker-measure — acoustic response of built-in laptop speakers,
measured with the internal microphone, cancelling the DSP loopback.

    speaker-measure --self-test        # verify the engine, no audio
    speaker-measure                    # measure, 4 reps
    speaker-measure --reps 6 --level -20

WHY THIS IS NOT JUST "PLAY A SWEEP AND RECORD IT"
On at least some SOF/DMIC laptops (verified on a ThinkPad X1 Yoga Gen 7)
the internal microphone stream carries a DSP **echo reference** — a
digital copy of the playback — mixed in with the acoustic signal. Mute the
speakers at the codec and a sweep still records at full level. Naively
measuring gives a suspiciously flat response that is really just the
loopback, and no amount of averaging fixes it.

Both paths are linear and driven by the same deterministic sweep, so:

    H_on  = H_loopback + H_acoustic     (speaker switch on)
    H_off = H_loopback                  (speaker switch off)
    => H_acoustic = H_on - H_off        COMPLEX subtraction

This tool captures both and subtracts. On the reference machine the
loopback cancelled 39-40 dB, leaving the acoustic signal ~33 dB above the
cancellation floor. If your machine has no loopback the "off" capture is
just silence and the subtraction is a no-op, so this is safe either way.

OPERATING POINT MATTERS. The loopback scales with the DIGITAL level while
the acoustic scales with SPEAKER VOLUME. So run the volume high and the
digital level low: on the reference machine, volume 1.0 with a -24 dBFS
sweep put the acoustic 10 dB ABOVE the loopback with 0.04 % mic clipping,
whereas at volume 0.30 the acoustic was undetectable.

Play DIRECT TO THE HARDWARE SINK. Routing through a DSP sink such as
`easyeffects_sink` adds run-to-run latency jitter that de-aligns the
loopback and wrecks the cancellation (repeatability 6 dB vs ~1 dB).

READ THE RESULT WITH CARE
The internal mic is uncalibrated and sits centimetres from the drivers, so
this is speaker x mic, not speaker. Trust it for:
  * A/B comparisons, where the mic response cancels.
  * Narrow (high-Q) features — those are the speaker; mic response is smooth.
  * Repeatability-checked relative changes.
Do NOT flatten the measured curve: you would bake the microphone's own
response into your speakers. Results below ~200 Hz are additionally
gate-limited (see audio_ess.py).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audio_ess import (SR, analyse_sweep, deconv, ess, ess_inverse,  # noqa: E402
                       self_test, smooth_oct, wread, wwrite)

N = 1 << 15


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def need(*tools):
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        sys.exit(f'error: missing required tool(s): {", ".join(missing)}')


def pw_nodes(media_class):
    try:
        d = json.loads(sh('pw-dump').stdout)
    except json.JSONDecodeError:
        sys.exit('error: could not parse pw-dump output; is PipeWire running?')
    out = []
    for o in d:
        props = (o.get('info') or {}).get('props') or {}
        if props.get('media.class') == media_class and props.get('node.name'):
            out.append((o['id'], props['node.name']))
    return out


def default_node(media_class, pattern=None):
    nodes = pw_nodes(media_class)
    if pattern:
        for i, n in nodes:
            if pattern in n:
                return i, n
    for i, n in nodes:
        if n.startswith('alsa_'):
            return i, n
    if not nodes:
        sys.exit(f'error: no {media_class} node found')
    return nodes[0]


def speaker_switches(card):
    """ALSA switches that actually mute the speakers, found BY NAME.

    Deliberately not by numid: those are unstable across machines and
    kernels. Note `Master Playback Switch` does NOT mute the speakers on
    every codec -- on the reference machine only these two did.
    """
    names = []
    out = sh(f'amixer -c {card} controls').stdout
    for line in out.splitlines():
        if "name='" not in line:
            continue
        nm = line.split("name='")[1].rstrip("'")
        if nm in ('Speaker Playback Switch', 'Bass Speaker Playback Switch'):
            names.append(nm)
    return names


def set_speakers(card, names, on):
    """Mute/unmute and VERIFY.

    Must use `cset name=`, not `sset`: these are not ALSA *simple* mixer
    controls, so `amixer sset 'Speaker Playback Switch' mute` fails with
    "Unable to find simple control" and — because amixer still exits 0 in
    some paths — silently leaves the speakers ON. A measurement taken
    that way is contaminated by real acoustic output and the loopback
    cancellation is meaningless, so the state is read back and a mismatch
    is fatal rather than a warning.
    """
    want = 'on' if on else 'off'
    for nm in names:
        sh(f"amixer -c {card} cset name='{nm}' {want}")
    time.sleep(0.4)
    for nm in names:
        got = sh(f"amixer -c {card} cget name='{nm}'").stdout
        vals = [ln.split('=', 1)[1] for ln in got.splitlines() if ln.strip().startswith(': values=')]
        if not vals or want not in vals[0]:
            sys.exit(f"error: could not set '{nm}' to {want} (read back {vals or 'nothing'}).\n"
                     f"       Refusing to continue: an un-muted 'off' pass silently\n"
                     f"       invalidates the loopback cancellation.")


def capture(wav, sink, mic, dur, out):
    p = subprocess.Popen(
        f'timeout {dur} pw-record --target {mic} --rate {SR} '
        f'--channels 2 --format f32 {out}',
        shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.7)
    sh(f'pw-play --target {sink} {wav}')
    time.sleep(1.2)
    p.wait()
    _sr, a = wread(out)
    return a[:, 0]          # one mic capsule: no inter-capsule comb filtering


def spectrum(rec, ref, L, T):
    h = deconv(rec, ess_inverse(ref, L, T))
    q = int(np.argmax(np.abs(h)))
    s = h[q - 128:q - 128 + N].astype(float)
    if len(s) < N:
        s = np.pad(s, (0, N - len(s)))
    return np.fft.rfft(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--reps', type=int, default=4)
    ap.add_argument('--level', type=float, default=-24.0, help='sweep peak, dBFS')
    ap.add_argument('--seconds', type=float, default=6.0)
    ap.add_argument('--sink', default=None, help='substring of the sink node.name')
    ap.add_argument('--mic', default=None, help='substring of the source node.name')
    ap.add_argument('--card', default='0', help='ALSA card index or name for amixer')
    ap.add_argument('--tmp', default='/tmp/speaker-measure')
    a = ap.parse_args()

    if a.self_test:
        return 0 if self_test() else 1

    need('pw-dump', 'pw-play', 'pw-record', 'amixer', 'wpctl')
    os.makedirs(a.tmp, exist_ok=True)
    sink_id, sink = default_node('Audio/Sink', a.sink)
    _mic_id, mic = default_node('Audio/Source', a.mic)
    card = a.card
    switches = speaker_switches(card)
    print(f'sink : {sink}\nmic  : {mic}')
    print(f'mute : {", ".join(switches) if switches else "NONE FOUND"}')
    if not switches:
        print('warning: no speaker mute control found, so the DSP loopback (if any)\n'
              '         cannot be cancelled. Results may be meaningless -- see the\n'
              '         module docstring.')

    vol = sh(f'wpctl get-volume {sink_id}').stdout.strip().split()[-1]
    print(f'note : speaker volume is {vol}; run it high with a low --level '
          f'so the\n       acoustic signal dominates any loopback.\n')

    ref, L, T = ess(T=a.seconds, peak_db=a.level)
    wwrite(f'{a.tmp}/sweep.wav', ref)
    acc = []
    try:
        for i in range(a.reps):
            if switches:
                set_speakers(card, switches, False)
                off = spectrum(capture(f'{a.tmp}/sweep.wav', sink, mic,
                                       int(T + 4), f'{a.tmp}/off{i}.wav'), ref, L, T)
            else:
                off = 0.0
            set_speakers(card, switches, True)
            on = spectrum(capture(f'{a.tmp}/sweep.wav', sink, mic,
                                  int(T + 4), f'{a.tmp}/on{i}.wav'), ref, L, T)
            acc.append(on - off)
            print(f'  rep {i + 1}/{a.reps}', flush=True)
    finally:
        set_speakers(card, switches, True)

    f = np.fft.rfftfreq(N, 1 / SR)
    M = np.array([20 * np.log10(np.abs(x) + 1e-30) for x in acc])
    med = smooth_oct(f, np.median(M, axis=0))
    iqr = smooth_oct(f, np.percentile(M, 75, axis=0) - np.percentile(M, 25, axis=0))
    ref1k = med[np.argmin(abs(f - 1000))]
    band = (f >= 300) & (f <= 8000)
    print(f'\nrepeatability 300 Hz-8 kHz: IQR median {np.median(iqr[band]):.2f} dB '
          f'(>2 dB means something is moving; check for fans, typing, or a DSP sink)\n')
    print(f'{"Hz":>7} {"dB rel 1k":>10} {"IQR":>7}')
    for fr in (100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
               1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500):
        i = np.argmin(abs(f - fr))
        flag = '' if fr >= 200 else '  (gate-limited)'
        print(f'{fr:7d} {med[i] - ref1k:+10.2f} {iqr[i]:7.2f}{flag}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
