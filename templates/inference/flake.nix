{
  description = "Python inference environment for arbitrary tools & one-offs (uv + pip-pulled ML libs)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # CUDA wheels are x86_64-linux only; CPU/MPS works on the rest.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python3
              uv
              ruff
            ];
            # torch/transformers etc. come from PyPI wheels in a uv venv;
            # they dlopen libstdc++/zlib/cuda at runtime, so expose them.
            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath (
              with pkgs;
              [ stdenv.cc.cc.lib zlib ]
            );
            env.UV_PYTHON = "${pkgs.python3}/bin/python";
            shellHook = ''
              echo "inference shell — try: uv add torch transformers; uv run python"
            '';
          };
        }
      );
    };
}
