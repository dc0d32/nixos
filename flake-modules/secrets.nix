# Secrets — sops-nix wiring (cross-class).
#
# Provides:
#   - flake.modules.nixos.secrets       — imports sops-nix NixOS module
#   - flake.modules.homeManager.secrets — imports sops-nix HM module
#
# Each host that wants secrets imports the appropriate module(s) and supplies
# (a) an age key file path on disk (NOT in the repo), and (b) a sops-encrypted
# YAML file (in the repo, encrypted to that age key).
#
# Top-level options (set per-host in flake-modules/hosts/<name>.nix):
#   secrets.ageKeyFile       — path to the user's age key on disk
#                              (e.g. "/home/p/.config/sops/age/keys.txt").
#                              Read by HM. Required if HM secrets module
#                              is imported.
#   secrets.systemAgeKeyFile — path to the system age key on disk
#                              (e.g. "/var/lib/sops-nix/key.txt"). Read by
#                              NixOS. Required if NixOS secrets module is
#                              imported.
#   secrets.commonFile       — path to encrypted YAML for HM-scope secrets
#                              (git identity, AI API tokens, etc).
#                              Required if HM secrets module is imported.
#   secrets.hostFile         — path to encrypted YAML for NixOS-scope secrets
#                              (user password hashes, etc). Required if NixOS
#                              secrets module is imported.
#
# Bootstrap on a brand-new host:
#   1. Generate an age key:
#        mkdir -p ~/.config/sops/age
#        nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
#        chmod 600 ~/.config/sops/age/keys.txt
#      Note the public key (age1...) printed to stderr.
#   2. Add the public key to .sops.yaml under the matching path_regex rule.
#   3. (NixOS-scope only) Either copy the same key file to /var/lib/sops-nix/
#      key.txt with mode 0600 owned by root, OR generate a separate machine
#      key and add it as a second recipient.
#   4. Create encrypted secrets YAMLs:
#        nix shell nixpkgs#sops -c sops secrets/common.yaml
#      Save normally; sops re-encrypts on save.
#   5. Set secrets.{ageKeyFile,systemAgeKeyFile,commonFile,hostFile} on the
#      host bridge.
#   6. git add .sops.yaml secrets/*.yaml flake-modules/secrets.nix flake.lock
#      (Nix flake builds ignore untracked files.)
#
# Activation paths:
#   - NixOS: sops-nix runs at boot; secrets land at /run/secrets/<name> with
#            owner/mode set per declaration.
#   - HM:    sops-nix runs at `home-manager switch`; secrets land at
#            /run/user/<uid>/secrets/<name>.
#
# Standalone HM ≠ NixOS: each side activates independently. You can use only
# one side if you only have secrets there.
#
# Per-secret declarations (the actual sops.secrets.<name> entries) live in the
# feature module that consumes them — git.nix declares git_identity, ai-cli.nix
# declares the API keys, family-laptop's host bridge declares the password
# hashes. This module just wires the framework.
#
# Retire when: every secret-shaped value is either non-secret, runtime-managed
# by an app keystore, or the user moves to agenix / a hardware token.
{ lib, config, ... }:
let
  cfg = config.secrets;
in
{
  options.secrets = {
    ageKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/p/.config/sops/age/keys.txt";
      description = ''
        Path to the user's age key file on disk. Read by the home-manager
        sops-nix module. Set this on the host bridge for any host that
        imports config.flake.modules.homeManager.secrets.
      '';
    };
    systemAgeKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/sops-nix/key.txt";
      description = ''
        Path to the system age key file on disk (root-readable). Read by the
        NixOS sops-nix module before users are created. Set this on the host
        bridge for any host that imports config.flake.modules.nixos.secrets.
      '';
    };
    commonFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Encrypted sops YAML carrying cross-host HM secrets (git identity,
        AI API keys, etc). Used as the default sops file for the HM module.
      '';
    };
    hostFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Encrypted sops YAML carrying host-specific NixOS secrets (e.g. user
        password hashes for family-laptop). Used as the default sops file for
        the NixOS module.
      '';
    };
  };

  config.flake.modules.nixos.secrets = { inputs, ... }: {
    imports = [ inputs.sops-nix.nixosModules.sops ];

    # Only set keyFile / defaultSopsFile if the host supplied them. sops-nix
    # tolerates missing values at eval time (the assertions only fire at
    # activation), but setting `null` causes a type error.
    sops = lib.mkMerge [
      {
        # Disable the SSH-host-key fallback: we use an explicit age key file,
        # not the machine's ssh_host_ed25519_key. Setting sshKeyPaths = []
        # suppresses the "no SSH host keys found" warning sops-nix emits when
        # openssh is off.
        age.sshKeyPaths = [ ];
        gnupg.sshKeyPaths = [ ];
      }
      (lib.mkIf (cfg.systemAgeKeyFile != null) {
        age.keyFile = cfg.systemAgeKeyFile;
        # Treat the key as the only source of truth — don't try to fall back
        # to ssh_host_* if it's missing (we'd rather fail loudly).
        age.generateKey = false;
      })
      (lib.mkIf (cfg.hostFile != null) {
        defaultSopsFile = cfg.hostFile;
      })
    ];
  };

  config.flake.modules.homeManager.secrets = { inputs, ... }: {
    imports = [ inputs.sops-nix.homeManagerModules.sops ];

    sops = lib.mkMerge [
      (lib.mkIf (cfg.ageKeyFile != null) {
        age.keyFile = cfg.ageKeyFile;
        age.generateKey = false;
      })
      (lib.mkIf (cfg.commonFile != null) {
        defaultSopsFile = cfg.commonFile;
      })
    ];
  };
}
