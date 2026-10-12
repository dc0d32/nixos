# 2026-10-11 — Side-by-side terminal trials

## Decision

Trial Ghostty and WezTerm on GUI Linux accounts and `p@pb-mb`; trial WezTerm
beside Windows Terminal on native Windows. No winner or default change yet.
Alacritty and its niri launch bindings, Terminal.app, and Windows Terminal's
existing settings remain unchanged. Headless WSL/server accounts do not install
Unix GUI terminals. Rio is excluded.

`flake-modules/terminal-trials.nix` publishes common appearance and shortcut
intent plus the Lua configuration consumed by `windows/windows.nix`. The
desktop and kid bundles and the Mac bridge opt in. Appearance is derived from
`flake.lib.alacrittySettings`: Fantasque Mono Regular, Alacritty's default
palette (not Windows Terminal's Campbell), eight-pixel padding and a steady beam.
Font sizes are 12pt Unix / 13pt Windows; Windows intentionally uses the custom
patched Terminal Nerd Font family. WezTerm keeps 100,000 lines; Ghostty's
byte-based budget is 102,400,000 bytes (1 KiB per configured history line).
Linux trials use borderless windows and the same niri 0.85 compositor opacity
as Alacritty, without multiplying it by application-side transparency.
macOS and Windows retain native decorations and opaque backgrounds.
Titles follow the shell/application, not fixed profile names.

Unix starts login zsh; Windows prefers native PowerShell 7, falling back to
Windows PowerShell. No automatic tmux/psmux attachment or built-in SSH/WSL
domains. External `ssh` remains an ordinary command.

## Pin and provenance

WezTerm is **20261010-083911-e2a98e1b**, upstream commit
`e2a98e1b8af156988ad0ac778658ac27b60a55fb` (2026-10-10).
`overlays/wezterm-pin.nix` is the single provenance record.

- Linux and macOS build exact source from the nonflake `wezterm-src` input
  in `flake.lock`, including submodules and hashed Cargo dependencies.
  macOS builds natively, assembles `WezTerm.app`, and ad-hoc signs executables
  and the app after fixup. This is not an upstream notarized universal app.
  Nix caches the source build normally; no nightly Darwin download remains.
- Windows temporarily pins the upstream **x64** archive, asset **629718573**,
  SHA-256
  `a7ae0ae77a8e72f459157c83fb154353ab7185908dbae947559b57b624381516`.
  The architecture-keyed pin has a null ARM64 bootstrap entry because no native
  upstream asset exists for this snapshot. The installer detects native AMD64
  versus ARM64 and refuses ARM64 until a promoted native pin exists; it never
  silently installs x64 under emulation.

The x86-64 Windows pin is explicitly **bootstrap-unpromoted**, not a durable
completed pipeline release. Its previously verified identity matches the source pin.
Only `hm_win --setup` (or direct invocation of the staged installer) downloads
it through the anonymous asset-ID API with `Accept: application/octet-stream`.
Deleted assets fail closed; hashes prevent drift. Ordinary `hm_win`
builds/stages only the manifest, Lua and installer and does not depend on this
deletable archive.

Ghostty is the locked nixpkgs **1.3.1**: `ghostty` on Linux and the native,
signed `ghostty-bin` on Darwin. The flake lock pins those package definitions.
In-application update checks are disabled for both trials.

WezTerm's renderer is deliberately **unset**. Its documented default detects
Windows RDP and selects Software automatically:
<https://wezterm.org/config/lua/config/front_end.html>.
No Mesa DLL injection, forced renderer, or speculative fallback launcher.

## Launch and compare

User activation:

```sh
home-manager switch --flake .#'p@pb-mb' # or the GUI Linux account
```

Launch Ghostty or WezTerm from the application menu; macOS apps appear in Home
Manager's application directory. Shell commands are `ghostty` and `wezterm start`.
HM collision checks protect existing config files; move/back up any conflicting
local config before activation rather than forcing replacement.

On Windows, deploy only with ordinary `hm_win`, or install/update the toolkit,
register the patched fonts and install the isolated WezTerm Trial together:

```sh
hm_win --setup
```

The setup path runs the existing winget/Scoop toolkit installer, registers the
font, then installs WezTerm Trial and creates its Start-menu shortcut. It does
not change terminal defaults. Ordinary `hm_win` stages the shared Lua file and installer under
`%USERPROFILE%\.config\nixwin\wezterm-trial\<bundle>` without running it.
The explicit installer copies Lua to
`%USERPROFILE%\.config\nixwin\wezterm-trial\config\wezterm.lua`; the shortcut's
`--config-file` selects only that isolated trial config. Neither command touches
standard WezTerm configs (including `.config\wezterm\wezterm.lua` and
`.wezterm.lua`). Binary installs live in architecture-specific content-addressed
`%LOCALAPPDATA%\nixwin\wezterm-trial\<architecture>\<version>-<sha256>`
directories; running builds are never overwritten. Config changes apply to the
next explicit deployment.

Primary modifier is **Cmd** on macOS, **Ctrl+Shift** elsewhere:

| Primary + key | Action |
| --- | --- |
| C / V / F | Copy / paste / search |
| = / - / 0 | Increase / decrease / reset text size |
| T / N / W | New tab / new window / close pane with confirmation |
| D / E / Z | Split right / split down / zoom pane |
| Alt + arrows | Focus adjacent pane |

Ctrl+Tab / Ctrl+Shift+Tab switch tabs. Shift+PageUp/Down scroll history.
WezTerm also scrolls plain PageUp/Down on the primary screen and forwards them
inside alternate-screen applications. Ghostty leaves plain paging to the child;
use Shift for terminal history. Shell Ctrl+C is not overridden.
Existing Windows Terminal shortcuts/presentation stay as they were.

Compare locally and over SSH/RDP: normal text, Braille/clock/triangle glyphs,
search, shell interrupts, paging in `less`/vim, tabs/panes, copy/paste and zoom.
The niri trials now match Alacritty's compositor opacity; other platforms remain
opaque. Interactive macOS GUI, Linux desktop and Windows/RDP comparisons are
still host-side trials, not claimed as completed by configuration validation.

## Update and rollback

No floating nightly or in-session binary update. Saturday's coordinator updates
other flake inputs and publishes `.github/wezterm-request.json` on
`automation/update-flake-lock`, leaving active WezTerm pins untouched. The
request contains an exact upstream SHA and identity bound to the weekly cycle.
Unrelated updates continue if upstream request resolution fails.

The separate public **dc0d32/wezterm-builds** service polls hourly or runs
manually. It accepts only an open same-repository weekly PR, builds that exact
`wezterm/wezterm` revision and submodules for native x86-64 and ARM64 on a
read-only Windows runner using upstream's build, Nextest and packaging
procedure, then publishes on a fresh runner. Its writer executes only trusted
control scripts, never upstream code. Permanent release tags/assets are
source/run/attempt-addressed, include both architecture-qualified ZIPs,
schema-2 provenance and SHA256SUMS, require GitHub release immutability, and are
never overwritten.
Successful releases are reused by source SHA; full retries get a new attempt ID.

The NixOS hourly promotion coordinator verifies the immutable four-asset
release, exact source, both checksums, native PE machine types, architecture-
specific ZIP contents, successful run/jobs and still-current open
PR/request/head/base.
It discovers source/Cargo hashes with trusted locked Nix tooling, then updates
Unix source lock/version/hashes and Windows URL/hash together on the existing
weekly PR using a compare-and-swap commit. Closed/merged/superseded requests and
failed checks leave active pins unchanged. Cross-repository reads and writes
cannot form one transaction; final rechecks and exact-head CAS bound this race.

Only each repository's own narrowly scoped `GITHUB_TOKEN` is used: no PAT,
GitHub App, dispatch secret or credential-bearing URL. Actions use reviewed full
SHAs; candidates compile/check without exposed tokens. Token-created PRs do
**not** trigger normal CI: the coordinators explicitly run the same native Linux
`nix flake check --print-build-logs` and report `wezterm/native-linux` on the exact
head. Promotion separately checks the proposed tree before publication and the
published head afterward; success is never copied from an old head.

Owner setup, trust boundaries, commands and recovery are documented in
[`scripts/wezterm-bootstrap.txt`](../../scripts/wezterm-bootstrap.txt).
The build-only payload is prepared outside this repository at
`/Users/p/.copilot/session-state/f75bed34-1ece-4b84-9adb-5b9435c3154a/files/wezterm-builds`.
Nothing has been committed, pushed or created remotely. The owner must authorize
publishing both implementations, enable PR creation in NixOS and release
immutability in the public build repository, run the weekly request, run the
initial Windows build, and allow promotion before merging. Windows remains
bootstrap/unpromoted until that real release passes validation.

Ghostty changes through the ordinary flake-lock update and normal activation.

Unix rollback: use a previous Home Manager generation, or remove trial imports
and activate; defaults require no restoration. Windows rollback: close the trial,
repoint `WezTerm Trial.lnk` to a retained version's `wezterm-gui.exe` with
`--config-file` pointing to a compatible retained/backed-up Lua config, or deploy
the earlier checkout with `hm_win --setup`. Config backups use `.bak.<stamp>`.
To remove Windows trial, delete its shortcut,
`%LOCALAPPDATA%\nixwin\wezterm-trial` and
`%USERPROFILE%\.config\nixwin\wezterm-trial` after closing the app.
Standard WezTerm configs need no restoration.

## Verification

- Native source-built `p@pb-mb` activation build: exit 0, without activation or
  sudo. Output:
  `/nix/store/1hzvlzxc3rn5n6z12djvv5fp2ayj73ag-home-manager-generation`.
- WezTerm source tests: 361 passed, one ignored doctest. Native app/resource
  checks and Apple strict/deep signature verification passed.
- Ghostty `+validate-config` and pinned WezTerm `show-keys` on the actual
  generated Unix configuration: passed.
- Actual Windows bundle built on Darwin using the generator and shared flake
  library through a hash-locked pure reference (Darwin has no default
  `windows-dotfiles` package export). Output:
  `/nix/store/wkp7ywv5057n2qicjdy2ir30ikg9xzz4-windows-dotfiles`.
- Generated `hm_win` wrapper build: exit 0 (includes ShellCheck):
  `/nix/store/4hajf4pr7vpqmngiqz91wavbrh711vnn-hm_win`.
- Archive-free bundle dependency inspection, shared Lua/manifest, PowerShell
  parsing and mocked installer/shell fallback, generated wrapper ShellCheck/Bash
  syntax: passed. The bootstrap binary hash/identity was verified earlier; no
  new durable Windows binary was published locally.
- Pure baseline `nix flake check --no-build`: exit 1 on existing invalid store
  derivation `dwz7h2ppsfhgljdk7jvyfgx59ah65zbn-source.drv` during WSL bootstrap
  evaluation. Final pure evaluation: exit 0; no impure workaround or placeholder
  flag. Darwin omits incompatible Linux systems and has no native flake checks,
  so this is not a claim that hosted Linux builds/hooks passed.
- Coordinator: 638 tests passed with the locked formatter oracle. Build service:
  64 tests passed. State tests cover supersession, fork/closed/merged PRs, races,
  checksums/provenance, failed/partial releases, retry identities, deduplication
  and status binding. Hosted permissions and end-to-end publication remain
  unverified until owner bootstrap.
- Linux source and Cargo hashes were verified; full Linux GUI build cannot run
  on this Darwin-only builder. Real Windows installation/RDP and GUI interaction
  require testing on the respective hosts.
- Darwin has no flake formatter export; the locked native `nixpkgs-fmt` was used
  directly on relevant Nix paths; final check reports 0/12 need reformatting.
- Existing staged gitleaks scan: exit 0, no leaks. Whitespace, LF, shebang and
  topology hook invariants passed. The Linux flake's generated pre-commit check
  is not available as a native Darwin export; no Linux hook build is claimed.

No activation, commit or push performed.
