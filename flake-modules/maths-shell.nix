# Unit tests for the kids' maths helper library, run by `nix flake check`.
#
# Why it exists: the environment itself lives in maths/ (a small flake the
# kids' ~/src/math/.envrc builds, see maths/flake.nix); this only checks that
# the `mathkit` library and the starter notebooks still work with it, so a broken
# helper is caught before the kids see it.
#
# Retire when: the kids stop using the maths workspace.
{ ... }:
{
  perSystem = { pkgs, lib, ... }:
    let
      env = import ../maths { inherit pkgs; };
      root = ../packages/mathkit;
    in
    {
      packages.mathkit = env.mathkit;

      checks.mathkit = pkgs.runCommand "mathkit-tests"
        {
          nativeBuildInputs = [ env.pyEnv ];
          src = lib.fileset.toSource {
            inherit root;
            fileset = lib.fileset.unions [
              (root + "/src")
              (root + "/tests")
              (root + "/notebooks")
            ];
          };
        }
        ''
          cp -r $src work && chmod -R u+w work && cd work
          export HOME=$TMPDIR MPLBACKEND=Agg MPLCONFIGDIR=$TMPDIR/mpl
          python -m unittest discover -s tests -v
          touch $out
        '';
    };
}
