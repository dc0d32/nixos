{
  description = "OpenWrt firmware build host deps (buildroot/imagebuilder)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # OpenWrt's buildroot is Linux-host oriented.
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = import nixpkgs { inherit system; }; });
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              gcc
              gnumake
              ncurses
              zlib
              gawk
              unzip
              file
              wget
              python3
              rsync
              perl
              git
              subversion
              bc
              flex
              bison
              gettext
              which
            ];
            shellHook = ''
              echo "openwrt build shell — clone git://git.openwrt.org/openwrt/openwrt.git, then ./scripts/feeds update -a && make menuconfig"
            '';
          };
        }
      );
    };
}
