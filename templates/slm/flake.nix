{
  description = "SLM research: run, experiment with, and dissect small language models";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
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
              llama-cpp # local GGUF inference, quant + inspection (llama-cli, llama-quantize, llama-gguf)
              jq
            ];
            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath (with pkgs; [ stdenv.cc.cc.lib zlib ]);
            env.UV_PYTHON = "${pkgs.python3}/bin/python";
            shellHook = ''
              echo "slm shell — uv add transformers safetensors vllm jupyter ; llama-cli --help"
            '';
          };
        }
      );
    };
}
