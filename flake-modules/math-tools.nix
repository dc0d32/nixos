# Maths workspace for the kids (home-manager): a plain folder, ~/src/math, plus a
# launcher, a calculator and a function plotter.
#
# Why it exists: the kids already know Python, so the symbolic side of their
# maths (derivatives, integrals, limits, linear algebra) is SymPy in a Jupyter
# notebook rather than a new language such as Maxima's. SymPy returns only
# answers, so packages/mathkit adds what a teacher would: a friendly answer
# checker, step-by-step working and interactive pictures.
#
# Design rule, learned the hard way: let VS Code own VS Code and let Nix own the
# Python. Declaring VS Code's internal state from home-manager (named profiles,
# the extension index, settings.json) fought it at every step: read-only
# settings popups, a ~/.vscode/extensions clash that broke `hm switch` and the
# unattended auto-update, and extensions that never loaded. So this module
# touches nothing of VS Code's. See docs/sessions/2026-11-20-maths-workspace-direnv.md.
#
# How it fits together:
#   - ~/src/math is seeded from templates/maths (an `.envrc` plus `.vscode/`
#     settings and a recommended-extensions list) and from
#     packages/mathkit/notebooks (-> ~/src/math/samples). Copy-if-missing, so
#     the kids' edits are never overwritten; updates reach existing folders only
#     if someone deletes the file.
#   - `.envrc` runs `use flake github:dc0d32/nixos?dir=maths` (maths/flake.nix,
#     a flake with nixpkgs as its only input); direnv builds the Python environment on first use and
#     links it at ~/src/math/.direnv/python, which `.vscode/settings.json`
#     points VS Code at. The environment is rebuilt automatically the first
#     time the folder is used after a week without a rebuild (a stamp file the
#     `.envrc` watches), and keeps the old one if the rebuild fails. What it
#     rebuilds to is whatever maths/flake.lock says; see
#     scripts/sync-maths-lock.sh.
#   - `math-studio` (also the "Maths Studio" launcher) prepares the folder,
#     builds the environment (in a terminal the first time, so progress is
#     visible), lets VS Code install the recommended extensions itself, and
#     opens the folder in the kids' normal VS Code.
#
# Needs the `direnv` module (with nix-direnv) in the account's bundle, which the
# kid bundle already has through `base`.
#
# Qalculate! covers everyday calculation with units and exact fractions; KmPlot
# plots functions and shows derivatives and integrals without any code.
#
# Carried by the kid bundle only. Retire when: the kids stop using it, OR a
# step-by-step tool worth adopting replaces the notebooks.
{ ... }:
{
  flake.modules.homeManager.math-tools = { lib, pkgs, ... }:
    let
      template = ../templates/maths;
      notebooks = ../packages/mathkit/notebooks;
      direnv = "${pkgs.direnv}/bin/direnv";
      code = "${pkgs.vscode}/bin/code";

      # Seeds ~/src/math. Safe to run any number of times.
      mathSetup = pkgs.writeShellApplication {
        name = "math-setup";
        runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.diffutils pkgs.jq ];
        text = ''
          dir="$HOME/src/math"
          mkdir -p "$dir/samples"

          seed() {
            [ -e "$2" ] && return 0
            mkdir -p "$(dirname "$2")"
            install -m 0644 "$1" "$2"
          }

          (cd ${template} && find . -type f -print0) |
            while IFS= read -r -d "" f; do
              seed "${template}/$f" "$dir/$f"
            done
          for nb in ${notebooks}/*.ipynb; do
            seed "$nb" "$dir/samples/$(basename "$nb")"
          done

          # An earlier version of this module shipped notebooks that name a
          # `mathpython` kernel, which no longer exists. Repoint only that one
          # line of metadata, so nothing the kids wrote is touched.
          for nb in "$dir"/samples/*.ipynb; do
            [ -e "$nb" ] || continue
            if jq -e '.metadata.kernelspec.name == "mathpython"' "$nb" >/dev/null 2>&1; then
              tmp="$(mktemp)"
              jq '.metadata.kernelspec = {name: "python3", display_name: "Python 3", language: "python"}' "$nb" > "$tmp" &&
                cat "$tmp" > "$nb"
              rm -f "$tmp"
            fi
          done

          # Approve the .envrc only while it is still exactly the one we
          # shipped; if someone edited it, they approve it themselves.
          if cmp -s "$dir/.envrc" ${template}/.envrc; then
            ${direnv} allow "$dir" || true
          fi
        '';
      };

      mathStudio = pkgs.writeShellApplication {
        name = "math-studio";
        runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq mathSetup ];
        text = ''
          dir="$HOME/src/math"
          math-setup

          # The first run, and the first run after a week away (see .envrc),
          # builds the Python environment. That takes minutes and prints
          # progress: make sure there is a terminal to show it in.
          stale() {
            [ -z "$(find "$dir/.direnv" -maxdepth 1 -name refreshed -mtime -7 2>/dev/null)" ]
          }
          if [ ! -t 1 ] && { [ ! -e "$dir/.direnv/python/bin/python" ] || stale; }; then
            exec ${pkgs.alacritty}/bin/alacritty -e "$0" "$@"
          fi

          pause() { if [ -t 0 ]; then read -r -p "Press Enter to close. " _ || true; fi; }

          cd "$dir"
          echo "Getting your maths tools ready (the first time, and about once a week, this takes a few minutes)..."
          if ! ${direnv} exec . true; then
            echo
            echo "Could not set up the Python tools. Is the internet connected?"
            echo "Ask a grown-up, or just try again."
            pause
            exit 1
          fi

          # VS Code installs its own extensions; we only ask for the ones the
          # folder recommends, and only when they are missing.
          have="$(${code} --list-extensions 2>/dev/null || true)"
          for ext in $(jq -r '.recommendations[]' ${template}/.vscode/extensions.json); do
            if ! printf '%s\n' "$have" | grep -qix "$ext"; then
              ${code} --install-extension "$ext" ||
                echo "(Could not install $ext; will try again next time.)"
            fi
          done

          exec ${code} --disable-workspace-trust "$dir" "$dir/samples/00-start-here.ipynb" "$@"
        '';
      };

      mathStudioItem = pkgs.makeDesktopItem {
        name = "math-studio";
        desktopName = "Maths Studio";
        comment = "VS Code set up for maths: Python, SymPy and notebooks";
        categories = [ "Education" ];
        exec = "${mathStudio}/bin/math-studio";
      };
    in
    {
      home.packages = [
        mathStudio
        mathStudioItem
        pkgs.qalculate-gtk
        pkgs.kdePackages.kmplot
      ];

      home.activation.seedMathWorkspace = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${mathSetup}/bin/math-setup || verboseEcho "math-setup failed; the Maths Studio launcher will retry"
      '';
    };
}
