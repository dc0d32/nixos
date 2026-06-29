{
  description = "Container build/dev: buildx, compose, dive, hadolint, skopeo";

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
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              docker-client # talks to the host dockerd (see flake-modules/docker.nix)
              docker-buildx
              docker-compose
              dive # inspect image layers
              hadolint # Dockerfile linter
              skopeo # copy/inspect images without a daemon
            ];
          };
        }
      );
    };
}
