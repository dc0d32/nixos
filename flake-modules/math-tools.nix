# Maths tools for the kids (home-manager): one Python environment, a
# purpose-built VS Code profile, a helper library, a calculator and a plotter.
#
# Why it exists: the kids already know Python, so the symbolic side of their
# maths (derivatives, integrals, limits, linear algebra) is SymPy in a Jupyter
# notebook rather than a new language such as Maxima's. SymPy returns only
# answers, so packages/mathkit adds what a teacher would: a friendly answer
# checker, step-by-step working (derivatives, integrals, equations, fractions)
# and interactive pictures (tangent lines, Riemann sums, the unit circle).
#
# One environment feeds everything: `math-python` (CLI), the "Maths" Jupyter
# kernel, the VS Code `Maths` profile's interpreter, and `math-lab`
# (JupyterLab, the fallback UI). The environment MUST contain `notebook`: with
# only `ipykernel` VS Code refuses to start the kernel and then suggests
# `uv venv`, which cannot work on a Nix store Python.
#
# VS Code profile `Maths` (opened by the "Maths Studio" launcher via
# `code --profile Maths`): Microsoft's Python / Pylance / Jupyter extensions
# pinned from nixpkgs, large type, AI features switched off (the kids may use
# AI for programming but not for maths, so this is per-profile and a nudge
# rather than a lock - a local VS Code cannot enforce it). Declaring any
# non-default profile makes Home Manager require an immutable extensions
# directory, so extensions the kids install by hand no longer persist; add what
# they want here instead.
#
# Starter notebooks from packages/mathkit/notebooks are copied into ~/math on
# activation, only when missing, so the kids' edits are never overwritten.
#
# Qalculate! covers everyday calculation with units and exact fractions; KmPlot
# plots functions and shows derivatives and integrals without any code.
#
# `python3` in the base bundle stays untouched; the separate `math-python`
# command keeps the two environments from colliding in the profile.
#
# Carried by the kid bundle only. Retire when: the kids stop using them, OR a
# step-by-step tool worth adopting replaces the notebooks.
{ ... }:
{
  flake.modules.homeManager.math-tools = { lib, pkgs, ... }:
    let
      mathkit = pkgs.python3Packages.buildPythonPackage {
        pname = "mathkit";
        version = "0.1.0";
        pyproject = true;
        src = ../packages/mathkit;
        build-system = [ pkgs.python3Packages.setuptools ];
        dependencies = with pkgs.python3Packages; [ sympy numpy matplotlib ];
        pythonImportsCheck = [ "mathkit" ];
        doCheck = false;
      };

      pyEnv = pkgs.python3.withPackages (ps: [
        ps.sympy
        ps.numpy
        ps.scipy
        ps.matplotlib
        ps.ipython
        ps.ipykernel
        ps.ipywidgets
        ps.notebook
        ps.jupyterlab
        mathkit
      ]);
      py = "${pyEnv}/bin/python";

      kernelName = "mathpython";
      kernelSpec = builtins.toJSON {
        argv = [ py "-m" "ipykernel_launcher" "-f" "{connection_file}" ];
        display_name = "Maths (Python + SymPy)";
        language = "python";
      };

      mathPython = pkgs.writeShellScriptBin "math-python" ''
        exec ${py} "$@"
      '';
      mathLab = pkgs.writeShellScriptBin "math-lab" ''
        dir="$HOME/math"
        mkdir -p "$dir"
        exec ${pyEnv}/bin/jupyter-lab --notebook-dir="$dir" "$@"
      '';
      mathStudio = pkgs.writeShellScriptBin "math-studio" ''
        dir="$HOME/math"
        mkdir -p "$dir"
        exec ${pkgs.vscode}/bin/code --profile Maths "$dir" "$dir/00-start-here.ipynb" "$@"
      '';
      mathStudioItem = pkgs.makeDesktopItem {
        name = "math-studio";
        desktopName = "Maths Studio";
        comment = "VS Code set up for maths: Python, SymPy and notebooks";
        categories = [ "Education" ];
        exec = "${mathStudio}/bin/math-studio";
      };
      mathLabItem = pkgs.makeDesktopItem {
        name = "math-lab";
        desktopName = "Maths Notebook (JupyterLab)";
        comment = "JupyterLab with SymPy, the browser-style notebook";
        categories = [ "Education" ];
        exec = "${pkgs.alacritty}/bin/alacritty -e ${mathLab}/bin/math-lab";
      };

      notebooks = ../packages/mathkit/notebooks;
    in
    {
      home.packages = [
        mathPython
        mathLab
        mathStudio
        mathStudioItem
        mathLabItem
        pkgs.qalculate-gtk
        pkgs.kdePackages.kmplot
      ];

      xdg.dataFile."jupyter/kernels/${kernelName}/kernel.json".text = kernelSpec;

      home.activation.seedMathNotebooks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        mkdir -p "$HOME/math"
        for nb in ${notebooks}/*.ipynb; do
          dest="$HOME/math/$(basename "$nb")"
          [ -e "$dest" ] || install -m 0644 "$nb" "$dest"
        done
      '';

      programs.vscode.mutableExtensionsDir = lib.mkForce false;
      programs.vscode.profiles.Maths = {
        extensions = with pkgs.vscode-extensions; [
          ms-python.python
          ms-python.vscode-pylance
          ms-python.debugpy
          ms-toolsai.jupyter
          ms-toolsai.jupyter-renderers
          ms-toolsai.vscode-jupyter-cell-tags
          ms-toolsai.vscode-jupyter-slideshow
          ms-toolsai.jupyter-keymap
        ];
        userSettings = {
          "python.defaultInterpreterPath" = py;
          "python.terminal.activateEnvironment" = false;
          "python.analysis.typeCheckingMode" = "off";
          "jupyter.widgetScriptSources" = [ "jsdelivr.com" "unpkg.com" ];
          "jupyter.askForKernelRestart" = false;
          "chat.disableAIFeatures" = true;
          "editor.inlineSuggest.enabled" = false;
          "github.copilot.enable" = { "*" = false; };
          "telemetry.telemetryLevel" = "off";
          "workbench.startupEditor" = "none";
          "security.workspace.trust.enabled" = false;
          "editor.fontSize" = 16;
          "editor.minimap.enabled" = false;
          "files.autoSave" = "afterDelay";
          "window.zoomLevel" = 0.5;
        };
      };
    };
}
