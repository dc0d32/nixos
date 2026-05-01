# Cross-platform neovim with sensible defaults, LSP, treesitter, completion,
# fuzzy finder, git signs, theming. Works on NixOS and macOS.
#
# Design:
# - Uses home-manager's programs.neovim (not nixvim) to keep config portable
#   and readable. Lua lives in a single initLua block.
# - LSP is wired via the nvim 0.11 native API: vim.lsp.config + vim.lsp.enable.
#   We keep nvim-lspconfig on the runtimepath for its default `lsp/<name>.lua`
#   config files, but never call require("lspconfig") itself.
# - Treesitter uses the main-branch API: grammars come from
#   pkgs.vimPlugins.nvim-treesitter.withAllGrammars, enabled per-buffer on
#   FileType via vim.treesitter.start. The plugin itself is currently pinned
#   via overlays/nvim-treesitter-pin.nix to dodge the CLI version gate —
#   that's transparent here; see the overlay for details.
#
# Retire when: a host wants a different editor or the config grows large
# enough to warrant a separate file tree (lua/ directory).
{
  flake.modules.homeManager.neovim = { pkgs, ... }: {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;

      # Opt out of the legacy ruby/python3 providers; they pull in large
      # closures we don't need. home-manager warns when stateVersion < 26.05
      # that these default to true — pin them off explicitly.
      withRuby = false;
      withPython3 = false;
      withNodeJs = false;

      extraPackages = with pkgs; [
        # tools
        ripgrep
        fd
        git
        # tree-sitter CLI + nodejs are provided via home.packages in
        # flake-modules/build-deps.nix so they land in ~/.nix-profile/bin
        # where :checkhealth nvim-treesitter actually looks. Keeping them out
        # of extraPackages avoids duplication.
        # build deps some plugins / LSPs need
        gcc
        gnumake

        # LSPs
        nil # nix
        lua-language-server
        pyright
        rust-analyzer
        gopls
        typescript-language-server
        bash-language-server
        vscode-langservers-extracted # html/css/json/eslint
        yaml-language-server
        marksman # markdown
        taplo # toml

        # formatters
        stylua
        nixpkgs-fmt
        black
        prettierd
      ];

      plugins = with pkgs.vimPlugins; [
        # UI / theme
        catppuccin-nvim
        lualine-nvim
        nvim-web-devicons
        which-key-nvim

        # Treesitter: main-branch flavor, all grammars on runtimepath.
        # Intentionally NOT including nvim-treesitter-textobjects — its current
        # setup path still hits the legacy nvim-treesitter attr and triggers
        # the deprecation warning. Native textobjects can be added later via
        # vim.treesitter if wanted.
        nvim-treesitter.withAllGrammars

        # LSP + completion — nvim-lspconfig still ships the per-server
        # `lsp/<name>.lua` default configs, which vim.lsp.enable() picks up
        # off the runtimepath. We no longer call require("lspconfig"), so
        # the deprecated "framework" code path is untouched.
        nvim-lspconfig
        nvim-cmp
        cmp-nvim-lsp
        cmp-buffer
        cmp-path
        cmp_luasnip
        luasnip
        friendly-snippets

        # Telescope
        telescope-nvim
        plenary-nvim
        telescope-fzf-native-nvim

        # Git
        gitsigns-nvim
        vim-fugitive

        # Editing QoL
        nvim-autopairs
        comment-nvim
        indent-blankline-nvim
        nvim-surround

        # Formatter
        conform-nvim
      ];

      initLua = /* lua */ ''
        -- ---------- options ----------
        vim.g.mapleader = " "
        vim.g.maplocalleader = " "

        local o = vim.opt
        o.number = true
        o.relativenumber = true
        o.termguicolors = true
        o.mouse = "a"
        o.clipboard = "unnamedplus"
        o.expandtab = true
        o.shiftwidth = 2
        o.tabstop = 2
        o.softtabstop = 2
        o.smartindent = true
        o.wrap = false
        o.signcolumn = "yes"
        o.cursorline = true
        o.ignorecase = true
        o.smartcase = true
        o.splitbelow = true
        o.splitright = true
        o.undofile = true
        o.updatetime = 250
        o.timeoutlen = 400
        o.scrolloff = 6
        o.sidescrolloff = 8
        o.completeopt = { "menu", "menuone", "noselect" }

        -- ---------- theme ----------
        require("catppuccin").setup({ flavour = "mocha", integrations = {
          cmp = true, gitsigns = true, telescope = { enabled = true },
          treesitter = true, which_key = true, native_lsp = { enabled = true },
        }})
        vim.cmd.colorscheme("catppuccin")

        require("lualine").setup({ options = { theme = "catppuccin-mocha", globalstatus = true } })
        require("ibl").setup({ scope = { enabled = false } })
        require("gitsigns").setup()
        require("nvim-autopairs").setup()
        require("Comment").setup()
        require("nvim-surround").setup()
        require("which-key").setup()

        -- ---------- treesitter (nvim-treesitter main-branch API) ----------
        -- The old `require("nvim-treesitter.configs").setup` was removed.
        -- Grammars come from pkgs.vimPlugins.nvim-treesitter.withAllGrammars
        -- (they're on the runtimepath). Highlighting + indent are enabled
        -- per-buffer on FileType via the native vim.treesitter API.
        vim.api.nvim_create_autocmd("FileType", {
          callback = function(ev)
            local ft = vim.bo[ev.buf].filetype
            local lang = vim.treesitter.language.get_lang(ft) or ft
            if lang and pcall(vim.treesitter.language.add, lang) then
              pcall(vim.treesitter.start, ev.buf, lang)
              -- Tree-sitter based indent (requires the indents query).
              if vim.treesitter.query.get(lang, "indents") then
                vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
              end
            end
          end,
        })

        -- Textobjects: intentionally omitted. The nvim-treesitter-textobjects
        -- plugin's setup path still resolves the legacy nvim-treesitter attr
        -- and fires a deprecation warning. Drop it here; if textobjects come
        -- back, switch to native queries via vim.treesitter.query.set.

        -- ---------- completion ----------
        local cmp = require("cmp")
        local luasnip = require("luasnip")
        require("luasnip.loaders.from_vscode").lazy_load()
        cmp.setup({
          snippet = { expand = function(a) luasnip.lsp_expand(a.body) end },
          mapping = cmp.mapping.preset.insert({
            ["<C-Space>"] = cmp.mapping.complete(),
            ["<CR>"]      = cmp.mapping.confirm({ select = false }),
            ["<C-e>"]     = cmp.mapping.abort(),
            ["<Tab>"]     = cmp.mapping(function(fallback)
              if cmp.visible() then cmp.select_next_item()
              elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
              else fallback() end
            end, { "i", "s" }),
            ["<S-Tab>"]   = cmp.mapping(function(fallback)
              if cmp.visible() then cmp.select_prev_item()
              elseif luasnip.jumpable(-1) then luasnip.jump(-1)
              else fallback() end
            end, { "i", "s" }),
          }),
          sources = cmp.config.sources(
            { { name = "nvim_lsp" }, { name = "luasnip" } },
            { { name = "buffer" }, { name = "path" } }
          ),
        })

        -- ---------- LSP (nvim 0.11 native: vim.lsp.config + vim.lsp.enable) ----------
        -- We no longer call `require("lspconfig")` — that path is deprecated and
        -- will be removed in nvim-lspconfig v3.0.0. nvim-lspconfig still ships
        -- `lsp/<name>.lua` default configs which vim.lsp.enable() auto-discovers
        -- on the runtimepath, so those defaults (cmd, filetypes, root markers)
        -- still apply. We add cmp capabilities via vim.lsp.config("*").
        local caps = require("cmp_nvim_lsp").default_capabilities()
        vim.lsp.config("*", { capabilities = caps })

        -- Per-server overrides (merged with the default config shipped by
        -- nvim-lspconfig's lsp/<name>.lua).
        vim.lsp.config("lua_ls", {
          settings = { Lua = { workspace = { checkThirdParty = false } } },
        })

        -- Turn servers on. nvim spawns each when a buffer's filetype matches.
        vim.lsp.enable({
          "nil_ls",
          "lua_ls",
          "pyright",
          "rust_analyzer",
          "gopls",
          "ts_ls",
          "bashls",
          "jsonls",
          "yamlls",
          "html",
          "cssls",
          "marksman",
          "taplo",
        })

        vim.api.nvim_create_autocmd("LspAttach", {
          callback = function(ev)
            local map = function(lhs, rhs, desc)
              vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, desc = desc })
            end
            map("gd", vim.lsp.buf.definition,       "Go to definition")
            map("gr", vim.lsp.buf.references,       "References")
            map("gi", vim.lsp.buf.implementation,   "Implementation")
            map("K",  vim.lsp.buf.hover,            "Hover")
            map("<leader>rn", vim.lsp.buf.rename,   "Rename")
            map("<leader>ca", vim.lsp.buf.code_action, "Code action")
            map("[d", vim.diagnostic.goto_prev,     "Prev diagnostic")
            map("]d", vim.diagnostic.goto_next,     "Next diagnostic")
          end,
        })

        -- ---------- formatting ----------
        require("conform").setup({
          formatters_by_ft = {
            lua = { "stylua" },
            nix = { "nixpkgs_fmt" },
            python = { "black" },
            javascript = { "prettierd" },
            typescript = { "prettierd" },
            json = { "prettierd" },
            yaml = { "prettierd" },
            markdown = { "prettierd" },
          },
          format_on_save = { timeout_ms = 2000, lsp_fallback = true },
        })

        -- ---------- telescope ----------
        local t = require("telescope.builtin")
        vim.keymap.set("n", "<leader>ff", t.find_files, { desc = "Files" })
        vim.keymap.set("n", "<leader>fg", t.live_grep,  { desc = "Grep" })
        vim.keymap.set("n", "<leader>fb", t.buffers,    { desc = "Buffers" })
        vim.keymap.set("n", "<leader>fh", t.help_tags,  { desc = "Help" })
        vim.keymap.set("n", "<leader>fr", t.resume,     { desc = "Resume" })
        pcall(require("telescope").load_extension, "fzf")

        -- ---------- keymaps ----------
        vim.keymap.set("n", "<leader>w", "<cmd>w<cr>",  { desc = "Save" })
        vim.keymap.set("n", "<leader>q", "<cmd>q<cr>",  { desc = "Quit" })
        vim.keymap.set("n", "<esc>",     "<cmd>nohlsearch<cr>")
        -- window nav
        vim.keymap.set("n", "<C-h>", "<C-w>h")
        vim.keymap.set("n", "<C-j>", "<C-w>j")
        vim.keymap.set("n", "<C-k>", "<C-w>k")
        vim.keymap.set("n", "<C-l>", "<C-w>l")
      '';
    };
  };
}
