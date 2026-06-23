# 🖥️  Terminal Help

Welcome! A terminal lets you tell the computer what to do by typing a
command and pressing **Enter**. This page lists the handy commands set
up on this machine. Most commands accept `--help` for more, and
`tldr <command>` shows quick real-world examples.

> Type `tools` any time to see this page again.

## 📂  Moving around folders

| Command | What it does |
| --- | --- |
| `pwd` | Show which folder you are in |
| `ls`  ·  `eza -la` | List files here (`eza -la` shows details + icons) |
| `cd folder` | Go into a folder (`cd ..` goes up, `cd` alone goes home) |
| `z name` | Jump back to a folder you visited before (smart `cd`) |
| `mkdir name` | Make a new folder |
| `cp` · `mv` · `rm` | Copy · move/rename · delete files |

## 👀  Looking at files

| Command | What it does |
| --- | --- |
| `bat file` | Show a file with colours and line numbers |
| `glow file.md` | Read a Markdown document, nicely formatted |
| `less file` | Scroll through a long file (press **q** to quit) |

## 🔎  Finding things

| Command | What it does |
| --- | --- |
| `fd name` | Find files by name |
| `rg word` | Search *inside* files for some text |
| `fzf` | Fuzzy-pick anything (see shortcuts below) |
| `tldr cmd` | Quick examples for a command, e.g. `tldr tar` |

## ⌨️  Keyboard shortcuts

| Keys | Action |
| --- | --- |
| **Home** / **Ctrl-A** | Jump to the start of the line |
| **End** / **Ctrl-E** | Jump to the end of the line |
| **Ctrl-←** / **Ctrl-→** | Move one word left / right |
| **Ctrl-R** | Search commands you typed before (atuin) |
| **Tab** | Auto-complete (press twice to see the choices) |
| **Ctrl-C** | Stop the command that is running |
| **Ctrl-L** | Clear the screen |
| **Ctrl-D** | Sign out / close the shell |

`direnv` quietly loads the right tools and settings when you `cd` into a
project folder that has a `.envrc`. The prompt (starship) shows your
folder, git branch, and more.

## ✍️  Editing text

| Command | What it does |
| --- | --- |
| `vim file`  (or `nvim`) | Edit a text file in the terminal (`:q` to quit) |
| `code file` | Open in VS Code *(desktops only)* |

## 🪟  Keep things running — tmux

| Command | What it does |
| --- | --- |
| `tmux` | Start a session that survives disconnects |
| `tmux a` | Re-attach to your last session |

Inside tmux press **Ctrl-B** then `c` for a new window, or `d` to detach.

## 🌿  Git & GitHub

| Command | What it does |
| --- | --- |
| `git st` · `git co` · `git ci` | status · checkout · commit (aliases) |
| `git lg` | Pretty commit graph |
| `git diff` | Colourful side-by-side diff (delta) |
| `git dft` | Structural, syntax-aware diff (difftastic) |
| `lazygit`  (or `lg`) | Visual, menu-driven git |
| `gh` | GitHub from the terminal: `gh pr create`, `gh repo clone` |
| `git lfs` | Track big files (models, datasets) |

## 🤖  AI helpers

| Command | What it does |
| --- | --- |
| `opencode` | AI coding assistant in the terminal |
| `gh copilot suggest` | Ask Copilot for a shell command |
| `gh copilot explain` | Ask Copilot to explain a command |

## 🧪  Data & number crunching

| Command | What it does |
| --- | --- |
| `duckdb` | Run SQL on CSV / JSON / Parquet files |
| `vd file.csv` | Explore a table / spreadsheet interactively |
| `mlr` · `qsv` | Slice and summarise CSV / TSV data |
| `jq` · `gron` · `jless` | Read and search JSON |
| `dasel` | Convert between JSON / YAML / TOML / CSV |
| `lnav file.log` | Explore log files (even with SQL) |
| `numbat` | A calculator that understands units |

## 🐍  Building & coding

| Command | What it does |
| --- | --- |
| `uv` | Fast Python: `uv venv`, `uv pip install`, `uv run app.py` |
| `python3` · `node` | Run Python / JavaScript |
| `gcc` · `make` · `cmake` | Compile C / C++ projects |
| `jq` · `yq` | Process JSON / YAML on the command line |
| `curl` · `wget` · `rsync` | Download / copy files over the network |
| `dig` · `nmap` · `iperf3` | DNS lookup / port scan / network speed test |
| `tar` · `zip` · `unzip` · `zstd` | Pack and unpack archives |

## 🔌  Hardware hacking *(where enabled)*

| Command | What it does |
| --- | --- |
| `esptool` | Flash ESP32 / ESP8266 boards |
| `dfu-util` | Flash STM32 and other DFU devices |
| `flashrom` | Read / write SPI flash chips |
| `picocom` · `screen` | Talk to a device over a serial port |
| `lsusb` | List connected USB devices |

## 📐  Design *(where installed)*

| Command | What it does |
| --- | --- |
| `freecad` | 3D CAD modelling |
| `kicad` | Circuit-board (PCB) design |

## ☁️  Azure *(work laptops only)*

| Command | What it does |
| --- | --- |
| `az login` | Sign in to Azure; `az synapse -h` for Synapse |
| `az account get-access-token --resource https://database.windows.net/` | Get an AAD token |
| `azcopy copy SRC DST` | Copy to / from Blob storage or Data Lake |
| `sqlcmd -S host -G -Q "SELECT 1"` | Query Azure SQL / Synapse |

## 🩺  System & help

| Command | What it does |
| --- | --- |
| `btop`  (or `htop`) | Live view of CPU / memory / processes |
| `tldr cmd` | Quick examples for any command |
| `man cmd` | Full manual for a command |
| `tools` | Show this page again |

---
*Stuck? Add `--help` to a command, or run `tldr <command>`.*
