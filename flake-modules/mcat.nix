# Mcat previews documents, images and video from one terminal command.
# Keep it universal so the same viewing workflow is available on Linux,
# macOS and headless WSL; native Windows installs it through Scoop.
#
# Retire when: mcat is no longer used, or a broader shared document-viewer
# module supersedes it.
{
  flake.modules.homeManager.mcat = { pkgs, ... }: {
    home.packages = [ pkgs.mcat ];
  };
}
