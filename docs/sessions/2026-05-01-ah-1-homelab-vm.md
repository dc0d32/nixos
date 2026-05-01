# 2026-05-01 — ah-1: first homelab service-VM host

## Goal

Add a new host class to the flake for **homelab service VMs**: NixOS
running as a guest inside a hypervisor (Proxmox/ESXi/Hyper-V/whatever
the homelab uses), unattended, headless, primarily running services
through Docker but with the option to run native daemons too. First
concrete instance is `ah-1`; the design must support `ah-2`, `ah-3`,
... cheaply.

This is the third host class in the repo:

- **Desktop** (pb-x1): full Wayland session, audio, biometrics, GUI HM.
- **Family laptop** (family-laptop): desktop class with extra parental-
  controls / multi-user policy on top.
- **WSL** (wsl, wsl-arm): headless WSL2 guest, factory-pattern host.
- **Homelab VM** (ah-N): headless KVM/QEMU guest, factory-pattern, role
  account, container-runtime focus. *(This file.)*

## User preferences locked in

These were chosen explicitly during the design dialog at the start of
this session and should be treated as defaults for future ah-N hosts
unless the user revisits them in a later session:

| Concern | Choice | Why |
|---|---|---|
| Hypervisor role | NixOS as a VM **guest** (not a hypervisor itself) | Decouples flake from any specific hypervisor; the hypervisor stays whatever the user already runs in the homelab. |
| Number of VMs | One today (`ah-1`), factory pattern for growth | Mirrors `wsl.nix`. Adding ah-2 = 1 line in the `hosts` list + a regenerated hardware-config. |
| Container runtime | Docker (not podman, not oci-containers) | Broadest tutorial / compose ecosystem compatibility. Tradeoff (`docker` group ≈ root) accepted; documented in `docker.nix`'s header. |
| Stack management | External docker-compose files, NOT NixOS-managed | Compose stacks live on the VM under `/var/lib/compose/<service>/docker-compose.yml`. Keeps the flake stable; iteration on a stack doesn't churn the system closure. |
| Remote access | openssh **only** | Homelab is LAN-reachable; no Tailscale, no Wireguard, no jump host. SSH default config (no hardening preset) — hardening is a host-bridge concern, not a primitive-module concern. |
| Reverse proxy | None yet | Services on raw `host:port` until enough exist to warrant Caddy/Traefik/nginx. Easy add later. |
| User account | New dedicated `nas` role account | Service hosts are shared / unattended; role account keeps SSH keys, shell history, and group memberships from leaking into personal `p` workflows on desktop hosts. |
| SSH auth policy | Defaults | `services.openssh.enable = true` only. The user explicitly chose to defer hardening (PermitRootLogin, PasswordAuthentication, key-only) until first deploy makes the host reachable. |
| Hardware-config | Buildable kvm-guest stub, regenerate inside the VM later | Keeps `nix flake check` green from day one and lets us iterate on the host module before the VM exists. Same pattern as `family-laptop`'s placeholder. |

If a future ah-N needs a different choice (e.g. ah-2 wants podman
instead, or wants Tailscale), the right move is a new dedicated host
bridge — NOT to retrofit conditionals into `ah-1.nix`. Importing IS
enabling; divergence happens by composition, not by feature flags.

## Context

The repo had no precedent for a server-class host that ISN'T inside
WSL. `wsl.nix` was the closest reference (headless, factory pattern,
no GUI imports), but WSL has its own quirks:

- WSL doesn't manage networking (`networking.nix` is skipped, the
  Windows side handles it).
- WSL doesn't need a bootloader stanza.
- WSL has no real users module — the WSL fork creates the default user
  itself, so `wsl.nix` deliberately skips `users.users.<name>`.
- WSL has no sshd by default and doesn't need one (Windows runs the
  SSH listener if any).

A KVM/QEMU guest needs ALL of these things. So `ah-1.nix` is "shaped
like wsl.nix but with the missing parts filled in":

- Imports `networking.nix` (NetworkManager + firewall).
- Sets `boot.loader.systemd-boot.enable = mkDefault true` (UEFI
  default; modern hypervisors ship OVMF). User can override in the
  regenerated hardware-config if their VM is BIOS.
- Declares `users.users.nas = { isNormalUser; extraGroups = [...]; ... }`
  inline in the host module.
- Imports a brand-new `openssh.nix` for the SSH listener.

And it adds one thing WSL doesn't have at all:

- Imports a brand-new `docker.nix` for the container runtime.

## Implementation

### `flake-modules/openssh.nix` (new, 35 LOC)

```nix
flake.modules.nixos.openssh = {
  services.openssh.enable = true;
};
```

That's the entire module body. The header explains why hardening
(key-only auth, no root login, fail2ban, port changes) is **not**
in this module: hardening policy belongs on the host bridge so
different hosts can pick different policies while still sharing the
"sshd is enabled" primitive. If every server-class host eventually
ends up with the same hardening preset, that's the point at which
to extract a `flake-modules/openssh-hardened.nix` and have hosts
choose between `openssh` and `openssh-hardened`.

### `flake-modules/docker.nix` (new, 55 LOC)

Three lines of config wrapped in a thoroughly-commented header:

```nix
flake.modules.nixos.docker = { config, pkgs, ... }: {
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.docker-compose ];
  users.users.${config.users.primary}.extraGroups = [ "docker" ];
};
```

Three deliberate decisions in there:

1. **`docker-compose` (v2) on PATH explicitly.** nixpkgs ships v2 as a
   separate `pkgs.docker-compose` derivation (the Go CLI plugin). With
   it installed, both `docker compose ...` (subcommand) and the
   legacy `docker-compose ...` wrapper resolve. Most homelab tutorials
   use the wrapper form; the subcommand form is the modern blessed
   path. Including the package gives both.
2. **Add `users.primary` to the `docker` group.** Without this, every
   docker invocation needs `sudo`, which is friction. The cost is
   that group membership in `docker` is effectively root on the host
   (the docker socket trivially mounts host paths into containers as
   root). For a single-admin homelab box this is the standard tradeoff
   and matches every tutorial; for a multi-tenant box you'd pick
   rootless docker or podman instead. The header documents this.
3. **Read `users.primary`, not a hard-coded username.** This module
   is intended to be reusable on any future server host that imports
   it; the host bridge declares who the primary user is. Same pattern
   as `flake-modules/hardware-hacking.nix` (dialout/plugdev) and
   `flake-modules/timekpr.nix`.

### `flake-modules/hosts/ah-1.nix` (new, 201 LOC)

Factory-pattern host bridge modeled exactly on `wsl.nix`:

```nix
hosts = [
  { name = "ah-1"; system = "x86_64-linux"; }
];

configurations.nixos = builtins.listToAttrs (map
  ({ name, system }: { inherit name; value.module = mkNixosModule { inherit name system; }; })
  hosts);

configurations.homeManager = builtins.listToAttrs (map
  ({ name, system }: {
    name = "${user}@${name}";
    value = { pkgs = mkPkgs system; module = hmModule; };
  })
  hosts);
```

Adding `ah-2`:

1. Provision the VM in the homelab hypervisor.
2. `mkdir hosts/ah-2 && sudo nixos-generate-config --show-hardware-config > hosts/ah-2/hardware-configuration.nix`
3. Append `{ name = "ah-2"; system = "x86_64-linux"; }` to the `hosts` list.
4. `git add` and rebuild.

NixOS imports for the shared `mkNixosModule`:

- `nix-settings`, `system-utils`, `users`, `locale`, `networking` —
  baseline shared with the desktop hosts.
- `openssh`, `docker` — new server-class primitives introduced this
  session.

NixOS imports DELIBERATELY skipped (annotated in the file):

- `gpu`, `power`, `battery`, `audio`, `biometrics`, `login-ly`, `niri`,
  `fonts`, `hardware-hacking`, `chromium-managed`, `steam`, `timekpr`.

HM bundle for `nas@ah-N`:

- `git`, `tmux`, `direnv`, `btop`, `gh`, `zsh`, `neovim`. Mirrors the
  `wsl.nix` headless set so SSHing into a homelab VM feels identical
  to SSHing into WSL: same shell, same prompt, same muscle memory.
- DROPPED vs wsl: `build-deps` (no gcc/make on a service host; pull in
  per-host if a specific VM needs to compile something), `ai-cli` (the
  homelab account isn't doing dev work).

User account:

```nix
users.users.nas = {
  isNormalUser = true;
  description = "nas";
  extraGroups = [ "wheel" "networkmanager" ];  # docker added by docker.nix
  shell = pkgs.zsh;
  initialPassword = "changeme";
};
```

`changeme` is a throwaway literal; the operator rotates it via
`passwd` on first login. The standard upgrade path (when sops-nix is
bootstrapped) is to replace `initialPassword` with
`hashedPasswordFile = config.sops.secrets.users_nas_password_hash.path;`
and declare the matching secret. Documented elsewhere in
`secrets/README.md`.

### `hosts/ah-1/hardware-configuration.nix` (new, 44 LOC)

Buildable sentinel that mirrors `family-laptop`'s placeholder pattern:
all-zeros UUID for `/`, `nixpkgs.hostPlatform = mkDefault "x86_64-linux"`,
no kernel modules listed, header explains that the file MUST be
regenerated inside the actual VM via
`sudo nixos-generate-config --show-hardware-config` before any
`nixos-rebuild switch`.

The choice between this approach and a `throw`-based placeholder was
explicit (the user picked "buildable kvm-guest stub"): the green-build
invariant lets us iterate on the host module before the VM exists, at
the cost of slight risk that a forgetful operator deploys the stub.
The all-zeros UUID makes that deployment fail loudly at activation
time (mount error), which is acceptable belt-and-braces.

## Verified

```sh
nix flake check
# all checks passed!  (5 NixOS configs: wsl, wsl-arm, pb-x1,
#                       family-laptop, ah-1; 5 HM configs.)

nix build --no-link --print-out-paths \
  .#nixosConfigurations.ah-1.config.system.build.toplevel \
  .#homeConfigurations.'nas@ah-1'.activationPackage
# /nix/store/c6z80md0lw1sxqphsi4jyw6wn7czjljw-nixos-system-ah-1-...
# /nix/store/ijc4a1jih0ss1aw5c9iqrdq7vz264r2c-home-manager-generation
```

Closure inspection:

- `ah-1` `sw/bin/` contains `docker`, `docker-compose`, `ssh`, `sshd`,
  `zsh`, `sudo`, `nmcli`.
- systemd `multi-user.target.wants/` enables `docker.service`,
  `sshd.service`, `NetworkManager.service`, `sshd-keygen.service`.
- `nix eval .#nixosConfigurations.ah-1.config.users.users.nas.extraGroups`
  → `["wheel" "networkmanager" "docker"]`. The `docker` group came in
  via `docker.nix` reading `users.primary = "nas"`. This validates the
  cross-module wiring: `users.nix` declares `users.primary`, the host
  bridge sets it, `docker.nix` reads it.
- HM `home-path/bin/` has `btop direnv gh git nvim tmux zsh`.

Regression check (closure-byte equivalence on the unchanged hosts):

- `pb-x1` toplevel: `s6nhvv2s4j9kkh14a6k7saj8kkksa5fh-...` — byte-
  identical to pre-session baseline.
- `family-laptop` toplevel: `b6lafnww598jbbfgl7z7k681ys8kmvkj-...` —
  byte-identical to post-zoom-steam baseline (also from this session).
- `wsl` toplevel: `f8pc9csn7cp1qzcx753cp80ny7wjb141-...` — byte-
  identical to pre-session baseline.
- `p@pb-x1` HM: `g6g6bb0v4i7j58jkhm5x4j84dvxjcs4k-...` — byte-identical
  to pre-session baseline.

Zero collateral on hosts that didn't import the new modules. Pattern A
("importing IS enabling") working as designed.

## Files

New:

- `flake-modules/openssh.nix` — bare sshd primitive.
- `flake-modules/docker.nix` — daemon + compose + docker group wiring.
- `flake-modules/hosts/ah-1.nix` — factory-pattern host bridge.
- `hosts/ah-1/hardware-configuration.nix` — placeholder, regenerate
  inside the VM.

Unchanged but referenced:

- `flake-modules/users.nix` — provides the `users.primary` option that
  `docker.nix` reads.
- `flake-modules/networking.nix` — NetworkManager + firewall, imported
  by ah-1.
- `flake-modules/hosts/wsl.nix` — structural template for the factory
  pattern.
- `hosts/family-laptop/hardware-configuration.nix` — visual template
  for the placeholder hardware-config.

Commit:

- `5f2409d` "ah-1: add homelab service-VM host with docker, sshd,
  dedicated nas user". Pushed to `origin/main`.

## Activation steps (operator)

Listed here so the next person picking up this work doesn't have to
re-derive them:

```sh
# 1. Provision the VM in the homelab hypervisor (UEFI firmware
#    preferred). Boot a NixOS installer ISO and install the base
#    system (any layout — the regenerated hardware-config will
#    capture it).

# 2. From inside the freshly-installed VM:
git clone https://github.com/dc0d32/nixos.git /etc/nixos
sudo nixos-generate-config --show-hardware-config \
    > /etc/nixos/hosts/ah-1/hardware-configuration.nix
cd /etc/nixos
git add hosts/ah-1/hardware-configuration.nix
sudo nixos-rebuild switch --flake .#ah-1

# 3. As the nas user (initial password: changeme):
passwd
home-manager switch --flake .#'nas@ah-1'

# 4. Drop docker-compose stacks under /var/lib/compose/<service>/
#    docker-compose.yml as needed. None of that lives in the flake.
```

## Open / future

Things deliberately deferred this session, listed so they don't get
re-litigated as if they were oversights:

- **SSH hardening preset.** Currently bare `services.openssh.enable`.
  When the host is reachable on the network, the natural follow-up is
  to set `services.openssh.settings.PermitRootLogin = "prohibit-password"`
  and `PasswordAuthentication = false`, plus declare authorized keys
  for `nas` (likely via sops-nix). Could either go inline in
  `flake-modules/hosts/ah-1.nix` or extract a
  `flake-modules/openssh-hardened.nix` once a second host wants the
  same preset.
- **Tailscale.** Not needed today (LAN-only access). When off-network
  access becomes a requirement, add `flake-modules/tailscale.nix`
  with `services.tailscale.enable = true;` plus the auth-key flow
  (likely sops-managed). Import on whichever ah-N needs it.
- **Reverse proxy.** When N services on raw `host:port` becomes
  unwieldy, the leading candidates are Caddy (simplest, automatic
  ACME) or Traefik (docker-aware label-based routing). Likely a
  `flake-modules/caddy.nix` opt-in.
- **Containers as NixOS systemd units (`virtualisation.oci-containers`).**
  Explicitly rejected this session in favor of external compose
  files. If a particular service needs declarative restart semantics
  / dependency ordering and is stable enough not to churn, it can be
  promoted to oci-containers later without disrupting the rest.
- **rootless docker / podman migration.** The `docker` group ≈ root
  caveat is documented in `docker.nix`'s header. If multi-tenancy
  ever becomes a concern, the migration is `flake-modules/podman.nix`
  with `virtualisation.podman.dockerCompat = true` and replacing the
  `docker.nix` import on whichever host needs it.
- **Backups.** No backup module exists yet. Compose-stack data lives
  in container volumes / bind-mounts on the VM; backing those up is
  a per-host concern that should probably get its own module
  (`flake-modules/restic.nix` or similar) once there's data worth
  losing.
- **Monitoring.** Same shape as backups. `flake-modules/node-exporter.nix`
  + a Prometheus-scraping host elsewhere is the obvious sketch, but
  not warranted until there's something to monitor.
- **Real hardware-configuration.nix.** Until regenerated inside an
  actual VM, the closure builds but the system is not bootable. The
  all-zeros root UUID is a deliberate sentinel; activation will fail
  loudly if anyone deploys the stub by accident.
