# WezTerm, Ghostty and Tabby share appearance and shortcut intent across OSes.
# Existing terminal defaults and compositor launch bindings remain untouched.
# Retire when none of these managed terminal alternatives is used.
{ config, lib, ... }:
let
  alacritty = config.flake.lib.alacrittySettings;
  # Match the user's macOS Terminal profile without changing other terminals.
  backdrop = { opacity = 0.8; blurRadius = 30; tintOpacity = 0.2; };
  # Alacritty's built-in palette (config/color.rs), used when colors is omitted.
  colors = lib.recursiveUpdate
    {
      primary = { foreground = "#d8d8d8"; background = "#181818"; };
      normal = {
        black = "#181818";
        red = "#ac4242";
        green = "#90a959";
        yellow = "#f4bf75";
        blue = "#6a9fb5";
        magenta = "#aa759f";
        cyan = "#75b5aa";
        white = "#d8d8d8";
      };
      bright = {
        black = "#6b6b6b";
        red = "#c55555";
        green = "#aac474";
        yellow = "#feca88";
        blue = "#82b8c8";
        magenta = "#c28cb8";
        cyan = "#93d3c3";
        white = "#f8f8f8";
      };
    }
    (alacritty.colors or { });
  colorOrder = [ "black" "red" "green" "yellow" "blue" "magenta" "cyan" "white" ];
  cursor = alacritty.cursor.style;
  appearance = {
    fontUnix = alacritty.font.normal.family;
    fontWindows = "FantasqueSansM Terminal Nerd Font Mono";
    style = alacritty.font.normal.style;
    sizeUnix = alacritty.font.size;
    sizeMac = 14;
    sizeWindows = 13;
    padding = alacritty.window.padding;
    decorations = alacritty.window.decorations;
    opacity = alacritty.window.opacity or 1;
    history = alacritty.scrolling.history;
    cursorShape = cursor.shape;
    cursorBlink = builtins.elem (cursor.blinking or "Off") [ "On" "Always" ];
    inherit (colors.primary) foreground background;
    ansi = map (name: colors.normal.${name}) colorOrder;
    brights = map (name: colors.bright.${name}) colorOrder;
  };
  shortcuts = [
    { key = "c"; ghost = "copy_to_clipboard"; wez = "act.CopyTo('Clipboard')"; }
    { key = "v"; ghost = "paste_from_clipboard"; wez = "paste"; }
    { key = "f"; ghost = "start_search"; wez = "act.Search { CaseInSensitiveString = '' }"; }
    { key = "equal"; ghostKey = "equal"; wezKey = "="; ghost = "increase_font_size:1"; wez = "act.IncreaseFontSize"; }
    { key = "minus"; wezKey = "-"; ghost = "decrease_font_size:1"; wez = "act.DecreaseFontSize"; }
    { key = "0"; ghost = "reset_font_size"; wez = "act.ResetFontSize"; }
    { key = "t"; ghost = "new_tab"; wez = "act.SpawnTab('CurrentPaneDomain')"; }
    { key = "n"; ghost = "new_window"; wez = "act.SpawnWindow"; }
    { key = "w"; ghost = "close_surface"; wez = "act.CloseCurrentPane { confirm = true }"; }
    { key = "d"; ghost = "new_split:right"; wez = "act.SplitHorizontal { domain = 'CurrentPaneDomain' }"; }
    { key = "e"; ghost = "new_split:down"; wez = "act.SplitVertical { domain = 'CurrentPaneDomain' }"; }
    { key = "z"; ghost = "toggle_split_zoom"; wez = "act.TogglePaneZoomState"; }
  ];
  tabbyPin = {
    version = "1.0.238";
    sources = {
      x86_64-linux = {
        asset = "tabby-1.0.238-linux-x64.AppImage";
        hash = "sha512-D/rkcmbkUPZFQtAf6133fVV7tsW+r8sdsmp0t2X23fvyH61o05hIJSrIKfYkmzz2mCJtSxpvbTF25WjeLczJuw==";
      };
      aarch64-linux = {
        asset = "tabby-1.0.238-linux-arm64.AppImage";
        hash = "sha512-vbQF31pOgSPxuOKCB9x6HjjVZviQpP5ZtWSqSXie0Wr0456j8BFBj6nzhV4889EuqZBVwOV9zJ/EbHBwTh6pVg==";
      };
      x86_64-darwin = {
        asset = "tabby-1.0.238-macos-x86_64.zip";
        hash = "sha512-7dvbp6+PLtXFxSHYmcx++zEB/yPgBMgcTavrBWTkZ6nyS0hgZrCa7QmZDO3nfUwMynb+p1f/7Coqeqz8+8zoew==";
      };
      aarch64-darwin = {
        asset = "tabby-1.0.238-macos-arm64.zip";
        hash = "sha512-cxEca/dUoJp4HbcxkA0XVWgxRLalO3LZ3I3dSm25yHrRrRIRhrgP3kFOQzRCEA/2mpfm5b43fbzNixQbpb+EiQ==";
      };
    };
  };
  mkTabbyPackage = pkgs:
    let
      pname = "tabby";
      inherit (tabbyPin) version;
      source = tabbyPin.sources.${pkgs.stdenv.hostPlatform.system}
        or (throw "Tabby Terminal is not pinned for ${pkgs.stdenv.hostPlatform.system}");
      src = pkgs.fetchurl {
        url = "https://github.com/Eugeny/tabby/releases/download/v${version}/${source.asset}";
        inherit (source) hash;
      };
      meta = {
        description = "Cross-platform terminal with a WebGL renderer and software fallback";
        homepage = "https://tabby.sh/";
        license = lib.licenses.mit;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = builtins.attrNames tabbyPin.sources;
        mainProgram = "tabby";
      };
    in
    if pkgs.stdenv.isLinux then
      pkgs.appimageTools.wrapType2
        {
          inherit pname version src meta;
          extraInstallCommands =
            let
              contents = pkgs.appimageTools.extractType2 { inherit pname version src; };
            in
            ''
              install -Dm444 ${contents}/tabby.desktop "$out/share/applications/tabby.desktop"
              substituteInPlace "$out/share/applications/tabby.desktop" \
                --replace-fail 'Exec=AppRun' 'Exec=tabby'
              cp -r ${contents}/usr/share/icons "$out/share/"
            '';
        }
    else
      pkgs.stdenvNoCC.mkDerivation {
        inherit pname version src meta;
        nativeBuildInputs = [ pkgs.unzip ];
        sourceRoot = ".";
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/Applications"
          cp -R Tabby.app "$out/Applications/"
          runHook postInstall
        '';
        # Preserve the upstream hardened-runtime signature.
        dontFixup = true;
      };
  tabbyConfig = { isDarwin ? false, isWindows ? false }: {
    version = 1;
    enableAnalytics = false;
    enableAutomaticUpdates = false;
    enableWelcomeTab = false;
    recoverTabs = true;
    appearance = {
      colorSchemeMode = "dark";
      # Tabby's window-level opacity fades text and fights macOS vibrancy.
      # Keep the window opaque and tint the native blur in CSS instead.
      opacity = 1.0;
      vibrancy = isDarwin;
      vibrancyType = "blur";
      css =
        if isDarwin then ''
          app-root.vibrant { background: rgba(var(--bs-dark-rgb), ${toString backdrop.tintOpacity}); }
        '' else if isWindows then ''
          app-root { background: rgb(var(--bs-dark-rgb)); }
        '' else "";
      frame = "thin";
      tabsLocation = "top";
      flexTabs = false;
      lastTabClosesWindow = false;
    };
    terminal = {
      frontend = "xterm-webgl";
      profile = if isWindows then "local:powershell-core" else "local:default";
      font = if isWindows then appearance.fontWindows else appearance.fontUnix;
      # Tabby sizes are CSS pixels, while the shared appearance sizes are points.
      fontSize =
        let px = pt: builtins.floor (pt * 4.0 / 3.0 + 0.5);
        in
        if isWindows then px appearance.sizeWindows
        else if isDarwin then appearance.sizeMac
        else px appearance.sizeUnix;
      fontWeight = 400;
      fontWeightBold = 700;
      ligatures = false;
      cursor = { Beam = "beam"; Block = "block"; Underline = "underline"; }.${appearance.cursorShape};
      cursorBlink = appearance.cursorBlink;
      scrollbackLines = appearance.history;
      copyOnSelect = false;
      bracketedPaste = true;
      warnOnMultilinePaste = true;
      colorScheme = {
        name = "Nix managed";
        inherit (appearance) foreground background;
        cursor = appearance.foreground;
        colors = appearance.ansi ++ appearance.brights;
      };
    };
    hotkeys =
      let
        primary = if isDarwin then "⌘" else "Ctrl-Shift";
        alt = if isDarwin then "⌥" else "Alt";
        paneMods = if isDarwin then "${primary}-${alt}" else "Ctrl-Alt-Shift";
      in
      {
        copy = [ "${primary}-C" ];
        paste = [ "${primary}-V" ];
        search = [ "${primary}-F" ];
        "zoom-in" = [ "${primary}-=" ];
        "zoom-out" = [ "${primary}--" ];
        "reset-zoom" = [ "${primary}-0" ];
        "new-tab" = [ "${primary}-T" ];
        "reopen-tab" = if isDarwin then [ "⌘-Shift-T" ] else [ ];
        "close-tab" = [ "${primary}-W" ];
        "split-right" = [ "${primary}-D" ];
        "split-bottom" = [ "${primary}-E" ];
        "pane-maximize" = [ "${primary}-Z" ];
        "pane-nav-left" = [ "${paneMods}-Left" ];
        "pane-nav-right" = [ "${paneMods}-Right" ];
        "pane-nav-up" = [ "${paneMods}-Up" ];
        "pane-nav-down" = [ "${paneMods}-Down" ];
        "next-tab" = [ "Ctrl-Tab" ];
        "previous-tab" = [ "Ctrl-Shift-Tab" ];
        "scroll-page-up" = [ "Shift-PageUp" ];
        "scroll-page-down" = [ "Shift-PageDown" ];
      };
  };
  ghostConfig = isDarwin: zsh: ''
    font-family = ${appearance.fontUnix}
    font-style = ${appearance.style}
    font-size = ${toString (if isDarwin then appearance.sizeMac else appearance.sizeUnix)}
    window-padding-x = ${toString appearance.padding.x}
    window-padding-y = ${toString appearance.padding.y}
    window-decoration = ${if isDarwin then "auto" else if lib.toLower appearance.decorations == "none" then "none" else "auto"}
    background = ${appearance.background}
    foreground = ${appearance.foreground}
    background-opacity = ${toString (if isDarwin then backdrop.opacity else appearance.opacity)}
    background-blur = ${if isDarwin then toString backdrop.blurRadius else "false"}
    cursor-style = ${{ Beam = "bar"; Block = "block"; Underline = "underline"; }.${appearance.cursorShape}}
    cursor-style-blink = ${lib.boolToString appearance.cursorBlink}
    command = ${zsh} -l
    # Ghostty measures bytes, not lines: budget roughly 1 KiB per history line.
    scrollback-limit = ${toString (appearance.history * 1024)}
    auto-update = off
    ${lib.concatStringsSep "\n" (lib.imap0 (i: c: "palette = ${toString i}=${c}") (appearance.ansi ++ appearance.brights))}
    ${lib.concatMapStringsSep "\n" (s: "keybind = ${if isDarwin then "super" else "ctrl+shift"}+${s.ghostKey or s.key}=${s.ghost}") shortcuts}
    keybind = ctrl+tab=next_tab
    keybind = ctrl+shift+tab=previous_tab
    keybind = shift+page_up=scroll_page_up
    keybind = shift+page_down=scroll_page_down
    # Ghostty 1.3.1 scroll_page_* always consumes input, even with performable:
    # on the alternate screen. Leave plain paging to the child rather than
    # breaking less/vim; Ctrl+C also remains an ordinary shell interrupt.
    ${lib.concatMapStringsSep "\n" (direction: "keybind = ${if isDarwin then "super" else "ctrl+shift"}+alt+${direction.key}=goto_split:${direction.action}") [
      { key = "left"; action = "left"; }
      { key = "right"; action = "right"; }
      { key = "up"; action = "up"; }
      { key = "down"; action = "down"; }
    ]}
  '';
  weztermConfig = ''
    -- Generated shared terminal config.
    local wezterm = require 'wezterm'
    local act = wezterm.action
    local config = wezterm.config_builder()
    local windows = wezterm.target_triple:find('windows') ~= nil
    local mac = wezterm.target_triple:find('darwin') ~= nil
    local primary = mac and 'CMD' or 'CTRL|SHIFT'
    config.font = wezterm.font(windows and '${appearance.fontWindows}' or '${appearance.fontUnix}', { weight = '${if lib.hasInfix "Bold" appearance.style then "Bold" else "Regular"}', italic = ${lib.boolToString (lib.hasInfix "Italic" appearance.style)} })
    if windows then
      -- Automatic bold/dim selection falls back to differently sized JetBrains.
      -- Fantasque has no light face; dim text keeps Regular/Italic letterforms.
      config.font_rules = {
        { intensity = 'Bold', italic = false, font = wezterm.font('${appearance.fontWindows}', { weight = 'Bold', style = 'Normal' }) },
        { intensity = 'Bold', italic = true, font = wezterm.font('${appearance.fontWindows}', { weight = 'Bold', style = 'Italic' }) },
        { intensity = 'Half', italic = false, font = wezterm.font('${appearance.fontWindows}', { weight = 'Regular', style = 'Normal' }) },
        { intensity = 'Half', italic = true, font = wezterm.font('${appearance.fontWindows}', { weight = 'Regular', style = 'Italic' }) },
      }
    end
    config.font_size = windows and ${toString appearance.sizeWindows} or (mac and ${toString appearance.sizeMac} or ${toString appearance.sizeUnix})
    config.window_padding = { left = ${toString appearance.padding.x}, right = ${toString appearance.padding.x}, top = ${toString appearance.padding.y}, bottom = ${toString appearance.padding.y} }
    config.window_background_opacity = ${toString appearance.opacity}
    if windows or mac then
      config.window_background_opacity = ${toString backdrop.opacity}
      if windows then
        config.win32_system_backdrop = 'Acrylic'
      else
        config.macos_window_background_blur = ${toString backdrop.blurRadius}
      end
    end
    config.window_decorations = (windows or mac) and 'TITLE | RESIZE' or '${if lib.toLower appearance.decorations == "none" then "NONE" else "TITLE | RESIZE"}'
    config.default_cursor_style = '${if appearance.cursorBlink then "Blinking" else "Steady"}${{ Beam = "Bar"; Block = "Block"; Underline = "Underline"; }.${appearance.cursorShape}}'
    config.scrollback_lines = ${toString appearance.history}
    config.check_for_updates = false
    config.colors = {
      foreground = '${appearance.foreground}', background = '${appearance.background}',
      cursor_fg = '${appearance.background}',
      cursor_bg = '${appearance.foreground}', cursor_border = '${appearance.foreground}',
      ansi = ${builtins.replaceStrings [ "[" "]" ] [ "{" "}" ] (builtins.toJSON appearance.ansi)},
      brights = ${builtins.replaceStrings [ "[" "]" ] [ "{" "}" ] (builtins.toJSON appearance.brights)},
    }
    config.use_fancy_tab_bar = false
    config.hide_tab_bar_if_only_one_tab = true
    -- Keep application/OSC titles: ssh and shells remain ordinary child processes.
    config.tab_max_width = 32
    config.ssh_domains = {}
    config.unix_domains = {}
    config.wsl_domains = {}
    if windows then
      -- OpenGL works locally but fails on RDP. Do not force WebGPU there:
      -- a GPU-less VM exposes Microsoft's CPU-backed D3D adapter, which can
      -- peg every vCPU. WezTerm's Software frontend is its intended RDP path.
      local remote = (os.getenv('SESSIONNAME') or ""):upper():match('^RDP') ~= nil
      config.front_end = remote and 'Software' or 'OpenGL'
      if remote then
        -- RDP may expose only the CPU-based Microsoft Basic Render Driver.
        config.window_background_opacity = 1
        config.win32_system_backdrop = 'Disable'
        config.max_fps = 15
        config.animation_fps = 1
        config.cursor_blink_ease_in = 'Constant'
        config.cursor_blink_ease_out = 'Constant'
      else
        config.window_background_opacity = 0.6
      end
      -- Match hm_win's preference, including installations outside Program Files.
      local roots = { os.getenv('ProgramFiles') or "", os.getenv('LOCALAPPDATA') or "" }
      local pwsh = nil
      for _, root in ipairs(roots) do
        local path = root .. '/PowerShell/7/pwsh.exe'
        local f = io.open(path, 'rb')
        if f then f:close(); pwsh = path; break end
      end
      if not pwsh then
        for entry in (os.getenv('PATH') or ""):gmatch('[^;]+') do
          local path = entry:gsub('^"', ""):gsub('"$', "") .. '/pwsh.exe'
          local f = io.open(path, 'rb')
          if f then f:close(); pwsh = path; break end
        end
      end
      config.default_prog = { pwsh or 'powershell.exe', '-NoLogo' }
    else
      config.default_prog = { 'zsh', '-l' }
    end
    local function page(direction, key)
      return wezterm.action_callback(function(window, pane)
        if pane:is_alt_screen_active() then
          window:perform_action(act.SendKey { key = key, mods = 'NONE' }, pane)
        else
          window:perform_action(act.ScrollByPage(direction), pane)
        end
      end)
    end
    local paste = wezterm.action_callback(function(window, pane)
      if windows and pane:get_user_vars().nix_copilot == '1' then
        -- Copilot checks images on Ctrl+V but needs terminal paste for ordinary text.
        -- Let it own image access; do not spawn clipboard probes on the GUI thread.
        window:perform_action(act.SendKey { key = 'v', mods = 'CTRL' }, pane)
      end
      window:perform_action(act.PasteFrom('Clipboard'), pane)
    end)
    config.keys = {
      ${lib.concatMapStringsSep "\n" (s: "{ key = '${s.wezKey or s.key}', mods = primary, action = ${s.wez} },") shortcuts}
      { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
      { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
      { key = 'PageUp', mods = 'NONE', action = page(-1, 'PageUp') },
      { key = 'PageDown', mods = 'NONE', action = page(1, 'PageDown') },
      { key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) },
      { key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) },
      { key = 'LeftArrow', mods = primary .. '|ALT', action = act.ActivatePaneDirection('Left') },
      { key = 'RightArrow', mods = primary .. '|ALT', action = act.ActivatePaneDirection('Right') },
      { key = 'UpArrow', mods = primary .. '|ALT', action = act.ActivatePaneDirection('Up') },
      { key = 'DownArrow', mods = primary .. '|ALT', action = act.ActivatePaneDirection('Down') },
    }
    return config
  '';
in
{
  flake.lib = {
    inherit tabbyConfig tabbyPin weztermConfig;
    terminalAppearance = appearance;
    weztermPin = import ../overlays/wezterm-pin.nix;
  };
  flake.modules.homeManager.terminals = { pkgs, options, ... }:
    let
      tabby = mkTabbyPackage pkgs;
      tabbyYaml = (pkgs.formats.yaml { }).generate "tabby-config.yaml" (tabbyConfig {
        isDarwin = pkgs.stdenv.isDarwin;
      });
    in
    {
      config = lib.mkMerge ([
        {
          home.packages = [
            pkgs.wezterm
            (if pkgs.stdenv.isDarwin then pkgs.ghostty-bin else pkgs.ghostty)
            tabby
          ];
          # Normal HM collision checks apply: no force/clobber of local configs.
          xdg.configFile = {
            "wezterm/wezterm.lua".text = weztermConfig;
            "ghostty/config".text = ghostConfig pkgs.stdenv.isDarwin "${pkgs.zsh}/bin/zsh";
          } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
            "tabby/config.yaml".source = tabbyYaml;
          };
          home.file = lib.mkIf pkgs.stdenv.isDarwin {
            "Library/Application Support/tabby/config.yaml".source = tabbyYaml;
          };
        }
      ] ++ lib.optional (options.programs ? niri) {
        # Paint opaque and let niri apply 0.8 once, after its
        # catch-all 0.7 rule. No extra application-side alpha.
        programs.niri.settings.window-rules = lib.mkAfter [
          {
            matches = [
              { app-id = "^com\\.mitchellh\\.ghostty$"; }
              { app-id = "^org\\.wezfurlong\\.wezterm$"; }
              { app-id = "^tabby$"; }
            ];
            opacity = backdrop.opacity;
          }
        ];
      });
    };
}
