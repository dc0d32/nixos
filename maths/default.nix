# The kids' maths Python environment and the `mathkit` package, as plain Nix
# shared by two callers: maths/flake.nix (what the workspace's `.envrc` builds)
# and flake-modules/maths-shell.nix (this repo's own checks).
#
# Why a separate file: the environment must be defined once, or the unit tests
# in `nix flake check` would test something other than what the kids run.
#
# The environment MUST contain `notebook`: with only `ipykernel` the VS Code
# Jupyter extension refuses to start a kernel ("requires the notebook package")
# and then suggests `uv venv`, which cannot work on a Nix store Python.
#
# Retire when: the kids stop using the maths workspace.
{ pkgs }:
let
  inherit (pkgs) lib;
  root = ../packages/mathkit;

  mathkit = pkgs.python3Packages.buildPythonPackage {
    pname = "mathkit";
    version = "0.1.0";
    pyproject = true;
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/pyproject.toml")
        (root + "/README.md")
        (root + "/src")
      ];
    };
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies = with pkgs.python3Packages; [ sympy numpy matplotlib ];
    pythonImportsCheck = [ "mathkit" ];
    doCheck = false;
  };

  pyEnv = pkgs.python3.withPackages (ps: [
    ps.sympy
    ps.numpy
    ps.scipy
    ps.matplotlib
    ps.ipython
    ps.ipykernel
    ps.ipywidgets
    ps.notebook
    mathkit
  ]);
in
{
  inherit mathkit pyEnv;
  shell = pkgs.mkShellNoCC { packages = [ pyEnv ]; };
}
