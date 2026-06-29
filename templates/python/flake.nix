{
  description = "Python development environment (uv-driven)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = import nixpkgs { inherit system; }; });
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python3
              uv # project + venv manager (`uv init`, `uv add`, `uv run`)
              ruff # linter + formatter
              basedpyright # type checker / LSP
              python3Packages.ipython
            ];
            env = {
              # Use a project-local interpreter; never write into the store.
              UV_PYTHON = "${pkgs.python3}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
            };
          };
        }
      );
    };
}
