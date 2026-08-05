# Discovery — tell the humans what this machine can actually do.
#
# Why this exists
# ---------------
# The kid accounts (m, s on pb-t480 / m-pc) carry a large toolset they
# were never told about: the whole niri desktop (screenshot pipeline,
# clipboard history, screen recording, display arranger), FreeCAD,
# VS Code, the hardware-hacking flashing kit, opencode + copilot CLI,
# and ~40 terminal tools from the base/dev bundles. Before this module
# every discovery surface was PULL-only:
#
#   * `tools` (flake-modules/zsh.nix) renders terminal-help.md — but you
#     have to already know the word `tools`.
#   * niri's hotkey overlay (Mod+Shift+Slash) has
#     `skip-at-startup = true` and, historically, exactly one bind
#     carried a `hotkey-overlay.title` — so it rendered as a wall of raw
#     action names.
#   * fuzzel only shows things that ship a .desktop file.
#
# A doc nobody opens is a doc that does not exist, so this module adds a
# PUSH surface (one tip per day) on top of a better pull surface (a
# generated guide reachable from the launcher, a keybind, and the bar).
#
# It is NOT only for the kids. The "Running this machine" section is
# this flake's own operating surface — backup-restore, seed-from-host,
# auto-update-now, display-export, biometrics-enroll, hm_win, the
# rollback path, the `nix fmt .`-needs-a-path trap. Those fire once a
# quarter and are therefore forgotten by the person who wrote them.
#
# The four layers
# ---------------
#   1. `guide`   — the cheat sheet. Keybind tables are GENERATED from
#                  `programs.niri.settings.binds`; the "what's installed"
#                  tips are filtered at RUNTIME by `command -v`.
#   2. `tip`     — a rotating tip. The content advances every HOUR; the
#                  push surfaces are a mako notification at graphical
#                  login (discovery-tip.service) and a one-line zsh
#                  greeting in the first terminal opened each hour. Both
#                  share a single stamp file, so you only ever get one
#                  per hour per user, from whichever surface you reach
#                  first. There is deliberately NO hourly notification
#                  timer — see the comment on discovery-tip.service.
#   3.           — `hotkey-overlay.title` backfill lives in
#                  flake-modules/niri/binds.nix + displays.nix, not here.
#   4.           — the zsh greeting hook, below.
#
# Three design decisions worth keeping
# ------------------------------------
# * A bind appears in the guide IFF it has a `hotkey-overlay.title`.
#   The title is simultaneously the human text niri's own overlay shows
#   and this module's curation marker ("if I bothered to name it, it's
#   worth telling someone about"). One source of truth, so the guide
#   cannot drift from the binds — the 100-odd unnamed navigation binds
#   stay out of the table and remain discoverable via Mod+Shift+Slash.
# * Tips are gated at RUNTIME, not eval time. `command -v freecad`
#   means a kid who doesn't have FreeCAD never sees the FreeCAD tip,
#   without this module having to know which bundle they're on. Tips
#   marked `admin = true` additionally require wheel/admin membership —
#   the maintenance wrappers are installed system-wide, so they sit on
#   the kids' PATH too and a probe alone would leak them.
# * The module lives in the BASE bundle, so it is also evaluated on
#   headless WSL and on macOS. Everything desktop-shaped — the keybind,
#   the launcher entry, the login notification, the alacritty re-exec —
#   is gated on `hasNiri`, computed from the DECLARED-option tree
#   (`options.programs ? niri`). The zsh greeting is deliberately NOT
#   gated: on a headless host it's the only push surface there is.
#
# The waybar `custom/help` button is defined in desktop-shell.nix, not
# here, because `programs.waybar.settings` is `types.anything` and lists
# do not merge across modules.
#
# Retire when: nobody opens the guide and nobody misses the tips, OR the
#   desktop moves to a shell with a first-class built-in cheat-sheet
#   surface that we'd rather feed.
# Takes the outer flake-parts `config` (bound as `outer`) to reach
# `flake.lib.mkMarkdownViewer`. The inner HM module body shadows
# `config`, so the outer one must be captured here — see the
# "Cross-module signals" section of AGENTS.md.
{ config, ... }:
let
  outer = config;
in
{
  flake.modules.homeManager.discovery = { config, options, lib, pkgs, ... }:
    let
      # ── Portability ───────────────────────────────────────────────
      # This module lives in the BASE bundle, so it also evaluates on
      # headless WSL and on macOS, where there is no compositor, no
      # notification daemon and no bar. Everything desktop-shaped is
      # gated on `hasNiri`.
      #
      # `options.programs ? niri` is the safe test: `options` is the
      # DECLARED-option tree, so probing it cannot depend on any value
      # this module defines (testing `config.programs ? niri` while also
      # defining `programs.niri.settings.binds` would be a recursion).
      # niri's HM options only exist when inputs.niri.homeModules.niri
      # has been imported, i.e. when flake.modules.homeManager.niri is.
      hasNiri = options.programs ? niri;
      isLinux = pkgs.stdenv.hostPlatform.isLinux;

      # ── Keybind table, generated from the live binds ───────────────
      binds = if hasNiri then config.programs.niri.settings.binds else { };

      # niri-flake renders `hotkey-overlay` as `{ hidden = false; }` when
      # untouched and `{ title = "…"; }` when a title is set, so `? title`
      # is the reliable test. Verified against the evaluated config.
      titled = lib.filterAttrs (_: v: (v.hotkey-overlay or { }) ? title) binds;

      # `action` always carries exactly one attribute — the action name.
      actionOf = v: lib.head (lib.attrNames v.action);

      # Groups are derived from the action name so they can't drift. The
      # override table only exists for binds whose action name lies about
      # what they're for (a `spawn` of the screenshot wrapper is a
      # screenshot, not an app launch). Stale entries are harmless — an
      # override for a key that no longer exists is simply never read.
      groupOverrides = {
        "Print" = "Screenshots & recording";
        "Shift+Print" = "Screenshots & recording";
        "Mod+Ctrl+Shift+S" = "Screenshots & recording";
        "Mod+Shift+C" = "Screenshots & recording";
        "Mod+O" = "Windows & layout";
        "Mod+Shift+V" = "Windows & layout";
        "Mod+Shift+Slash" = "Apps & tools";
        "Mod+D" = "Screens & session";
        "Mod+Shift+D" = "Screens & session";
        "Super+Alt+L" = "Screens & session";
        "Mod+Escape" = "Screens & session";
      };

      groupOf = key: v:
        let a = actionOf v; in
          groupOverrides.${key} or (
            if lib.hasInfix "screenshot" a then "Screenshots & recording"
            else if a == "spawn" then "Apps & tools"
            else if lib.hasInfix "workspace" a then "Workspaces"
            else if lib.hasInfix "monitor" a then "Screens & session"
            else if lib.hasInfix "column" a || lib.hasInfix "window" a then "Windows & layout"
            else "Screens & session"
          );

      groupOrder = [
        "Apps & tools"
        "Screenshots & recording"
        "Windows & layout"
        "Workspaces"
        "Screens & session"
      ];

      # Several keys often share one title (Mod+Left and Mod+H both focus
      # the column to the left). Collapse them onto a single row rather
      # than printing near-duplicate lines.
      keysByTitle = group:
        let
          inGroup = lib.filterAttrs (k: v: groupOf k v == group) titled;
        in
        builtins.foldl'
          (acc: k:
            let t = inGroup.${k}.hotkey-overlay.title; in
            acc // { ${t} = (acc.${t} or [ ]) ++ [ k ]; })
          { }
          (lib.attrNames inGroup);

      keyTable = group:
        let rows = keysByTitle group; in
        lib.optionals (rows != { }) ([
          "### ${group}"
          ""
          "| Keys | What it does |"
          "| --- | --- |"
        ] ++ lib.mapAttrsToList
          (title: keys:
            "| ${lib.concatMapStringsSep " · " (k: "`${k}`") keys} | ${title} |")
          rows
        ++ [ "" ]);

      presentGroups =
        let all = lib.unique (lib.mapAttrsToList groupOf titled); in
        (lib.filter (g: lib.elem g all) groupOrder)
        ++ (lib.filter (g: !(lib.elem g groupOrder)) all);

      keybindDoc = lib.optionalString hasNiri (lib.concatStringsSep "\n" (
        [
          "## ⌨️  Desktop shortcuts"
          ""
          "`Mod` is the **Windows / Super** key — bottom-left, next to Alt."
          ""
        ]
        ++ lib.concatMap keyTable presentGroups
        ++ [
          "Not everything is listed here — press `Mod+Shift+/` for the"
          "complete list of every key the desktop knows."
          ""
        ]
      ));

      # ── Tips ──────────────────────────────────────────────────────
      # `probe` = a command that must exist on PATH for the tip to be
      # shown (null = always). `admin = true` additionally hides the tip
      # from anyone not in wheel/admin — the maintenance commands exist on
      # the kids' machines too, so a probe alone would leak them.
      # `short` is the one-liner used by the login notification and the
      # zsh greeting; `body` is the Markdown block used by the guide,
      # defaulting to `short`.
      sectionTitles = {
        desktop = "🖥️  Desktop tricks";
        ai = "🤖 Robot helpers";
        make = "🔨 Making things";
        science = "🔬 Simulate & experiment";
        terminal = "⌨️  Terminal superpowers";
        media = "🎵 Files & media";
        admin = "🛠️  Running this machine";
      };
      sectionOrder = [ "desktop" "ai" "make" "science" "terminal" "media" "admin" ];

      tips = [
        {
          section = "desktop";
          probe = "screenshot";
          title = "Screenshot anything, then scribble on it";
          short = "Press Print, drag a box — an editor opens so you can draw arrows and text before you save.";
          body = ''
            Press **Print** and drag a box around anything on screen. An
            editor opens with the shot already loaded: draw arrows, add
            text, blur out something private, then save or copy it.

            | Keys | Grabs |
            | --- | --- |
            | `Print` | a region you drag out |
            | `Shift+Print` | the whole screen |
            | `Alt+Print` | just the window you're using |

            Shots are saved into `~/Pictures/screenshots/`.
          '';
        }
        {
          section = "desktop";
          probe = "clipboard-pick";
          title = "Your clipboard remembers everything you copied";
          short = "Press Mod+Shift+C to pick from the last things you copied — text and images both.";
          body = ''
            Copied something, then copied something else, then wanted the
            first thing back? Press **`Mod+Shift+C`**. A search box lists
            everything you've copied recently — type to filter, press
            Enter, and it's on your clipboard again. Images too.
          '';
        }
        {
          section = "desktop";
          probe = "wf-recorder";
          title = "Record your screen as a video";
          short = "Mod+Ctrl+Shift+S starts recording the screen; press it again to stop.";
          body = ''
            Press **`Mod+Ctrl+Shift+S`** to start recording, and the same
            keys again to stop. The video lands in `~/Videos/recording.mp4`
            — handy for showing someone a bug, or for a school project.

            (It overwrites the same filename each time, so rename the one
            you want to keep before recording again.)
          '';
        }
        {
          section = "desktop";
          probe = "niri";
          title = "See every window at once";
          short = "Press Mod+O for a zoomed-out view of all your windows and workspaces.";
          body = ''
            Press **`Mod+O`**. Everything you have open shrinks down into
            one overview so you can see where things are, then click (or
            arrow to) the one you want. Press `Mod+O` again to go back.

            Lost a window entirely? This is how you find it.
          '';
        }
        {
          section = "desktop";
          probe = "niri";
          title = "Windows don't have to be tiled";
          short = "Mod+V pops the current window out as a free-floating one; Mod+W stacks a column into tabs.";
          body = ''
            The desktop normally lines windows up side by side, but you can
            escape that:

            | Keys | What happens |
            | --- | --- |
            | `Mod+V` | make this window float freely, drag it anywhere |
            | `Mod+Shift+V` | jump between the floating and tiled windows |
            | `Mod+W` | stack a column into **tabs**, one visible at a time |
            | `Mod+F` | make this window fill the screen width |
            | `Mod+Shift+F` | true fullscreen |
          '';
        }
        {
          section = "desktop";
          probe = "wdisplays";
          title = "Plugged in a monitor or a TV? Arrange it yourself";
          short = "Mod+D opens the screen arranger — drag the screens around, then Mod+Shift+D to remember it.";
          body = ''
            Press **`Mod+D`** to open the screen arranger. Drag the
            rectangles so they match where the real screens are, set the
            resolution, then press **`Mod+Shift+D`** to save the layout so
            it comes back automatically next time you plug that screen in.

            No password and no help from an adult needed — this is yours.
          '';
        }
        {
          section = "desktop";
          probe = "blueman-manager";
          title = "Pair Bluetooth headphones yourself";
          short = "Click the Bluetooth icon in the top bar to pair headphones, a speaker, or a controller.";
          body = ''
            Click the **Bluetooth icon** in the top-right of the bar. Put
            your headphones (or speaker, or game controller) into pairing
            mode, and pick them from the list.

            The other icons up there are clickable too: the **wifi** icon
            opens the network picker, the **speaker** icon opens the volume
            mixer, and you can **scroll on the brightness** icon to dim the
            screen.
          '';
        }
        {
          section = "make";
          probe = "freecad";
          title = "Design real 3D parts";
          short = "FreeCAD is installed — design a part with real measurements and export it for a 3D printer.";
          body = ''
            **FreeCAD** is in your app menu (`Super+Space`, type "freecad").
            It's a proper parametric CAD program: draw a shape with real
            millimetre dimensions, give it thickness, and change a number
            later to have the whole model update.

            Export as `.stl` and it's ready for a 3D printer. Good first
            project: a phone stand, or a bracket to fix something broken.
          '';
        }
        {
          section = "make";
          probe = "Fritzing";
          title = "Draw circuits before you build them";
          short = "Fritzing draws breadboard layouts; CircuitJS simulates a circuit live with animated current.";
          body = ''
            **Fritzing** (in the app menu) lets you lay out a breadboard
            visually — drag in an Arduino, an LED, a resistor, and it draws
            the wires. It'll also turn that into a schematic and a PCB.

            **CircuitJS** (also in the app menu) is different and honestly
            more fun: build a circuit and watch the current animate through
            it in real time. Great for actually *seeing* what a capacitor
            or a transistor does.
          '';
        }
        {
          section = "make";
          probe = "picocom";
          title = "Talk to microcontrollers — no admin needed";
          short = "Plug in a Pico/ESP32/Arduino and flash it straight from your own account; you're already in the right groups.";
          body = ''
            Plug in a Raspberry Pi Pico, ESP32, or Arduino and it just
            works from your own account — you're already in the
            `dialout`/`plugdev` groups, so no sudo and no asking anyone.

            | Command | For |
            | --- | --- |
            | `lsusb` | check the board is actually detected |
            | `picocom -b 115200 /dev/ttyUSB0` | open its serial console (quit with `Ctrl-A Ctrl-X`) |
            | `esptool` | flash an ESP8266 / ESP32 |
            | `picotool` | poke at a Raspberry Pi Pico |
            | `arduino-cli` | build and upload Arduino sketches from the terminal |
            | `avrdude` | program classic Arduino Uno/Nano chips |
            | `probe-rs` · `openocd` | flash and *debug* over SWD/JTAG |

            There's a full ARM toolchain here too (`arm-none-eabi-gcc`), so
            you can write firmware from scratch, not just Arduino sketches.
          '';
        }
        {
          section = "make";
          probe = "kicad";
          title = "Design an actual circuit board";
          short = "KiCad is installed — draw a schematic and lay out a PCB you could have manufactured.";
          body = ''
            **KiCad** does the whole path from schematic to a real printed
            circuit board: place components, route the copper, view it in
            3D, and export the files a factory needs to make it.
          '';
        }
        {
          section = "make";
          probe = "code";
          title = "VS Code is here for real projects";
          short = "Run `code .` in any folder to open it in VS Code.";
          body = ''
            Type **`code .`** in a terminal to open the folder you're in.
            Works for Python, JavaScript, C, Nix — anything. Extensions,
            the debugger, and the built-in terminal all work.
          '';
        }
        {
          section = "make";
          probe = "nix-locate";
          title = "You can run almost any program ever packaged, without installing it";
          short = "`, blender` fetches Blender, runs it once, and forgets it. Same for ~100,000 other programs.";
          body = ''
            This is the most under-used thing on this machine. Put a comma
            in front of a program you don't have, and it appears:

            ```
            , blender          # 3D modelling, animation, physics
            , krita            # painting
            , inkscape         # vector drawing
            , sonic-pi         # make music by writing code
            , stellarium       # planetarium: the real sky, any date
            , openscad         # design 3D objects by writing code
            , gnuplot          # plot maths
            , thonny           # MicroPython editor for the Pico
            ```

            It downloads it, runs it, and doesn't clutter the machine —
            nothing is permanently installed and nothing can break anything
            else. First run is slow (it's fetching), after that it's
            instant.

            When several packages provide the same command, `,` asks which
            one you meant. If you already know, be exact:

            ```
            nix run nixpkgs#godot
            nix run nixpkgs#kdePackages.step
            ```

            **If you find something you use every week, say so** — it can
            be properly installed, with an icon in the launcher.
          '';
        }
        {
          section = "make";
          probe = "niri";
          title = "3D, animation, and physics you can actually watch";
          short = "`, blender` is a full 3D studio — and its physics engine will drop, tear, splash and burn things for you.";
          body = ''
            Run **`, blender`**. It's the same program used on real films,
            and it's free.

            Beyond modelling, its simulators are the fun part — set them
            running and watch:

            | Simulation | Try |
            | --- | --- |
            | Rigid body | a tower of blocks collapsing |
            | Cloth | a flag in wind, a sheet dropped over a chair |
            | Soft body | jelly, a bouncing ball that squashes |
            | Fluid | water poured into a glass |
            | Smoke & fire | a rocket exhaust |
            | Particles | rain, sparks, hair, grass |

            It's also a video editor and a motion-graphics tool. Enormous
            and confusing at first — start with "Blender donut tutorial",
            which is the traditional rite of passage.
          '';
        }
        {
          section = "make";
          probe = "niri";
          title = "Design 3D objects by writing code";
          short = "`, openscad` builds shapes from a script — change a number, the object updates. Pairs with FreeCAD.";
          body = ''
            **`, openscad`** models by *programming* rather than drawing:

            ```
            difference() {
              cube([30, 30, 10], center = true);
              cylinder(h = 20, r = 8, center = true);
            }
            ```

            That's a block with a hole through it. Change `r = 8` and the
            hole resizes. Add `for (i = [0:5])` and you have six of them.

            Which makes it perfect for things with maths in them —
            gear teeth, a phone stand parameterised by phone thickness, a
            box sized from a variable. Export STL and print it.

            FreeCAD is the mouse-driven counterpart; use whichever suits
            the shape.
          '';
        }
        {
          section = "make";
          probe = "niri";
          title = "Make a game";
          short = "`nix run nixpkgs#godot` is a full 2D/3D game engine; `, love` is a tiny Lua one; `, luanti` is a moddable voxel world.";
          body = ''
            | Try | What it is |
            | --- | --- |
            | `nix run nixpkgs#godot` | a complete game engine — 2D and 3D, visual editor, its own easy language (GDScript). Real games ship on this. |
            | `, love` | LÖVE: a tiny 2D framework where you just write Lua. One file, and you have a game. Fastest path from zero to something moving. |
            | `, luanti` | a Minecraft-like voxel world you can mod in Lua — change the game while you're inside it |

            Start with LÖVE if you want something on screen in an hour;
            move to Godot when you want menus, physics and a build you can
            hand to a friend.
          '';
        }
        {
          section = "make";
          probe = "niri";
          title = "Make music by writing code";
          short = "`, sonic-pi` plays whatever you type, live — edit the loop while it's running and it changes underneath you.";
          body = ''
            **`, sonic-pi`**. You type music and press run:

            ```ruby
            live_loop :beat do
              sample :bd_haus
              sleep 0.5
            end

            live_loop :tune do
              play scale(:e3, :minor_pentatonic).choose
              sleep 0.25
            end
            ```

            Edit while it's playing and it changes without stopping. It was
            built for teaching programming, so loops, randomness and
            functions all arrive as things that *make an audible
            difference* — which is a much better feedback loop than
            printing to a terminal.
          '';
        }
        {
          section = "make";
          probe = "niri";
          title = "Draw, paint and design";
          short = "`, krita` for painting and digital art; `, inkscape` for logos, stickers and anything that must scale.";
          body = ''
            | Try | Good for |
            | --- | --- |
            | `, krita` | painting and drawing — built for artists, brush engine, animation timeline. Works properly with a drawing tablet. |
            | `, inkscape` | vector graphics: logos, posters, stickers, diagrams. Scales to any size without going blurry, and exports SVG for laser cutters and vinyl cutters. |

            Inkscape output also feeds straight into the maker chain — an
            SVG can become a laser-cut part or a KiCad board outline.
          '';
        }
        {
          section = "science";
          probe = "niri";
          title = "Physics you can poke at";
          short = "`nix run nixpkgs#kdePackages.step` simulates springs, gravity and collisions live — drag things mid-experiment and watch what changes.";
          body = ''
            **`nix run nixpkgs#kdePackages.step`** is an interactive physics
            sandbox. Drop in masses, springs, charges, gravity, friction —
            press play and it solves the equations and animates the result.
            You can grab an object *while it's running* and watch the whole
            system respond, and graph any quantity (velocity, energy) as it
            evolves.

            It's the fastest way to answer "what would actually happen
            if…" without setting anything up.

            Same idea, pointed at the sky:

            | Try | Shows |
            | --- | --- |
            | `, stellarium` | the real sky from anywhere on Earth, at any date — wind time forwards and watch an eclipse happen |
            | `, celestia` | fly out of the solar system in 3D, to scale |
          '';
        }
        {
          section = "science";
          probe = "google-chrome-stable";
          title = "Simulators that need nothing but the browser";
          short = "PhET, Wokwi and GeoGebra run instantly in Chrome — real physics sims, a virtual Arduino, and maths that draws itself.";
          body = ''
            No install, no waiting, works on any machine:

            | Site | What it does |
            | --- | --- |
            | **phet.colorado.edu** | hundreds of physics/chemistry/maths simulations from the University of Colorado — pendulums, circuits, gravity, waves, gas laws. Change a slider, watch the physics change. |
            | **wokwi.com** | a *virtual* Arduino / ESP32 / Pico with virtual LEDs, sensors and displays. Write the code and watch the LED blink with no hardware plugged in — then flash the same code to the real board. |
            | **geogebra.org** | graph an equation and drag it; geometry, calculus and 3D plots |
            | **falstad.com/circuit** | animated circuit simulator (also installed here as **CircuitJS** in the app menu) |
            | **tinkercad.com** | 3D design and circuits in the browser, gentler than FreeCAD |

            Wokwi in particular pairs beautifully with the real boards in
            the drawer: prototype in the simulator, then flash the hardware.
          '';
        }
        {
          section = "science";
          probe = "niri";
          title = "Simulate the circuit before you solder it";
          short = "`, ngspice` runs the real SPICE simulator; KiCad has one built in; CircuitJS animates the current.";
          body = ''
            Three levels of the same idea:

            | Tool | Level |
            | --- | --- |
            | **CircuitJS** (app menu) | see it — current animates as coloured dots, components glow. Best for *understanding*. |
            | **KiCad → Simulate** | draw the schematic you're going to build and run it, using ngspice underneath. Best for *checking your design*. |
            | `, ngspice` | the raw SPICE engine on a netlist. Best for *sweeping* — run the same circuit at 50 different resistor values and plot the result. |

            Worth doing before you commit: a simulator will tell you a
            resistor is about to cook in a way that a breadboard tells you
            with smoke.
          '';
        }
        {
          section = "science";
          probe = "nix-locate";
          title = "Maths that draws itself";
          short = "`, gnuplot` plots anything; `, maxima` does algebra and calculus symbolically; `, octave` is free MATLAB.";
          body = ''
            | Try | Does |
            | --- | --- |
            | `, gnuplot` | plot a function or a data file. `plot sin(x)/x` and it's on screen. |
            | `, maxima` | *symbolic* maths — it doesn't approximate, it solves. `diff(x^3, x);`, `integrate(1/x, x);`, `solve(x^2-4=0, x);` |
            | `, octave` | free MATLAB: matrices, signal processing, numerical everything |
            | `numbat` | already installed — a calculator that tracks units, so `120 km/h -> mph` just works |

            `maxima` is the one worth knowing about early: it will do your
            calculus homework *and show the steps*, which makes it a
            checker rather than a cheat.
          '';
        }
        {
          section = "science";
          probe = "uv";
          title = "Notebooks: code, graphs and notes on one page";
          short = "`uv run --with jupyterlab --with matplotlib --with numpy jupyter lab` gives you a notebook with zero setup.";
          body = ''
            A notebook mixes text, code and the graph the code produced,
            all in one scrolling document — the standard way science and
            data work gets done, and an excellent format for a school
            project.

            ```sh
            uv run --with jupyterlab --with matplotlib --with numpy \
              jupyter lab
            ```

            That one line fetches everything into a throwaway environment
            and opens it in your browser. Nothing is installed permanently
            and nothing can break; run it again with different `--with`
            packages whenever you need something else (`--with pandas`,
            `--with sympy`, `--with scipy`).
          '';
        }
        {
          section = "ai";
          probe = "copilot";
          title = "There's an AI in your terminal";
          short = "Run `copilot` in any folder and describe what you want — it reads and writes the files itself.";
          body = ''
            Run **`copilot`** in a project folder and talk to it in plain
            English: *"why does this script crash?"*, *"add a dark mode to
            this page"*. Unlike a chat window, it can actually read your
            files, edit them, and run commands — it asks before doing
            anything destructive.

            Best used as a pair-programmer: ask it to *explain* code you
            didn't write before you ask it to change it.
          '';
        }
        {
          section = "ai";
          probe = "opencode";
          title = "A second AI coding assistant";
          short = "`opencode` is another terminal AI agent — a different tool with a full-screen interface.";
          body = ''
            **`opencode`** is a second AI coding agent with a full-screen
            terminal interface. Same idea as `copilot`, different tool —
            worth trying both and seeing which one you get on with.
          '';
        }
        {
          section = "ai";
          probe = "copilot";
          title = "Make the AI explain it, don't just take the answer";
          short = "Ask \"why\", ask for two different approaches, ask it to quiz you — that's how you end up smarter instead of stuck.";
          body = ''
            The difference between an AI that makes you better and one that
            makes you helpless is entirely in how you ask. Things that work:

            - *"Explain this file to me like I've never seen this language."*
            - *"Give me two different ways to do this and tell me the
              trade-offs."*
            - *"Don't write it yet — tell me what you'd do and why."*
            - *"I think the bug is in X. Am I right? Don't fix it, just
              tell me if I'm on the right track."*
            - *"Quiz me on this code until I can explain it back to you."*

            And the important habit: **it is confidently wrong sometimes.**
            When it tells you a fact, ask *"how would I check that
            myself?"* — then go and check it. Running the code is the
            check.
          '';
        }
        {
          section = "ai";
          probe = "copilot";
          title = "Ask the AI about this computer itself";
          short = "Everything about this machine is text files in ~/nixos — point `copilot` at them and ask.";
          body = ''
            This whole computer — every program installed, every keyboard
            shortcut, the way the screen locks — is described by text files
            in `~/nixos`. That means you can ask about it:

            ```
            cd ~/nixos
            copilot
            ```

            Then try: *"what does flake-modules/niri.nix actually do?"*,
            *"where is the keyboard shortcut for screenshots defined?"*,
            *"how would I add a shortcut that opens a calculator?"*

            It can explain how any of it works, and it can draft the change
            for you. Don't apply it yourself — show it to whoever runs the
            machine. But understanding it is the whole point: nothing here
            is magic, it's just files.
          '';
        }
        {
          section = "ai";
          probe = "picocom";
          title = "Get the AI to write firmware for the board in your hand";
          short = "Plug in a Pico or ESP32, tell `copilot` what you want it to do, and have it explain every line before you flash it.";
          body = ''
            This is the fun one, because the result blinks.

            1. Plug in a Raspberry Pi Pico / ESP32 / Arduino.
            2. Run `copilot` and say what you want: *"write MicroPython for
               a Pico that fades an LED on GP15 with a sine wave"*, or
               *"read a DHT22 on GP2 and print the temperature every 5
               seconds"*.
            3. Then — before flashing it — *"explain each line to me"*.
            4. Flash it, watch it not work, paste the error back, iterate.

            The loop of *idea → code → real hardware doing a thing → it's
            wrong → fix it* is the single best way to learn embedded
            programming, and the AI removes the "I don't know the syntax"
            wall without removing the thinking.

            For MicroPython on a Pico, `, thonny` gives you an editor that
            talks to the board directly.
          '';
        }
        {
          section = "terminal";
          probe = "tools";
          title = "There's a whole guide to the terminal";
          short = "Type `tools` for a friendly page listing every terminal command set up on this machine.";
          body = ''
            Type **`tools`** in a terminal. It opens a full guide to every
            command installed here, written to be readable rather than
            correct-and-cryptic. Press `q` to close it.

            Also: **`tldr <command>`** gives you real examples of any
            command instead of a wall of options — try `tldr tar`.
          '';
        }
        {
          section = "terminal";
          probe = "zoxide";
          title = "Stop typing long folder paths";
          short = "After visiting a folder once, `z partofitsname` jumps straight back there from anywhere.";
          body = ''
            Once you've been in a folder, you never have to type its path
            again. From anywhere:

            ```
            z school
            ```

            jumps to the folder you visit most whose name contains
            "school". It learns from where you actually go.
          '';
        }
        {
          section = "terminal";
          probe = "atuin";
          title = "Search everything you've ever typed";
          short = "Press Ctrl+R and type a few letters to find any command you've run before.";
          body = ''
            Press **`Ctrl+R`** and start typing. It searches your entire
            command history — including from other terminals and other
            days — and shows when you ran each one and whether it worked.
            Arrow to the one you want, press Enter.

            This is the single biggest time-saver in the terminal.
          '';
        }
        {
          section = "terminal";
          probe = "nix-locate";
          title = "Mistyped commands tell you what to install";
          short = "Type a command you don't have and the shell names the package that provides it — then `, cmd` runs it once.";
          body = ''
            Type any command that isn't installed and, instead of a bare
            "command not found", the shell tells you which package provides
            it. Put a comma in front to run it right there without
            installing anything:

            ```
            , cowsay hello
            , sl
            , figlet BIG TEXT
            ```

            Great for trying something you read about online before
            deciding whether you actually want it.

            This works for **graphical** programs too — see "You can run
            almost any program ever packaged" for the interesting list.
          '';
        }
        {
          section = "terminal";
          probe = "yazi";
          title = "A file manager inside the terminal";
          short = "Type `yazi` to browse files with arrow keys and live previews of images and text.";
          body = ''
            Type **`yazi`**. Arrow keys move around, and the right pane
            previews whatever is selected — including images, PDFs and
            code. Press `q` to leave, and it drops you in the folder you
            ended up in.
          '';
        }
        {
          section = "terminal";
          probe = "lazygit";
          title = "Git without memorising git";
          short = "Type `lg` to stage, commit, branch and push from a visual interface.";
          body = ''
            Type **`lg`**. Stage individual lines, write a commit message,
            switch branches, look at history, push — all from a keyboard-
            driven interface, no memorised commands required.
          '';
        }
        {
          section = "terminal";
          probe = "numbat";
          title = "A calculator that understands units";
          short = "`numbat` does maths with real units: `120 km/h -> mph`, or `3 GiB / 20 MB/s -> minutes`.";
          body = ''
            Run **`numbat`** and type things like:

            ```
            120 km/h -> mph
            3 GiB / (20 MB/s) -> minutes
            sqrt(2) * 5 cm
            180 degrees -> radians
            ```

            It tracks the units through the whole calculation and refuses
            to add metres to seconds — so it catches mistakes a normal
            calculator would happily give you a wrong answer for.
          '';
        }
        {
          section = "terminal";
          probe = "uv";
          title = "Python projects that don't break each other";
          short = "`uv init`, `uv add requests`, `uv run script.py` — instant, isolated Python environments.";
          body = ''
            **`uv`** is the fast way to do Python here:

            ```
            uv init myproject && cd myproject
            uv add requests
            uv run main.py
            ```

            Each project gets its own isolated set of packages, so
            installing something for one project can never break another.
          '';
        }
        {
          section = "terminal";
          probe = "duckdb";
          title = "Ask questions of a spreadsheet";
          short = "`duckdb` runs SQL directly on CSV files — no import step, no database to set up.";
          body = ''
            Got a CSV of anything — game stats, weather, an export from a
            website? Run **`duckdb`** and query it directly:

            ```sql
            SELECT team, avg(score) FROM 'games.csv' GROUP BY team;
            ```

            No importing, no setup. **`vd file.csv`** (visidata) is the
            point-and-click version of the same idea.
          '';
        }
        {
          section = "media";
          probe = "thunar";
          title = "USB sticks and phones, without asking anyone";
          short = "Mod+E opens the file manager; USB sticks and Android phones mount on their own.";
          body = ''
            Press **`Mod+E`** for the file manager. Plug in a USB stick and
            it appears in the sidebar — click to mount it, no password.
            Android phones show up too, so you can pull photos off them.

            Right-click a `.zip` to extract it.
          '';
        }
        {
          section = "media";
          probe = "mpv";
          title = "Play any video or image";
          short = "`mpv file.mkv` plays anything; `imv picture.png` is an instant image viewer.";
          body = ''
            **`mpv`** plays essentially any video or audio file, including
            straight from a URL. **`imv`** is a fast image viewer, and
            **VLC** is in the app menu if you'd rather click.
          '';
        }

        # ── Admin section ────────────────────────────────────────────
        # This flake's own operating surface. These wrappers are
        # installed system-wide, so they're on the kids' PATH too — hence
        # `admin = true`, which gates them on wheel/admin membership at
        # runtime on top of the usual probe. Everything here is a thing
        # that fires once a quarter and is therefore forgotten by the
        # person who wrote it.
        {
          section = "admin";
          admin = true;
          probe = "auto-update-status";
          title = "This host updates itself — here's how to see it";
          short = "`auto-update-status` shows the policy, the last run and the next fire; `sudo auto-update-now` bypasses every gate.";
          body = ''
            Every NixOS host polls hourly and rebuilds from `origin/main`
            when it's a good moment (quiet window 02:00–09:00 or >24h since
            the last success, on wall power, GitHub reachable).

            | Command | Does |
            | --- | --- |
            | `auto-update-status` | policy, last run, last success, next fire |
            | `sudo auto-update-now` | run right now, bypassing every gate |
            | `sudo systemctl stop auto-update.timer` | go quiet during a long refactor |

            The gate is an `ExecCondition=`, so "not now" leaves the unit
            *inactive*, not failed. Full write-up: `docs/auto-update.md`.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "backup-snapshots";
          title = "Restoring from backup, and seeding a new machine";
          short = "`sudo backup-snapshots` lists this host's restic snapshots; `sudo backup-restore` pulls the latest back.";
          body = ''
            One restic-over-SFTP repo per host, daily at 03:00, gated on
            wall power. Everything under `/persist` — the rest of the disk
            is wiped to a blank subvolume on every boot.

            | Command | Does |
            | --- | --- |
            | `sudo backup-snapshots` | list snapshots in this host's repo |
            | `sudo backup-restore` | restore the latest, whole `/persist` |
            | `sudo backup-restore --include /persist/home/p` | restore one path |
            | `./scripts/seed-from-host.sh --from pb-x1 --user p` | pull a home directory out of *another* host's repo |
            | `./scripts/init-backup.sh` | one-time bootstrap on a fresh host |

            Seeding never touches `/persist` itself — machine-id,
            NetworkManager state and SSH host keys are host-specific.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "display-export";
          title = "Promote a monitor layout back into the flake";
          short = "Arrange with Mod+D, save with Mod+Shift+D, then `display-export` prints the Nix to paste into the host bridge.";
          body = ''
            The full loop, none of which needs a rebuild until the last
            step:

            | Command | Does |
            | --- | --- |
            | `Mod+D` | drag the screens into place (wdisplays) |
            | `Mod+Shift+D` | persist it to `~/.config/niri/outputs.local.kdl` |
            | `display-export` | print that layout as Nix, ready to paste into `displays.outputs` in the host bridge |
            | `display-reset` | drop the local override and fall back to the declared layout |

            The local file wins over the declarative layout while it
            exists — so `display-reset` is what you run after promoting.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "nixos-rebuild";
          title = "The rebuild commands, and the `nix fmt` trap";
          short = "`nix fmt .` needs the path argument or it blocks reading stdin; `nix flake check` must stay pure.";
          body = ''
            | Command | Does |
            | --- | --- |
            | `sudo nixos-rebuild switch --flake .#$(hostname)` | system |
            | `home-manager switch --flake .#"$USER@$(hostname)"` | user |
            | `nix fmt .` | format — **the path is required**, bare `nix fmt` hangs reading stdin |
            | `nix flake check` | evaluate + build everything, exactly as a real host does |

            Inside the dev shell, `nh os switch` and
            `nh home switch <user>@<host>` do the same with a closure diff,
            and work from anywhere in the repo.

            Never add `--impure` or `NIXOS_ALLOW_PLACEHOLDER=1` to CI or to
            the pre-push hook: a real host deploys via
            `nixos-rebuild --flake github:…`, which evaluates **purely**,
            and under pure eval `builtins.getEnv` always returns `""`.
            A green check that used `--impure` once hid a host whose every
            upgrade aborted, for months.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "nixos-rebuild";
          title = "Rolling back a bad generation";
          short = "Pick the previous generation from the boot menu, or `sudo nixos-rebuild switch --rollback` if it still boots.";
          body = ''
            If it still boots: `sudo nixos-rebuild switch --rollback`, or
            `nixos-rebuild list-generations` then
            `sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch`.

            If it doesn't: pick an older generation from the boot menu.

            Home-manager rolls back separately —
            `home-manager generations`, then run the `activate` script of
            the one you want.

            And on an impermanent host, the pre-rollback root subvolumes
            are kept for 30 days under `/btrfs_tmp/old_roots/<timestamp>/`
            — that's where "I forgot to add this to the persistence list"
            gets recovered from.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "timekpra";
          title = "Adjusting the kids' screen time";
          short = "`timekpra` is the admin GUI; the shared cross-host budget lives on the dashboard at screentime.bitset.cc.";
          body = ''
            **`timekpra`** opens the admin GUI for ad-hoc adjustments;
            `timekprc` is the client view.

            The important thing to remember, because it looks like a bug
            every single time: the **daily budget and the allowed-hours
            window are independent axes**. Time left is
            `min(budget, per-hour limits)`, so granting bonus time can
            never open a blocked curfew hour — a kid with 5 hours of
            budget is still locked out at 22:01.

            The shared budget across hosts is spent against the controller
            dashboard; granting time there is behind its basic auth.
            Declared policy lives in `flake.lib.kidTimekprPolicy`
            (`flake-modules/kid-hm.nix`), and runtime `timekpra` changes
            survive until that declaration next changes.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "biometrics-enroll";
          title = "Fingerprint and face enrolment";
          short = "`biometrics-enroll` walks through fprintd and howdy setup on the hosts that have the hardware.";
          body = ''
            Run **`biometrics-enroll`** after a fresh install on a host
            with the hardware. It handles both the fingerprint reader
            (fprintd) and the IR camera (howdy).

            Note the deliberate gap: the **lockscreen has no face unlock**
            — swaylock + howdy isn't a combination anyone has wired. The
            fingerprint sensor *does* work on the lockscreen, via
            `security.pam.services.swaylock.fprintAuth`.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "hm_win";
          title = "The native-Windows dotfiles are a separate build";
          short = "`hm_win` generates and pushes the native Windows profile — it is NOT part of `home-manager switch`.";
          body = ''
            Run **`hm_win`** from inside WSL. It builds
            `packages.x86_64-linux.windows-dotfiles` and pushes
            `profile.ps1`, `setup.ps1`, `starship.toml` and the rest to the
            Windows side.

            This is independent of `home-manager switch` — editing the
            Windows files and only running home-manager silently does
            nothing. Check your work with
            `nix build .#packages.x86_64-linux.windows-dotfiles`.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "esptool";
          title = "Re-tuning this machine's audio";
          short = "`./scripts/audio-discover.sh` prints ready-to-paste EasyEffects autoload entries for the sinks it finds.";
          body = ''
            Run **`./scripts/audio-discover.sh`** on the host. It reads
            `pw-dump` and prints autoload entries you can paste straight
            into `audio.autoloads` in the host bridge.

            Do not hand-guess the `profile` field. It is the PipeWire
            **route description** (`"Speaker"`, `"Headphones"`), not the
            ALSA card profile (`"HiFi: Speaker: sink"`) — EasyEffects keys
            its autoload filename on the former, and getting it wrong
            fails silently by falling through to the passthrough preset.
          '';
        }
        {
          section = "admin";
          admin = true;
          probe = "git";
          title = "New files are invisible to nix until you `git add` them";
          short = "Flake builds only see git-tracked files — a new module you forgot to stage is silently excluded.";
          body = ''
            Nix flake builds only see **git-tracked** files. Create a new
            `flake-modules/*.nix` and forget to `git add` it, and the
            rebuild succeeds while quietly ignoring everything you just
            wrote. This costs an hour roughly once a year.

            ```sh
            git add <file> && nix flake check
            ```

            Related: `nix fmt .` recurses into the `homelab/` submodule,
            which is *not* nixpkgs-fmt-formatted. Scope it instead:

            ```sh
            git ls-files '*.nix' | grep -v '^homelab/' | xargs nixpkgs-fmt
            ```
          '';
        }
      ];

      # ── Rendering ─────────────────────────────────────────────────
      withDefaults = t: t // {
        body = t.body or t.short;
        admin = t.admin or false;
      };
      allTips = map withDefaults tips;

      tipsJson = pkgs.writeText "discovery-tips.json" (builtins.toJSON
        (map (t: { inherit (t) title short admin; probe = t.probe or ""; }) allTips));

      # Emitted into both scripts. `wheel` is the NixOS admin group;
      # `admin` is its macOS equivalent, so the same check works on
      # pb-mb. `id -nG` needs word-boundary matching — a plain grep for
      # "wheel" would also match a group called "wheelhouse".
      adminCheck = ''
        is_admin=0
        for _g in $(id -nG 2>/dev/null || true); do
          case "$_g" in wheel | admin) is_admin=1 ;; esac
        done
      '';

      # Static header/footer of the guide. The middle (the gated tips) is
      # assembled at runtime by the script below.
      guideHeader = ''
        # 🧭 What this machine can do

        This page lists the things that are set up on this computer and are
        easy to miss.

        Scroll with the **arrow keys** or **Page Down**. Press **q** to close.

        > Type `guide` any time to see this page again${lib.optionalString hasNiri ", or press `Mod+Slash`"}.

        ${keybindDoc}
      '';

      guideFooter = ''
        ## 📖  Where to look next

        | Do this | To get |
        | --- | --- |
        | `tools` | the full terminal command guide |
        ${lib.optionalString hasNiri "| `Mod+Shift+/` | every single desktop keyboard shortcut |"}
        | `tldr <command>` | real examples for any command |
        | `<command> --help` | the official (dense) explanation |
        | `guide` | this page |

        Everything on this machine is described in a text file in `~/nixos`,
        so if you want something added — a program, a keyboard shortcut —
        it can be. Ask.
      '';

      # Emit `if command -v X; then cat <<EOF … EOF; fi` per tip, grouped
      # into sections, and drop any section whose tips all failed their
      # gate (so a machine without CAD doesn't show an empty heading, and
      # a non-admin never sees the "Running this machine" header).
      sectionScript = sec:
        let
          inSection = lib.filter (t: t.section == sec) allTips;
          emit = t:
            let
              tests =
                lib.optional (t.probe != null)
                  "command -v ${lib.escapeShellArg t.probe} >/dev/null 2>&1"
                ++ lib.optional t.admin ''[ "$is_admin" = 1 ]'';
            in
            ''
              ${lib.optionalString (tests != [ ]) "if ${lib.concatStringsSep " && " tests}; then"}
              cat >>"$sect" <<'DISCOVERY_TIP_EOF'
              ### ${t.title}

              ${t.body}
              DISCOVERY_TIP_EOF
              ${lib.optionalString (tests != [ ]) "fi"}
            '';
        in
        lib.optionalString (inSection != [ ]) ''
          : >"$sect"
          ${lib.concatMapStringsSep "\n" emit inSection}
          if [ -s "$sect" ]; then
            printf '## %s\n\n' ${lib.escapeShellArg sectionTitles.${sec}} >>"$doc"
            cat "$sect" >>"$doc"
          fi
        '';

      guide = pkgs.writeShellApplication {
        name = "guide";
        # No glow here — rendering is entirely md-view's job (see
        # flake-modules/markdown-viewer.nix). This script only assembles
        # the page; coreutils covers mktemp/cat/id.
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          ${lib.optionalString hasNiri ''
            # Launched from the app menu, the bar or a notification there is
            # no terminal attached at all, so re-run ourselves inside one.
            # Inside alacritty stdout IS a tty, so this recurses exactly
            # once.
            #
            # stdin is tested as well as stdout, and that matters: testing
            # stdout alone means `guide | head` or `guide > out.md` typed at
            # a shell pops an alacritty window instead of writing to the
            # pipe. A launcher/bar/systemd invocation has neither.
            #
            # alacritty is deliberately taken from PATH rather than pinned:
            # it comes from the same bundles this module ships in, and
            # pinning it here would drag a second copy into the closure.
            if [ ! -t 0 ] && [ ! -t 1 ] && [ -n "''${WAYLAND_DISPLAY:-}" ] \
               && command -v alacritty >/dev/null 2>&1; then
              exec alacritty --title "Help & Tips" -e "$0" "$@"
            fi
          ''}
          ${adminCheck}
          # The `.md` suffix is LOAD-BEARING, not cosmetic. glow decides
          # whether to render a file as Markdown from its extension, and
          # for an extensionless path it passes the source through
          # untouched — so the page arrives in the pager as raw `#
          # heading` / `**bold**` / table pipes. Proven by rendering the
          # same bytes twice: `md5sum` identical, `/tmp/tmp.ZZZ111.md`
          # renders, `/tmp/tmp.ZZZ111` does not.
          #
          # It only ever showed up down the notification path because
          # that's the only surface anyone had actually clicked; `tools`
          # was always fine, since terminal-help.md is a real .md file.
          doc="$(mktemp --suffix=.md)"
          sect="$(mktemp)"
          trap 'rm -f "$doc" "$sect"' EXIT

          cat >>"$doc" <<'DISCOVERY_HEAD_EOF'
          ${guideHeader}
          DISCOVERY_HEAD_EOF

          ${lib.concatMapStringsSep "\n" sectionScript sectionOrder}

          cat >>"$doc" <<'DISCOVERY_FOOT_EOF'
          ${guideFooter}
          DISCOVERY_FOOT_EOF

          if [ -t 1 ]; then
            ${lib.getExe (outer.flake.lib.mkMarkdownViewer pkgs)} "$doc"
          else
            cat "$doc"
          fi
        '';
      };

      # `tip` — the push surface. All three entry points (login service,
      # zsh greeting, manual run) share ONE stamp file, so you get at most
      # one tip per PERIOD however you arrive at it.
      #
      # The period is one hour, and the same bucket number drives both the
      # gate and the rotation — so "which tip is it right now" and "have I
      # already shown this one" cannot disagree.
      tip = pkgs.writeShellApplication {
        name = "tip";
        runtimeInputs = [ pkgs.coreutils pkgs.jq ]
          # notify-send only makes sense where there's a notification
          # daemon. On macOS / headless WSL `--notify` falls back to
          # printing rather than dragging libnotify into the closure.
          ++ lib.optional isLinux pkgs.libnotify;
        text = ''
          tips=${tipsJson}
          state="''${XDG_STATE_HOME:-$HOME/.local/state}/discovery"
          stamp="$state/last-tip"
          welcomed="$state/welcomed"
          ${adminCheck}

          mode=print
          gated=0
          case "''${1:-}" in
            --notify) mode=notify ;;
            --once) gated=1 ;;
            --notify-once) mode=notify; gated=1 ;;
            "") ;;
            *) echo "usage: tip [--once|--notify|--notify-once]  (--once = at most one per hour)" >&2; exit 2 ;;
          esac

          # Hours since the epoch. UTC-based, so a DST change can't hand
          # out the same hour twice or skip one, and it survives month and
          # year boundaries that a %j day-of-year would trip over.
          bucket=$(( $(date +%s) / 3600 ))

          # The stamp is CHECKED here but only COMMITTED once the tip has
          # actually been delivered (below). Committing up front means a
          # login-time notification that fails — no notification daemon
          # yet, a headless session — silently eats that hour's tip for
          # the shell greeting too, and nothing is seen at all.
          if [ "$gated" = 1 ]; then
            # Written as an `if`, not an `&&` chain: writeShellApplication
            # runs under `set -e`, where a top-level `a && b && exit 0`
            # whose first test fails takes down the whole script.
            if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$bucket" ]; then
              exit 0
            fi
          fi

          commit() {
            mkdir -p "$state"
            printf '%s\n' "$bucket" >"$stamp"
            : >"$welcomed"
          }

          # First run ever: introduce the guide instead of a random tip.
          # Without this the very first thing they see is a tip about a
          # tool, with no hint that a whole page of them exists.
          if [ ! -f "$welcomed" ]; then
            title="👋 There's more on this machine than you think"
            short="A pile of tools and shortcuts are set up here. Here's the tour."
          else
            # Keep only the tips this user can actually act on: the probe
            # command must exist, and admin-only tips need wheel/admin.
            mapfile -t avail < <(
              jq -r 'to_entries[] | "\(.key)\t\(.value.probe)\t\(.value.admin)"' "$tips" \
              | while IFS=$'\t' read -r idx probe adminonly; do
                  if [ "$adminonly" = true ] && [ "$is_admin" != 1 ]; then
                    continue
                  fi
                  if [ -z "$probe" ] || command -v "$probe" >/dev/null 2>&1; then
                    printf '%s\n' "$idx"
                  fi
                done
            )
            n=''${#avail[@]}
            [ "$n" -gt 0 ] || exit 0

            # The hour bucket picks the tip, so it's stable for the whole
            # hour (every surface agrees) and moves on at the top of the
            # next one.
            #
            # Multiplied by a prime rather than used directly: consecutive
            # buckets would otherwise walk `avail` in file order, handing
            # out five AI tips in a row and then six maker ones. 7919 is
            # prime, so gcd(7919, n) = 1 for any plausible n, which makes
            # bucket -> index a full-cycle permutation — every tip is shown
            # exactly once before any repeats, but consecutive hours land
            # in unrelated sections.
            #
            # The username offset keeps two people on the same machine from
            # being shown the identical tip in the identical hour.
            off=$(printf '%s' "''${USER:-nobody}" | cksum | cut -d' ' -f1)
            pick=''${avail[$(( (bucket * 7919 + off) % n ))]}
            title="$(jq -r ".[$pick].title" "$tips")"
            short="$(jq -r ".[$pick].short" "$tips")"
          fi

          if [ "$mode" = notify ] && command -v notify-send >/dev/null 2>&1; then
            # mako's default left-click is `invoke-default-action`, so the
            # action MUST be named `default` for a plain click to work.
            # notify-send prints the action name and blocks until the
            # notification is closed (-A implies --wait).
            #
            # A non-zero exit means no notification daemon answered, so the
            # tip was never seen — leave the daily stamp alone and let the
            # shell greeting deliver it instead.
            if chosen="$(notify-send \
              --app-name="Tips" \
              --icon=dialog-information \
              --expire-time=25000 \
              --action=default="Show me more" \
              "💡 $title" "$short")"; then
              commit
              if [ "$chosen" = "default" ]; then
                exec ${guide}/bin/guide
              fi
            fi
          else
            # No backticks in this format string: shellcheck flags them
            # inside single quotes (SC2016) and writeShellApplication
            # treats that as a build failure.
            printf '\n💡 %s\n   %s\n   (%s for more)\n\n' \
              "$title" "$short" \
              ${lib.escapeShellArg (if hasNiri then "press Mod+Slash, or run 'guide'," else "run 'guide',")}
            commit
          fi
        '';
      };
    in
    {
      # Wrapped in an explicit `config = { … }` rather than written at the
      # top level. The set of attributes below depends on `hasNiri`, which
      # is derived from the module argument `options` — and the module
      # system has to read this attrset's KEYS (looking for `imports` /
      # `options` / `config`) before it can finish building `options`.
      # Returning a bare set whose key set depends on `options` is an
      # infinite recursion; hiding it one level down under a fixed `config`
      # key is not.
      #
      # `lib.mkMerge`, NOT `//`. The desktop-only block below also defines
      # something under `programs.*`, and `//` is a SHALLOW update — it
      # would replace the whole `programs` attribute and silently drop the
      # zsh greeting. (It did exactly that, undetected, until the rendered
      # .zshrc was diffed.)
      config = lib.mkMerge ([
        {
          home.packages = [ guide tip ];

          # Layer 4 — one line in the first terminal opened each HOUR.
          # This is the only push surface on a headless host, which is
          # why it isn't gated on hasNiri, and it's the surface that
          # actually benefits from hourly rotation: open a new terminal
          # after the top of the hour and there's a fresh tip. Shares the
          # stamp with the login notification, so you get the tip from
          # whichever surface you reach first, never both.
          programs.zsh.initContent = lib.mkAfter ''
            if [[ -o interactive ]] && (( $+commands[tip] )); then
              tip --once || true
            fi
          '';
        }
      ]
      # Everything below needs a compositor: the launcher entry, the
      # keybind, and the login notification. `optional` + `mkMerge` rather
      # than `mkIf` because on a headless config `programs.niri` is not a
      # DECLARED option at all, and a `mkIf false` definition still trips
      # the module system's unknown-option check.
      ++ lib.optional hasNiri {
        # Shows up in the fuzzel launcher (Super+Space) as "Help & Tips".
        # Deliberately NOT in kid-launcher.nix's hidden list.
        xdg.desktopEntries.help-and-tips = {
          name = "Help & Tips";
          genericName = "What this machine can do";
          comment = "Keyboard shortcuts and the tools installed here";
          exec = "guide";
          icon = "dialog-information";
          terminal = false;
          categories = [ "Utility" "Documentation" ];
        };

        programs.niri.settings.binds."Mod+Slash" = {
          hotkey-overlay.title = "Show the help & tips guide";
          action.spawn = "guide";
        };

        # Layer 2 — the push. Fires once per graphical login and NOT on a
        # timer: the content rotates hourly, but a notification every hour
        # on a machine you sit in front of all day is a tax, not a feature
        # (decided 2026-08-04). The hourly surface is the shell greeting;
        # this is the once-you-sit-down one. The `--once` gate makes it a
        # no-op if a terminal already delivered this hour's tip.
        systemd.user.services.discovery-tip = {
          Unit = {
            Description = "Tip about what this machine can do (at login)";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            Type = "oneshot";
            # Give mako time to claim the notification bus; a notify-send
            # that arrives first is silently dropped.
            ExecStartPre = "${pkgs.coreutils}/bin/sleep 25";
            ExecStart = "${tip}/bin/tip --notify-once";
            # notify-send blocks until the notification is dismissed or
            # expires (25s), so the unit must be allowed to sit there.
            TimeoutStartSec = "180s";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      });
    };
}
