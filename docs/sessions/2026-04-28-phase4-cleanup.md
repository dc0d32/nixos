# 2026-04-28 — Phase 4 cleanup

## Goal

Continue the post-Phase-3 code-smell sweep. One P0 (broken lockscreen
wallpaper), eleven P1 items (event-driven QML extractions, schema drift,
deploy-time policy, redundant declarations), and six P2 hygiene fixes
(orphan files, stale comments, sentinel unification).

## Context

Continues from `2026-04-28-phase3-cleanup.md`. Phase 3 introduced
`NiriState`, `Pipewire` subscription in `Volume.qml`, and udev events for
`Brightness.qml`, but the *flyouts* and *OSDs* for those subsystems were
left polling. A fresh review surfaced four more shell features that still
poll subprocesses behind the scenes (`Battery`, `BatteryFlyout`,
`BrightnessFlyout`, `VolumeFlyout`, `Network`, `NetworkFlyout`) plus a
triplicated MPRIS player-selection expression. Independent items rolled in:
host variables.nix files had drifted (some flags missing, some sentinels
inconsistent), three `configuration.nix` files re-declared options already
set by `modules/nixos/*`, and `extras.nix` had ssh-agent gated with the
wrong default polarity.

## Changes

### 1. `LockScreen.qml` — wallpaper path fix (P0)

The wallpaper Image's `source` referenced `root.wallpaperPath`, an
undefined property. The lock screen rendered with a black background. Set
the path explicitly to
`"file://" + Quickshell.env("HOME") + "/.wallpaper/current.jpg"`. The
`current.jpg` symlink is created unconditionally by
`modules/home/desktop/wallpaper.nix` regardless of source extension, so
hardcoding `.jpg` is correct.

### 2. `BatteryState.qml` — event-driven UPower wrapper

New singleton at `modules/home/desktop/quickshell/qml/BatteryState.qml`.
Wraps `Quickshell.Services.UPower.displayDevice` (already used by the
existing `PowerProfile` chips, so no new service dependency). Surfaces:

- `present` — `displayDevice.isLaptopBattery && isPresent` (chips hide
  on desktops / hosts without a battery)
- `percent` — rounded `displayDevice.percentage`
- `charging` — `state === UPowerDeviceState.Charging`
- `status` — derived `Charging` / `Discharging` / `Full` / `Unknown`
- `timeLeft` — humanised `1h 23m` / `45m` / `""`

Replaces the two `Process` blocks in `Battery.qml` and `BatteryFlyout.qml`
that ran `sh -c "for b in /sys/class/power_supply/BAT*; ..."` every 10 s
to read `capacity`, `status`, `time_to_empty_now`, and `time_to_full_now`
out of sysfs. Both files are now pure renderers binding to the singleton.
Net: 1 D-Bus subscription replaces 2 sysfs-polling subprocesses, and the
percentage updates immediately when UPower notices a change rather than
on the next 10 s tick.

### 3. `BrightnessState.qml` — udev event subscription

New singleton consolidating the udev-monitor + `brightnessctl get/max`
flow that already existed in `Brightness.qml` (chip) but was *not* in
`BrightnessFlyout.qml` — the flyout was running its own 200 ms `Timer`
to re-run `brightnessctl get` while open. Both files now bind to
`BrightnessState.percent`. The flyout slider's `value` binding gates on
`!slider.pressed` so a user drag isn't fought mid-stroke by the singleton
push.

### 4. `VolumeState.qml` — Pipewire wrapper + sink-name resolution

New singleton wrapping `Pipewire.defaultAudioSink` (event-driven, already
used by `VolumeOsd.qml` and `Volume.qml` chip). Adds a derived `sinkName`
that falls through `nickname → description → name → "Default Sink"`,
replacing the `wpctl status | awk '/Audio/,0' | grep -m1 '\\*' | sed
's/.*\\* //;s/ \\[.*//'` pipeline in `VolumeFlyout.qml`. Owns the
`PwObjectTracker` so all consumers share one binding. `Volume.qml`,
`VolumeFlyout.qml`, and `VolumeOsd.qml` are now pure renderers.

`VolumeFlyout.qml` lost its 200 ms `Timer` polling `wpctl get-volume` and
the `sinkPoller` Process. `VolumeOsd.qml`'s `Connections { target:
Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null }` is
now `Connections { target: VolumeState.audio }` — same semantics, the
indirection lives in the singleton.

### 5. `NetworkState.qml` — `nmcli monitor` event source

New singleton replacing two 5-second `Timer`-driven `nmcli` poller pairs
(one per widget) with a single long-running `nmcli monitor` subprocess.
Each summary line from `nmcli monitor` triggers a 250 ms-debounced
re-read of connection state and AP scan. Surface:

- `currentSsid`, `currentState` (`wifi`/`wired`/`off`), `currentIface`
- `apList` — `[{ssid, signal, secured, inUse}]` sorted by signal
- methods: `tryConnect(ssid)`, `connectWithPassword(s, p)`, `disconnect()`
  (dispatched via `Quickshell.execDetached([...])` — replaces the
  anti-pattern of mutating `Process.command` at runtime in
  `NetworkFlyout.qml`)

`Network.qml` chip is pure rendering. `NetworkFlyout.qml` keeps only
the inline password-prompt UX state (`pendingSsid`, `showPassField`,
`connectError`) plus a `checkTimer` to detect silent auth failures.
The `connector`/`disconnector` Process blocks and the
`onRunningChanged → postConnectTimer` chain are gone — `NetworkState`
fires its own post-connect re-read after each `execDetached`.

### 6. `MediaState.qml` — MPRIS player selector

The expression `Mpris.players.values.find(p => p.playbackState ===
MprisPlaybackState.Playing) || Mpris.players.values[0] || null` was
copy-pasted across `Media.qml`, `MediaFlyout.qml`, and `MediaOsd.qml`,
and it was *not* reactive to player appearance/disappearance — it was
evaluated as a property binding but `Mpris.players` is a `QObject`-typed
container without a values-changed property notification on every
mutation, so a newly-appearing player wouldn't be picked up until
something else triggered re-evaluation.

New singleton uses an explicit `Connections { target: Mpris.players;
function onValuesChanged() { _select() } }` plus a second `Connections
{ target: root.player }` that re-selects when the current player's
`playbackState` flips (so a paused player yields to a newly-playing
one). All three consumers now read `MediaState.player`.

### 7. `MediaOsd.qml` — `armed` startup gate

Mirrors the pattern from `VolumeOsd.qml:24-25`: a 1.5 s `Timer` flips
`armed = true`, and the `onTrackTitleChanged` handler ignores the
initial bind. Without this, restarting quickshell while music plays
would immediately pop the now-playing OSD with the current track.

### 8. `niri.nix` — dead let-binding

`modules/home/desktop/niri.nix` had a `let` block defining `wpcfg` and
`wallpaperDir` that no consumer in the file references (a previous
refactor moved wallpaper handling into its own module). Removed.

### 9. `login-ly.nix` — `mkForce` → `mkDefault`

The three `services.xserver.displayManager.{gdm,sddm,lightdm}.enable =
mkForce false` lines used `mkForce` to defeat the NixOS default of
enabling gdm. But `ly` only requires that *one* DM is the chosen one,
not that the others can never be re-enabled by a downstream override
(e.g., a host that wants to switch DM without disabling ly first). Changed
to `mkDefault false` and updated the comment to reflect that hosts can
override.

### 10. `extras.nix` — ssh-agent default polarity

`services.ssh-agent.enable = lib.mkDefault (variables.sshAgent.enable
or true)` and the matching `optionalAttrs` for `SSH_AUTH_SOCK` defaulted
to `true`. Every host in the repo (laptop, wsl, wsl-arm, template) sets
`sshAgent.enable = false`, but the `or true` would silently re-enable
ssh-agent if the key were ever missing from a host's variables. Changed
both to `or false` — fail-safe, matches every host's actual intent, and
aligns with the comment "Disable if using a hardware key (YubiKey) or a
secrets manager instead." which implies opt-in not opt-out.

### 11. Schema drift — host variables.nix completeness

`modules/home/desktop/wallpaper.nix`, `apps/bitwarden.nix`,
`biometrics.nix`, and `desktop/waybar.nix` all read their respective
flags via `or { enable = false; }` / `or false` defaults, so missing
keys never broke a build — but they made it impossible to scan a host's
`variables.nix` and see *all* the toggles for that host at a glance.

Added the missing keys explicitly as `enable = false`:

- `desktop.wallpaper` block to `wsl/variables.nix` and
  `wsl-arm/variables.nix`
- `desktop.waybar.enable` to `laptop/variables.nix` (and reordered to
  match the template's "pick ONE bar" comment)
- `biometrics.enable` to both WSL hosts
- `apps.bitwarden.enable` to both WSL hosts

`audio.easyeffects.enableConvolver` was the inverse — declared in two
hosts and the template but read by no module. Removed from both WSL
hosts, the template (`hosts/_template/variables.nix`), and the
scaffolder (`apps/new-host.nix`).

Stale `# monitors = [...]` comment-blocks on every host's
`variables.nix` were redundant with the same example in the template;
removed from the three real hosts so the template remains the single
copy.

### 12. Redundant declarations in host configuration.nix files

`hosts/{laptop,wsl,wsl-arm}/configuration.nix` all set
`programs.zsh.enable = true` and `nix.settings.experimental-features =
[ "nix-command" "flakes" ]`, but `modules/nixos/users.nix` and
`modules/nixos/nix-settings.nix` already set both. `laptop/
configuration.nix` additionally set `time.timeZone` and
`i18n.defaultLocale` already set by `modules/nixos/locale.nix`.
Deleted all redundant lines (replaced with a single comment pointing at
the responsible modules).

### 13. P2 hygiene

- `overlays/nvim-treesitter-pin.nix` comment got a `Rechecked
  2026-04-28: nixpkgs#tree-sitter still 0.25.10` line so the next
  reviewer doesn't have to re-check `nix eval`.
- `hosts/wsl/variables.nix` git sentinel changed from
  `none/none@none.com` to `CHANGEME/CHANGEME@example.com`, matching the
  other hosts and template (one less surprise for a `git rebase`er).
- `homes/p@wsl-arm/variables.nix` comment said `# stateVersion =
  "24.11"` while the host's actual stateVersion is `25.11`. Fixed.
- Deleted orphan
  `modules/home/desktop/quickshell/qml/bar/FlyoutBackdrop.qml` — its
  own header noted it was unused and it wasn't registered in `qmldir`.

### 14. `qmldir` registrations

Added five lines to
`modules/home/desktop/quickshell/qml/qmldir`:

```
singleton BatteryState 1.0 BatteryState.qml
singleton BrightnessState 1.0 BrightnessState.qml
singleton VolumeState 1.0 VolumeState.qml
singleton NetworkState 1.0 NetworkState.qml
singleton MediaState 1.0 MediaState.qml
```

## Verification

- `nix flake check` → all checks passed
- `nix build .#nixosConfigurations.laptop.config.system.build.toplevel --no-link` → ok
- `nix build .#nixosConfigurations.wsl.config.system.build.toplevel --no-link` → ok
- `nix build .#homeConfigurations."p@laptop".activationPackage --no-link` → ok
- `nix eval .#nixosConfigurations.wsl-arm.config.system.build.toplevel.drvPath`
  → returned `.drv` (aarch64 build needs aarch64 host)
- `nix fmt` → no diffs

Not switched (per AGENTS.md). The QML singletons take effect after
`home-manager switch` + a quickshell restart; the locale/zsh-redundancy
removals take effect after `nixos-rebuild switch` (no behavioral change
expected — modules already set the same values).

## Files

Created:
- `modules/home/desktop/quickshell/qml/BatteryState.qml`
- `modules/home/desktop/quickshell/qml/BrightnessState.qml`
- `modules/home/desktop/quickshell/qml/VolumeState.qml`
- `modules/home/desktop/quickshell/qml/NetworkState.qml`
- `modules/home/desktop/quickshell/qml/MediaState.qml`
- `docs/sessions/2026-04-28-phase4-cleanup.md`

Modified:
- `apps/new-host.nix` (drop `enableConvolver` from generated template)
- `homes/p@wsl-arm/variables.nix` (comment 24.11 → 25.11)
- `hosts/_template/variables.nix` (drop `enableConvolver`)
- `hosts/laptop/configuration.nix` (drop redundant tz/locale/zsh/nix-features)
- `hosts/laptop/variables.nix` (add `desktop.waybar.enable`, drop monitors comment)
- `hosts/wsl/configuration.nix` (drop redundant zsh/nix-features)
- `hosts/wsl/variables.nix` (add wallpaper/biometrics/bitwarden flags,
  drop `enableConvolver`, unify git sentinel, drop monitors comment)
- `hosts/wsl-arm/configuration.nix` (drop redundant zsh/nix-features)
- `hosts/wsl-arm/variables.nix` (add wallpaper/biometrics/bitwarden
  flags, drop `enableConvolver`, drop monitors comment)
- `modules/home/desktop/extras.nix` (ssh-agent polarity → `or false`)
- `modules/home/desktop/niri.nix` (drop dead `wpcfg`/`wallpaperDir` let)
- `modules/home/desktop/quickshell/qml/qmldir` (5 new singleton lines)
- `modules/home/desktop/quickshell/qml/bar/Battery.qml` (renderer-only)
- `modules/home/desktop/quickshell/qml/bar/Brightness.qml` (renderer-only)
- `modules/home/desktop/quickshell/qml/bar/Media.qml` (use `MediaState`)
- `modules/home/desktop/quickshell/qml/bar/Network.qml` (use `NetworkState`)
- `modules/home/desktop/quickshell/qml/bar/Volume.qml` (use `VolumeState`)
- `modules/home/desktop/quickshell/qml/bar/flyouts/BatteryFlyout.qml`
- `modules/home/desktop/quickshell/qml/bar/flyouts/BrightnessFlyout.qml`
- `modules/home/desktop/quickshell/qml/bar/flyouts/MediaFlyout.qml`
- `modules/home/desktop/quickshell/qml/bar/flyouts/NetworkFlyout.qml`
- `modules/home/desktop/quickshell/qml/bar/flyouts/VolumeFlyout.qml`
- `modules/home/desktop/quickshell/qml/lock/LockScreen.qml` (P0 fix)
- `modules/home/desktop/quickshell/qml/media/MediaOsd.qml` (use
  `MediaState`, add armed gate)
- `modules/home/desktop/quickshell/qml/osd/VolumeOsd.qml` (use
  `VolumeState`)
- `modules/nixos/desktop/login-ly.nix` (`mkForce` → `mkDefault`)
- `overlays/nvim-treesitter-pin.nix` (rechecked-date note)

Deleted:
- `modules/home/desktop/quickshell/qml/bar/FlyoutBackdrop.qml`

## Follow-ups (not done this session)

- `MediaFlyout.qml` still has a 1 s `Timer` updating `position` because
  MPRIS doesn't push `Position` notifications during normal playback
  (clients are expected to interpolate or poll). The interval matches
  the visible second-tick on the time labels; can't easily replace.
- `NetworkState`'s `nmcli monitor` parser ignores the actual content of
  monitor lines and just debounces all of them into a refresh. A more
  surgical implementation would dispatch on the event kind (e.g. only
  re-scan on `wifi-scan-completed`), but the current behavior is
  correct and the work-amplification is small.
- `BatteryState.percent` is rounded; if a future battery widget needs
  the unrounded float (e.g. for sub-percent transitions on a wide
  progress bar), expose a `percentRaw` alongside.
- `desktop.wallpaper` is now declared as `enable = false` on the WSL
  hosts purely for self-documentation; the module already defaulted to
  off via `or { }`. If `wallpaper.nix` ever grows required keys, the
  explicit declaration becomes load-bearing.
