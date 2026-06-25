# Plain vim as the universal base editor, installed for every account
# via the home-base bundle. Also the single source of EDITOR/VISUAL
# (set to "vim" with mkDefault below), so host bridges and other
# modules don't each re-set the session variables.
#
# Why plain vim (and not a full neovim/LSP setup): `pkgs.vim` is a
# ~5MB closure, provides `vi`/`view` shims, reads sane defaults from
# /etc/vimrc and ~/.vimrc, and is what every login shell already
# expects to find. A heavier editor (neovim + LSPs + treesitter +
# plugins) is an enormous closure and noise for accounts that just
# want `$EDITOR` to resolve to a working modal editor — service
# accounts, kid accounts, and small headless hosts. The previous
# neovim HM module was removed on 2026-06-25 (nothing imported it).
#
# Retire when: the flake adopts a different editor as the base
#   (helix, micro, …), OR a full editor setup returns to home-base
#   for everyone.
{
  flake.modules.homeManager.vim = { lib, pkgs, ... }: {
    # Single source of EDITOR/VISUAL across the flake. mkDefault so a
    # host or higher-tier editor module can override without mkForce.
    home.sessionVariables = {
      EDITOR = lib.mkDefault "vim";
      VISUAL = lib.mkDefault "vim";
    };

    programs.vim = {
      enable = true;
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
