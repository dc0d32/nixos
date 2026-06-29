{
  description = "Systems dev: C/C++ and Rust (clang, gcc, cmake, ninja, cargo, rust-analyzer)";

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
              # C/C++
              clang-tools # clangd + clang-format + clang-tidy
              cmake
              ninja
              pkg-config
              gdb
              lldb
              # Rust
              rustc
              cargo
              rust-analyzer
              clippy
              rustfmt
              cargo-nextest
              cargo-watch
            ];
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          };
        }
      );
    };
}
