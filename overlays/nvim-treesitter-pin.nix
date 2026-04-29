# Pin nvim-treesitter to the last main-branch revision that required only
# tree-sitter CLI 0.25. Upstream commit 5465196 (2026-01-29) bumped the
# required CLI to 0.26.1; nixpkgs still ships tree-sitter 0.25.x as of
# 2026-04, so without this pin :checkhealth nvim-treesitter fails the
# version gate even though highlighting and :TSInstall work fine.
# Rechecked 2026-04-28: nixpkgs#tree-sitter still 0.25.10 — pin still required.
#
# We override the base attr; nixpkgs defines .withAllGrammars as a passthru
# helper that threads through overrides, so consumers using
# `nvim-treesitter.withAllGrammars` pick up the pinned src automatically.
#
# Retirement condition: delete this file (and its entry in ./default.nix)
# once `nix eval --raw nixpkgs#tree-sitter.version` reports >= 0.26.1.
final: prev: {
  vimPlugins = prev.vimPlugins // {
    nvim-treesitter = prev.vimPlugins.nvim-treesitter.overrideAttrs (_: {
      version = "pre-0.26-cli-bump";
      src = prev.fetchFromGitHub {
        owner = "nvim-treesitter";
        repo = "nvim-treesitter";
        rev = "f8bbc3177d929dc86e272c41cc15219f0a7aa1ac";
        hash = "sha256-9GI22/cwoJWOO7jvRpW67s/x6IoahNZkMpBb58rO31k=";
      };
    });
  };
}
