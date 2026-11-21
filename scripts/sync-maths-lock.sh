#!/usr/bin/env bash
# Point the kids' maths environment (maths/flake.lock) at the SAME nixpkgs
# revision the fleet uses (flake.lock).
#
# Why: maths/ is a flake of its own, so a fleet nixpkgs bump does not move it.
# Using the fleet's revision (rather than the newest channel head) means the
# binaries are already in cache.nixos.org and the Attic cache, so the kids'
# laptops download instead of compile. Run it after every `nix flake update`.
#
# Idempotent: prints nothing changed when they already match.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
rev="$(jq -er '.nodes[.nodes.root.inputs.nixpkgs].locked.rev' flake.lock)"
echo "fleet nixpkgs: $rev"

(cd maths && nix flake lock --override-input nixpkgs "github:NixOS/nixpkgs/$rev")

git --no-pager diff --stat -- maths/flake.lock
echo "maths/flake.lock now follows $rev (commit it with the fleet bump)."
