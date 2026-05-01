# Bluetooth: BlueZ + blueman + quickshell chip/flyout

Date: 2026-05-01.

## Context

Pre-bluetooth state: bluetooth was completely unconfigured anywhere
in the flake. No `hardware.bluetooth.enable`, no system packages,
no quickshell UI, no audio codecs configured. Kid accounts on
pb-t480 and the adult on both laptops had no way to use a Bluetooth
headset, mouse, or controller.

Goal: full bluetooth experience — bar chip with status icon,
click-out flyout with paired-device list and inline pairing UI
(scan, PIN/passkey overlay, connect/disconnect/forget), high-quality
audio (HFP wideband voice + LDAC/aptX/aptX-HD), and an escape hatch
(blueman applet) for corner cases the quickshell flyout can't
handle.

Hosts in scope: pb-x1 (admin) and pb-t480 (admin + 2 kids). Skip
wsl (no audio/radio) and ah-1 (NAS, no users at console).

## Decisions

1. **Full pairing UI in the flyout**, not a read-only chip. The
   blueman applet sits in the SystemTray as a fallback for PINs the
   quickshell flow can't capture (e.g. passkey-confirm-on-display
   pairings of older car stereos).
2. **HFP + LDAC/aptX/aptX-HD/AAC enabled**. Codec preference order
   is highest-quality first; PipeWire negotiates the first the
   peer also supports.
3. **Kids get the same bluetooth as adults** — including blueman
   applet and the polkit bypass. The original draft restricted
   pairing to wheel; user direction was to drop the asymmetry.
   Polkit rule was rewritten to grant on `subject.local &&
   subject.active` (per-seat, not per-group), the standard polkit
   idiom for "physically present at this seat".
4. **bluetoothctl, not D-Bus directly.** Quickshell.Io ships
   Process / SplitParser / StdioCollector cleanly; binding QML to
   org.bluez.* would need a Qt QDBus wrapper module not present in
   vanilla Quickshell. bluetoothctl already does the introspection
   and ships in the bluez package we install at the system level.

## Implementation

### Commit A — `bluetooth: BlueZ + blueman + HFP/LDAC/aptX on pb-x1 + pb-t480`

New cross-class module `flake-modules/bluetooth.nix`:

NixOS class:
- `hardware.bluetooth.enable = true`, `powerOnBoot = true`,
  `settings.General.Experimental = true`. Experimental exposes
  `org.bluez.Battery1` for headset battery levels and is stable
  on BlueZ ≥ 5.65.
- Polkit JS rule: `subject.local && subject.active` grants every
  `org.bluez.*` and `org.blueman.*` action without an auth prompt.
  Modern rules.d API (deprecated .pkla loader is going away in
  polkit ≥ 0.121). Mirrors how we handle bitwarden in
  flake-modules/biometrics.nix.
- `environment.systemPackages = [ pkgs.bluez pkgs.bluez-tools ]`.
  bluez-tools provides `bt-adapter` / `bt-agent` / `bt-device`;
  bluez itself supplies `bluetoothctl`, which is what
  BluetoothState.qml shells out to.
- WirePlumber `51-bluez-config` block: HFP with mSBC wideband
  voice, SBC-XQ, codec preference `[ ldac, aptx_hd, aptx, aac,
  sbc_xq, sbc ]`, BAP LE-Audio sink/source roles. Uses the new
  SPA-JSON config loader (wireplumber 0.5+).

Home-manager class:
- `home.packages = [ pkgs.blueman ]`.
- `systemd.user.services.blueman-applet`: autostart under
  graphical-session.target, `Restart = "on-failure"`. Tray icon
  lands in quickshell's existing SystemTray automatically.

Cross-module signal:
- `options.bluetooth.enable` (mkOption, default false), set to true
  by mkDefault inside the module body when imported. Mirrors the
  pattern in `biometrics.nix` so future modules can read
  `config.bluetooth.enable` to gate UI without coupling to a
  host-level toggle.

Wired into:
- `hosts/pb-x1.nix` (NixOS imports)
- `hosts/pb-t480.nix` (NixOS imports)
- `bundles/home-desktop.nix` (covers p@pb-x1, p@pb-t480)
- `bundles/home-kid.nix` (covers m@pb-t480, s@pb-t480)

### Commit B — `quickshell: bluetooth chip + flyout with full pairing UI`

Three new QML files plus qmldir + Bar.qml wiring.

`quickshell/qml/BluetoothState.qml` — singleton, mirrors
NetworkState.qml shape:
- Long-running `bluetoothctl --monitor` event source, debounced
  (250ms) re-read of `bluetoothctl show` (controller state) and
  `bluetoothctl devices` followed by sequential `bluetoothctl info
  <mac>` walk for per-device details.
- Reactive properties: `powered`, `discovering`, `pairedList`,
  `connectedCount`, `pairingMac`, `pinPromptMac`, `pinPromptText`,
  `lastError`.
- Methods: `refreshAll`, `setPowered`, `startScan`/`stopScan`,
  `pair`, `confirmPin`/`cancelPin`,
  `connectDevice`/`disconnectDevice`, `removeDevice`, `trust`.
- PIN/passkey flow: long-lived interactive `bluetoothctl` with
  stdin enabled; agent prompt lines (`[agent] Enter PIN code:`,
  `[agent] Confirm passkey 123456 (yes/no):`) are parsed out of
  stdout (ANSI escapes stripped) and surfaced via
  `pinPromptMac`/`pinPromptText` for the flyout overlay.

`quickshell/qml/bar/Bluetooth.qml` — chip:
- Material Symbols icon swaps `bluetooth_disabled` /
  `bluetooth` / `bluetooth_connected` / `bluetooth_searching`.
- Optional label: connected device name (1 device) or count (>1).
- Same MouseArea + 600ms tooltip pattern as Network.qml.

`quickshell/qml/bar/flyouts/BluetoothFlyout.qml` — flyout (mirrors
NetworkFlyout.qml + adds scan & pairing):
- Header: controller power state + scan toggle (auto-starts scan
  when flyout opens, stops on close).
- Paired devices: device-icon by BlueZ Icon class
  (audio→headphones, phone→smartphone, …), battery pill
  (green/yellow/red bands), link/link_off action icon. Left-click
  = connect/disconnect, right-click = forget.
- Discovered devices (during scan): pair button per row, spinner
  while `pairingMac` matches the row.
- PIN/passkey overlay: shown when `pinPromptMac !== ""`, with
  TextInput + OK/Cancel routed to `confirmPin`/`cancelPin`.
- Footer: turn-off/turn-on toggle.
- Last-error text inline if a pair attempt fails.

Bar.qml wiring (4 spots): chip in `rightGroup2` between Network
and Volume; `bluetoothCX` reactive property; BarTooltip; flyout
instantiation. qmldir registers the singleton, chip, and flyout.

## Smoke build

`NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure` over all 10
closures, twice (once after each commit). Per-closure outcomes:

| Closure              | Commit A | Commit B | Reason                          |
| -------------------- | -------- | -------- | ------------------------------- |
| pb-x1 NixOS          | changed  | unchanged | bluetooth NixOS module          |
| pb-t480 NixOS        | changed  | unchanged | bluetooth NixOS module          |
| wsl NixOS            | baseline | baseline | not in scope                    |
| ah-1 NixOS           | baseline | baseline | not in scope                    |
| p@pb-x1 HM           | changed  | changed   | blueman + new QML               |
| p@pb-t480 HM         | changed  | changed   | blueman + new QML               |
| m@pb-t480 HM         | changed  | changed   | blueman + new QML (kid bundle)  |
| s@pb-t480 HM         | changed  | changed   | blueman + new QML (kid bundle)  |
| p@wsl HM             | baseline | baseline | no quickshell, no bluetooth     |
| nas@ah-1 HM          | baseline | baseline | no quickshell, no bluetooth     |

All four "out-of-scope" closures (wsl, ah-1, p@wsl, nas@ah-1) stayed
byte-identical across both commits — bluetooth is correctly scoped
to the two laptop hosts.

## Mistake along the way

`nix fmt -- <files>` blindly invokes `nixpkgs-fmt` on whatever paths
you pass; it does NOT filter by extension. After staging the QML
files I ran `nix fmt -- <list-with-qml-and-qmldir>` and the
formatter mangled all five files (treating them as Nix). Recovery
worked because I had already `git add`-ed the originals — `git
checkout -- <files>` restored the staged copies.

Lesson: always invoke bare `nix fmt` (which the perSystem formatter
binding scopes to `*.nix` only). If for some reason individual
files need formatting, filter the file list to `*.nix` first.

## Follow-ups (not done in this session)

- **Wire bluetooth audio into EasyEffects.** EasyEffects only
  applies its preset to a specific PipeWire sink (the X1 Yoga
  speaker, by node-name). When a Bluetooth headset connects it
  becomes the default sink but EasyEffects ignores it. This isn't
  a regression (it's the existing audio.nix design) but it is
  surprising: the user expects DSP to follow them onto the
  headset. Fix would be either (a) add an EasyEffects autoload rule
  for each headset sink, or (b) add a generic `bluez_output.*`
  rule with a different (headset-suitable) preset.
- **MIDI / aptX-Adaptive.** Snapdragon Sound and aptX-Adaptive
  aren't in our codec preference list because they're not in
  upstream pipewire's bluez codec set yet (gpl-incompatible
  blob). Revisit once `services.pipewire-aptx-adaptive` becomes
  a thing.
- **Bluetooth in the lockscreen.** Today, if the user pairs their
  phone for unlock-by-proximity, there's no quickshell affordance
  for it. Could be a future addition to the LockScreen UI using
  the same BluetoothState singleton.
- **Tests.** No automated test of the BluetoothState parsing
  logic. The bluetoothctl output format is stable but a `quickshell
  --headless` test harness reading canned bluetoothctl output via
  a mock Process would catch regressions.
