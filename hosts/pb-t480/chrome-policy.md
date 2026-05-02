# pb-t480 — Google Chrome managed-policy rationale

This file documents why each policy in `chrome-policy.json` is set
the way it is. JSON has no comment syntax, so the rationale lives
here. Edit both files together.

The file is dropped at `/etc/opt/chrome/policies/managed/` by
`flake-modules/chrome-managed.nix` (NixOS class). Chrome reads it
at startup and refuses to let the user override any field in it.
The "Managed by your organization" badge appears next to the avatar
once any mandatory policy is present.

**Scope on Linux**: Chrome reads system-wide policy from
`/etc/opt/chrome/policies/managed/*.json`; there is no per-user
policy mechanism. Every user on this host who launches Chrome
(including the admin account `p`) sees these policies. The trade-
off is accepted because the alternative — Chromium with no Google
API keys — can't complete the `BrowserSignin` handshake (it 404s
on accounts.google.com), and Family Link supervision requires a
working signed-in Chrome.

This is **defense-in-depth on top of Family Link**. Family Link
(via the kid's signed-in Google account) is the primary safety net
— URL filtering, app approval, screen time at the Google account
level. The policies below either (a) make Family Link supervision
mandatory, or (b) close per-browser bypass routes that Family Link
can't see.

## Policies

### `BrowserSignin: 2`

Force browser sign-in. Without a signed-in Family Link account,
Family Link's URL filtering and supervision do nothing, so we make
sign-in a precondition for browsing.

### `RestrictSigninToPattern: ".*@gmail\\.com"`

Restrict sign-in to consumer Google accounts (gmail.com). We
deliberately don't enumerate kid emails to avoid hardcoding
personal data into the repo; effective protection because the kids
only know their own credentials. Tighten to specific addresses if
a kid ever finds and tries someone else's account.

### `IncognitoModeAvailability: 1`

`1` = Incognito disabled. Incognito mode escapes Family Link's
history-based supervision and bypasses some content filtering.

### `DeveloperToolsAvailability: 2`

`2` = DevTools disabled (no access from menu, keyboard shortcuts,
or context menu). DevTools can disable extensions, edit cookies,
and run arbitrary JS — trivial bypass for a curious kid.

### `ForceGoogleSafeSearch: true`

Force Google SafeSearch ON for all Google searches; user can't
toggle it off in the SERP UI.

### `ForceYouTubeRestrict: 2`

`2` = Strict Restricted Mode on YouTube. Family Link applies this
too at the account level; this is belt-and-suspenders in case
sign-in is broken.

### `PasswordManagerEnabled: false`

Don't let chromium save passwords locally. Bitwarden (force-installed
below) is the password manager; saving locally creates a parallel
store that bypasses Bitwarden's sync and oversight.

### `BrowserGuestModeEnabled: false`

Disable guest mode browsing. Guest sessions have no Family Link
supervision because there's no signed-in account.

### `BrowserAddPersonEnabled: false`

Hide the "Add person" / multi-profile UI. Kids should only ever
sign into their own Family Link account; preventing profile
creation closes the "add a non-supervised account" loophole.

### `MetricsReportingEnabled: false`

Don't send usage stats and crash reports. Pure preference;
harmless either way.

### `ExtensionSettings`

Replaces the older `ExtensionInstallBlocklist` / `ExtensionInstallAllowlist`
/ `ExtensionInstallForcelist` triple with a single per-extension
policy map. Chromium prefers `ExtensionSettings` and recommends
not mixing the two styles.

The `"*"` default rule blocks any extension that doesn't have an
explicit per-ID rule below it. `blocked_install_message` is shown
to the kid in the Chrome Web Store install dialog when they try
to install something — polite framing avoids it feeling adversarial.

Two extensions are force-installed:

#### `ddkjiahejlhfcafbddmgiahcphecmpfh` — uBlock Origin Lite (MV3)

Manifest V3 ad blocker. Less powerful than the deprecated MV2
uBlock Origin (no dynamic filtering, smaller filter list cap, no
element zapper) but future-proof: it survives Google's MV2
deprecation. For a kid use case (mainly blocking ads on YouTube,
Wikipedia, school sites), the MV3 default rules are sufficient.

`toolbar_pin: "force_pinned"` so the icon is always visible —
quality of life for the rare case where the kid needs to whitelist
a site.

#### `nngceckbapebfimnlniiiahkandclblb` — Bitwarden

Password manager extension. Pointed at the family self-hosted
Vaultwarden instance via the `3rdparty.extensions.<id>.environment.base`
managed-storage entry below. Bitwarden's extension reads
`chrome.storage.managed` at startup and pre-fills the server URL
on the sign-in screen, so the kid doesn't have to know or type it.

`toolbar_pin: "force_pinned"` so the icon is always visible —
otherwise discoverability of the extension is bad and the kid
would type passwords manually.

The matching desktop Bitwarden client is intentionally NOT installed
for kids (see `flake-modules/bitwarden.nix` — only `p` imports it).
The desktop client is a parent admin tool; kids only need
in-browser autofill.

### `ExtensionSettings.3rdparty`

Chromium's mechanism for delivering managed-storage data to
extensions, exposed to the extension via `chrome.storage.managed`.
Only used here for Bitwarden's server-URL pre-config; documented
at <https://bitwarden.com/help/managed-policies/>.

## Verifying on the live system

Visit `chrome://policy`. Each policy from the JSON should appear
under "Chrome Policies" with status "OK" and source "Platform".
Bad JSON or unknown policy keys show up as warnings here — useful
debugging signal.

Visit `chrome://extensions` to confirm both force-installed
extensions are present, enabled, and uninstall buttons are greyed
out. The toolbar should show the uBlock and Bitwarden icons
pinned next to the avatar.

Bitwarden specifically: visit `chrome://extensions/?id=nngceckbapebfimnlniiiahkandclblb`,
click "Extension options" or open the extension popup. The "Log
in" screen should pre-fill the self-hosted server URL
(`https://bitwarden.bitset.cc`) without the kid needing to set it
under Settings \u2192 Server URL.

## Adding policies

The full enumerable list lives at
<https://chromeenterprise.google/policies/>. Filter by "Linux"
support before adding. Add the policy key to `chrome-policy.json`
and a `### <Key>` section to this file with the rationale.

## Retire when

Replaced by per-user policies (Linux gains them; not on the
upstream roadmap as of 2026), or kids age out of needing
supervision and the chrome-managed module is removed from this
host.
