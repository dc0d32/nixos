# 2026-10-14 — Tabby blur and RDP profiles

## Problem

Tabby's nominal macOS vibrancy was visually opaque. Tabby applies a 65% dark
application tint over the native blur, while the managed configuration also
set whole-window opacity to 80%. The two mechanisms compounded and made the
blur ineffective while unnecessarily fading text.

Windows also needed opposite policies on the same installation: native
acrylic and WebGL locally, but an opaque non-WebGL renderer under GPU-less RDP.

## Decision

Keep Tabby's window opacity at 100% and use native vibrancy with a 20% dark CSS
tint on macOS and local Windows sessions. This exposes the OS blur without
making terminal text translucent.

Native Windows now receives two generated configurations:

- `%APPDATA%\tabby\config.yaml` — local acrylic, WebGL enabled.
- `%APPDATA%\tabby-rdp\config.yaml` — opaque, GPU disabled.

The managed Start-menu launcher selects `tabby-rdp` through
`TABBY_CONFIG_DIRECTORY` only when `SESSIONNAME` starts with `RDP`, and retains
the Electron GPU-disable switches as defense in depth. Switching an existing
Tabby process between local and RDP sessions still requires closing and
relaunching it because Electron renderer selection is process-wide.

No activation was performed.
