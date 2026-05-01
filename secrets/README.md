# Secrets

This directory holds sops-encrypted YAML files. Plaintext secrets MUST NEVER
be committed.

## Bootstrap

One-time setup, on a single trusted machine:

```sh
# 1. Install age + sops temporarily.
nix shell nixpkgs#age nixpkgs#sops

# 2. Generate a personal age key.
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# 3. Get the public key (age1...).
age-keygen -y < ~/.config/sops/age/keys.txt

# 4. Edit ../.sops.yaml: replace age1REPLACEME_PERSONAL... with your real
#    public key from step 3.

# 5. (Family-laptop only — for NixOS-scope password hashes.)
#    Either reuse the personal key (simplest), OR generate a separate
#    machine key on the actual hardware once it's built and put it at
#    /var/lib/sops-nix/key.txt.
#    If reusing personal key: replace age1REPLACEME_FAMILY_LAPTOP... with
#    the same public key as step 3.

# 6. Create secrets/common.yaml. sops will open $EDITOR; populate with:
#    git_identity: |
#      [user]
#        name = Your Real Name
#        email = your.real@email
#    openai_api_key: sk-...
#    anthropic_api_key: sk-ant-...
sops common.yaml

# 7. (Family-laptop only.) Create secrets/family-laptop.yaml. Generate
#    password hashes ahead of time:
#      mkpasswd -m sha-512
#    Then:
sops family-laptop.yaml
#    Populate with:
#    users_p_password_hash: $6$...
#    users_m_password_hash: $6$...
#    users_s_password_hash: $6$...

# 8. git add the encrypted files (they're safe — encrypted to recipients
#    in .sops.yaml).
git add ../.sops.yaml common.yaml family-laptop.yaml

# 9. Uncomment the secrets imports + option settings in the appropriate
#    flake-modules/hosts/<name>.nix. They are pre-staged with comments
#    showing exactly what to enable.

# 10. Back up ~/.config/sops/age/keys.txt to Bitwarden as a secure note.
#     Without it, every encrypted secret in this repo is unrecoverable.
```

## Adding a second host

1. On the new host, generate a machine age key:
   ```sh
   sudo mkdir -p /var/lib/sops-nix
   sudo nix shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt
   sudo chmod 600 /var/lib/sops-nix/key.txt
   sudo age-keygen -y < /var/lib/sops-nix/key.txt   # public key
   ```
2. Add the new public key to `.sops.yaml` under the appropriate `path_regex`
   rule (e.g. as `&newhost_machine`).
3. From any host that already has decrypt rights:
   ```sh
   sops updatekeys secrets/<the-relevant-file>.yaml
   ```
4. Commit the rekeyed file.

## Editing existing secrets

```sh
sops secrets/common.yaml
```
Save normally; sops re-encrypts on save. Diffs in git will show only that the
encrypted bytes changed — the structure (key names) remains visible.
