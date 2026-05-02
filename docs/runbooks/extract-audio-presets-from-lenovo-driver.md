# Extracting EasyEffects presets from a Lenovo audio driver

How `hosts/pb-x1/audio-presets/` and `hosts/pb-x1/audio-irs/` were
generated, and how to do the same for any new Lenovo host that ships
with **Dolby Atmos / Dolby Audio Premium / DAX3** licensing. Useful
for hosts whose Windows driver embeds precomputed parametric EQ +
multiband + impulse-response data tuned for the specific speaker
hardware in that SKU.

> **NOT applicable to:** hosts with plain Realtek HDA audio and no
> Dolby licensing (e.g. ThinkPad T480, most lower-tier ThinkPad
> models, ThinkBook). These ship a stock Realtek driver with no DAX3
> data — there's nothing to extract. For those hosts, hand-author
> presets from speaker spec sheets / measurements (see
> `hosts/pb-t480/audio-presets/README.md` for an example).

## Background

Lenovo ships a Realtek + Dolby DAX3 (Dolby Atmos for PC) driver
package on its support site for licensed SKUs. The package is an
Inno Setup `.exe` installer wrapping:

- The Realtek HDA codec driver (`.inf` + `.sys` + Win32 service).
- A signed **DAX3 audio configuration database** containing the
  parametric EQ, multiband compressor, and convolver (impulse
  response) coefficients hand-tuned by Dolby + Lenovo's audio team
  for the specific speaker layout in that laptop SKU.

The DAX3 config is keyed by a PCI device + subsystem ID. For the
X1 Yoga Gen 7 it's `DEV_0287_SUBSYS_17AA22E6`. The same file ships
configurations for many SKUs side-by-side; the running driver picks
the one matching the host's `lspci -nn` output.

`speaker-tuning-to-easyeffects` (a third-party tool, not in this
flake) walks the DAX3 database, finds the configuration for a given
SKU ID, and emits one EasyEffects preset JSON + one `.irs` impulse
response file per "tuning preset" (Lenovo's grouping of
genre + balance: Music-Detailed, Movie-Warm, Voice-Balanced, …).

## Recipe

### 1. Identify the SKU

On the live target host, capture the audio device + subsystem ID:

```sh
lspci -nn | grep -iE 'audio|sound'
# typical line:
# 00:1f.3 Audio device [0403]: Intel Corporation Alder Lake PCH-P
#         High Definition Audio Controller [8086:51c8] (rev 01)
#         Subsystem: Lenovo Device [17aa:22e6]
```

The Lenovo SKU key is `DEV_<device>_SUBSYS_<vendor><subsystem>` —
in this example `DEV_51C8_SUBSYS_17AA22E6`. (For the X1 Yoga Gen 7
the relevant key was `DEV_0287_SUBSYS_17AA22E6` — Realtek codec
device id, not the Intel HDA controller; verify by also checking
`cat /proc/asound/card0/codec#0 | head` on Linux for the Realtek
codec id.)

### 2. Download the Lenovo audio driver

Find your machine model on
<https://support.lenovo.com>, navigate to **Drivers & Software →
Audio**, and download the latest **Conexant/Realtek + Dolby Audio
Driver** package. For the X1 Yoga Gen 7 the file was
`n3aa123w.exe` (~25 MiB Inno Setup self-extractor).

If your laptop's driver page doesn't list a "Dolby Audio" or
"Dolby Atmos" component, your SKU is not licensed; skip to the
"hand-author from spec sheets" approach instead.

### 3. Unpack the driver

Inno Setup self-extractors can be unpacked without running Windows:

```sh
nix shell nixpkgs#innoextract
innoextract -e n3aa123w.exe -d ./driver-unpacked
```

The DAX3 configuration database is usually at:

```
driver-unpacked/{app}/RtkApo/DolbyApo/DAX3.{Hxxx}.dat
```

(The specific path varies by driver vintage; search recursively
for `*.dat` files larger than 100 KiB.)

### 4. Run the extractor

Clone <https://github.com/<TBD>/speaker-tuning-to-easyeffects>
(the tool used originally — if the upstream URL has rotted, search
GitHub for "DAX3 EasyEffects extract"; several forks exist). Then:

```sh
speaker-tuning-to-easyeffects \
    --sku DEV_51C8_SUBSYS_17AA22E6 \
    --input driver-unpacked/{app}/RtkApo/DolbyApo/DAX3.Hxxx.dat \
    --output ./extracted \
    --prefix MyHost
```

This produces, in `./extracted/`:

- One `MyHost-<Genre>-<Balance>.json` EasyEffects preset per
  tuning the Dolby team authored for this SKU. Typical set: Music,
  Movie, Voice, Game, Dynamic, Voice_Onlinecourse, Personalize_User1-3,
  each in Balanced/Detailed/Warm balance flavors. ~27 presets total.
- One `MyHost-<Genre>-<Balance>.irs` impulse response per preset
  (32-bit float WAV @ 48 kHz, ~32 KiB each). Each preset's
  `convolver#0.kernel-name` references its matching IRS by the
  basename without extension.

### 5. Drop into the host's directory

```sh
mkdir -p hosts/<hostname>/audio-presets hosts/<hostname>/audio-irs
cp ./extracted/*.json hosts/<hostname>/audio-presets/
cp ./extracted/*.irs  hosts/<hostname>/audio-irs/
git add hosts/<hostname>/audio-presets hosts/<hostname>/audio-irs
```

`git add` is mandatory — the flake build only sees git-tracked
files (AGENTS.md gotcha #1).

### 6. Wire the host bridge

In `flake-modules/hosts/<hostname>.nix`, set the audio options:

```nix
audio = {
  presetsDir = ../../hosts/<hostname>/audio-presets;
  irsDir     = ../../hosts/<hostname>/audio-irs;
  autoloads  = [
    {
      device = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
      profile = "Speaker";
      description = "<lspci description of the audio controller>";
      preset = "MyHost-Dynamic-Detailed";  # pick your daily-driver
    }
    # add more entries for other sinks (HDMI, BT headphones, …)
  ];
};
```

The `device` and `profile` strings come from
`./scripts/host-setup.sh --audio-discover` run on the live host
(see `--help` for details).

### 7. Rebuild + activate

```sh
sudo nixos-rebuild switch --flake .#<hostname>
home-manager switch --flake .#'<user>@<hostname>'
systemctl --user restart easyeffects
```

`wpctl status` should show the EasyEffects sink wired in front of
your real ALSA sink, and the convolver should be processing.

## Caveats

- **Per-SKU only.** The extracted presets are tuned for the
  specific speaker hardware + cabinet of one laptop SKU. They will
  sound noticeably worse than passthrough on a different model
  (the convolver IRS represents that exact speaker's frequency
  response inverted). Don't share presets across SKUs.
- **Headphones.** The convolver IRS is for the built-in speakers
  only. Apply to bluetooth / wired headphones via a different
  preset (or none). The per-sink autoload schema in
  `flake-modules/audio.nix` makes this explicit — sinks without an
  autoload entry stay flat.
- **License.** The extracted DSP coefficients are Dolby IP. They're
  embedded in the driver Lenovo paid Dolby to ship with this
  laptop, so end-user use on the same laptop is implicitly
  licensed. Don't redistribute the extracted files outside that
  context. (The IRS files in this repo are committed because the
  flake repo is private to the laptop's owner.)
- **Driver updates.** Every Lenovo audio driver release re-tunes
  the presets. Re-extract after a major driver bump if you notice
  the upstream sound has changed.

## Retire when

You stop running EasyEffects (e.g. moving DSP into native
PipeWire filter graphs declaratively), OR Lenovo stops shipping
Dolby DAX3 entirely (e.g. moving to LE Audio + endpoint-side DSP),
OR a Linux-native equivalent driver appears that reads the DAX3
database directly (the Linux kernel already has a Sound Open
Firmware path; Dolby coefficient parsing in mainline would obviate
this whole runbook).
