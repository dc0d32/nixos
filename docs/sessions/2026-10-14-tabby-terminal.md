# 2026-10-14 — Managed Tabby Terminal

## Decision

Add Tabby beside WezTerm and Ghostty on GUI Linux and macOS accounts, and
beside WezTerm and Windows Terminal on native Windows. Existing defaults and
launch bindings remain unchanged while the terminals are compared.

Tabby shares the established terminal appearance and interaction intent:
Fantasque, the Alacritty-derived palette, a steady beam, 100,000 lines of
history, platform-sized text, and common copy/paste/search/tab/pane shortcuts.
Application analytics, welcome content, and self-updates are disabled so
updates remain declarative.

## Packaging

Tabby 1.0.238 is pinned to official architecture-specific release assets with
SHA-512 hashes:

- Linux x86-64 and ARM64 use wrapped AppImages.
- macOS x86-64 and ARM64 use the signed application from the release ZIP.
- Windows uses the native architecture selected by the `Eugeny.Tabby` winget
  manifest during `hm_win --setup`.

The Nix package is local to the terminal module because nixpkgs' package named
`tabby` is an unrelated AI server. Home Manager deploys `config.yaml` to
Tabby's platform-native Electron user-data directory. Native Windows receives
the same generated configuration through `hm_win`.

## Windows RDP

The managed Start-menu shortcut launches Tabby normally on a local console. In
an RDP session it adds Electron's `--disable-gpu` and
`--disable-software-rasterizer` switches, forcing Tabby's xterm.js frontend
away from CPU-backed WebGL. This selection happens at launch rather than being
baked into the shared configuration, so local sessions retain GPU rendering.
Tabby must be restarted when moving an existing process between local and RDP
sessions because Electron chooses its renderer at process startup.

## Verification

- Pure `nix flake check --no-build` evaluation passed.
- The native ARM64 macOS Home Manager activation package built successfully.
- The packaged `Tabby.app` passed strict/deep code-signature verification.
- Both Linux release downloads matched their pinned SHA-512 hashes.
- Linux Home Manager and the generated Windows bundle evaluate successfully.
- The terminal contract tests pass; the full test file retains four unrelated
  pre-existing PTY-capture failures on this macOS environment.

No activation, commit, or push was performed.
