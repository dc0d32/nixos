{ pkgs, ... }: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraPackages = with pkgs; [
      ripgrep
      fd
      gcc
      nodejs
      nil        # nix LSP
      lua-language-server
      stylua
    ];
    plugins = with pkgs.vimPlugins; [
      lazy-nvim
    ];
    # Bootstrap a minimal lazy.nvim config. Users can override in their own
    # home profile by setting programs.neovim.extraLuaConfig = lib.mkForce "...".
    extraLuaConfig = ''
      vim.g.mapleader = " "
      vim.g.maplocalleader = " "
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.termguicolors = true
      vim.opt.expandtab = true
      vim.opt.shiftwidth = 2
      vim.opt.tabstop = 2
      vim.opt.signcolumn = "yes"
      vim.opt.clipboard = "unnamedplus"
    '';
  };
}
