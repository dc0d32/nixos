# Plain vim as the universal base editor.
#
# Why vim and not neovim:
# Neovim's HM module (flake-modules/neovim.nix) ships LSPs +
# treesitter + completion + telescope + plugins for ~5 languages.
# That's wonderful for an adult dev account but enormous closure
# (and noise) for accounts that just want `EDITOR=$something` to
# resolve to a working modal editor — service accounts, kid
# accounts, and small headless hosts. As of 2026-05-02 the kid
# accounts on pb-t480 don't program text and the wsl host is
# rarely interactive, so the cost wasn't paying for itself.
#
# Plain `pkgs.vim` is ~5MB closure, provides `vi` as a built-in
# alias (no plugin needed), reads sane defaults from /etc/vimrc
# and ~/.vimrc, and is what every login shell on Linux already
# expects to find. defaultEditor=true sets EDITOR + VISUAL.
#
# Adult accounts that want the full neovim setup can still import
# `flake.modules.homeManager.neovim` from a higher-tier bundle
# (currently nothing does — that module is dormant; the file is
# kept on disk so reverting is one-line).
#
# Retire when: the flake adopts a different editor as the base
#   (helix, micro, …), OR neovim returns to home-base for everyone.
{
  flake.modules.homeManager.vim = { pkgs, ... }: {
    programs.vim = {
      enable = true;
      defaultEditor = true;
      # Tiny opinionated defaults — anything more invasive belongs
      # in a dedicated `vim-config` module per-user.
      settings = {
        number = true;
        relativenumber = true;
        expandtab = true;
        shiftwidth = 2;
        tabstop = 2;
        smartcase = true;
        ignorecase = true;
      };
      extraConfig = ''
        syntax on
        filetype plugin indent on
        set mouse=a
        set termguicolors
        set scrolloff=6
        set cursorline
        set undofile
      '';
    };
    # `pkgs.vim` already provides `vi` and `view` shims; no extra
    # packages needed.
  };
}
