final: prev: {
  # Pin tree-sitter CLI to 0.26.5. nvim-treesitter main branch requires
  # >= 0.26.1, but upstream nixpkgs reverted the 0.26 bump (back to 0.25.10)
  # due to a build regression on some platforms. The revert restored
  # reproducibility at the cost of breaking :checkhealth nvim-treesitter.
  # Hashes taken from the reverted commit (NixOS/nixpkgs@496e965e).
  #
  # Remove this override once nixpkgs re-bumps tree-sitter past 0.26.1.
  tree-sitter = prev.tree-sitter.overrideAttrs (old: rec {
    version = "0.26.5";
    src = prev.fetchFromGitHub {
      owner = "tree-sitter";
      repo = "tree-sitter";
      tag = "v${version}";
      hash = "sha256-tnZ8VllRRYPL8UhNmrda7IjKSeFmmOnW/2/VqgJFLgU=";
      fetchSubmodules = true;
    };
    cargoDeps = prev.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "tree-sitter-vendor-${version}";
      hash = "sha256-EU8kdG2NT3NvrZ1AqvaJPLpDQQwUhYG3Gj5TAjPYRsY=";
    };
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      prev.rustPlatform.bindgenHook
    ];
  });
}
