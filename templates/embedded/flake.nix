{
  description = "Embedded dev: ARM cross-toolchain, flashing & debugging (openocd, probe-rs, picotool)";

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
              gcc-arm-embedded # arm-none-eabi gcc/gdb
              platformio # multi-MCU build/flash/debug ecosystem (pio)
              cmake
              ninja
              openocd
              probe-rs-tools # cargo-flash / probe-rs (Rust embedded)
              picotool # Raspberry Pi RP2040
              minicom # serial console
              dfu-util
            ];
          };
        }
      );
    };
}
