# 2026-10-11 — General Mac LAN Nix cache

## Decision

`p@pb-mb` imports the Home Manager side of `lan-nix-cache`. Its options, signing
key, endpoints and roaming policy are shared with the existing NixOS module.
User `extra-substituters` / `extra-trusted-public-keys` preserve installer and
public cache settings. This is general Nix use, not WezTerm-specific.

Standalone HM remains userland-only. It generates a public daemon trust
fragment, but the owner must install/include it and restart the daemon.
The inspected Mac client has only root in `trusted-users` and no LAN cache
settings. User settings alone cannot authorize those daemon substitutions.
No nix-darwin, daemon management by HM, trusted-user escalation or disabled
signature checks.

## Native builds and signed sharing

The cache host's existing warmer builds Linux, including emulated ARM Linux—not
Darwin. Matching Macs build native outputs once and explicitly publish selected
closures with `nix-cache-upload`, `nix-cache-build`, or `hm --cache`.
Ordinary builds/switches do not upload, and no store watcher is installed.
The public cache can expose everything in a selected closure; explicit opt-in
is important even though credentials never enter those closures.

The inspected server also trusts only root for unsigned Nix imports. Rather
than grant operator `p` Nix root-equivalent trust or provision a Mac upload
token, use existing SSH plus interactive remote sudo:

1. The Mac checks LAN reachability and exports the selected closure through SSH.
2. `nix-cache-stage` stores the export under the operator's private state directory.
3. `sudo nix-cache-publish` validates the stage and requested roots, imports the
   native closure without building it, then pushes using the existing warmer
   configuration. Attic signs the output with the existing persisted key.

No credentials leave the cache host. Uploads retain Attic's upstream signature
filter; the nginx proxy continues caching upstream objects without re-signing.
No new sudo policy or authentication secret is introduced.

Server no-follow directory/file descriptors prevent symlink traversal. Publication
holds Nix's shared GC lock until imported roots are valid, then retains direct
root-owned GC roots until the push completes. Cleanup handles normal failures
and interrupts; hard kills may require removing the specific stale stage/roots.
The build wrapper keeps normal result links to protect local output roots.

## Verification and deployment boundary

Baseline pure `nix flake check --no-build` and native Mac HM build passed.
Final verification includes the generated native client scripts, focused
credential-free client/server safety tests, rendered Nix config, pure public
evaluation, and server helper evaluation with the local public-flake override.
Native HM builds include the existing ShellCheck and nix.conf validation gates.
The repository Python suite passed 650 tests (one existing skip), including
12 focused generated-client tests. The server helper passed 31 safety tests,
also exercised against the exact Nix-generated Python source.
Linux server helper builds and real end-to-end publication require the owner
on the respective hosts; Darwin cannot build those Linux derivations.

The LAN Attic endpoint was reachable. Existing physical-host operator SSH was
trusted, but the generic service alias was not yet pinned in SSH.

**No activation, daemon edits, remote sudo, publication, commit or push performed.**
The owner still needs to resolve the existing user nix.conf collision, activate
HM, install daemon trust, deploy the server helpers, and verify/pin the upload
SSH alias. README documents the exact steps and commands.
