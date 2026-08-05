# Shared Markdown viewer for this repo's human-facing docs.
#
# `flake.lib.mkMarkdownViewer pkgs` returns a package whose
# `bin/md-view <file.md>` renders Markdown with glow, pinned so that it
# renders the SAME WAY no matter who runs it or how the process was
# started. Two commands consume it — `tools` (flake-modules/zsh.nix) and
# `guide` (flake-modules/discovery.nix); sharing one invocation keeps
# them from drifting apart.
#
# The bug that produced this module (2026-08-04): the notification
# action opened a terminal showing the guide as raw Markdown source —
# `# heading`, `**bold**`, literal table pipes. The cause was not the
# terminal, not the pager and not the style: `guide` wrote its assembled
# page to `mktemp`, and **glow decides whether to render a file as
# Markdown from its extension**. An extensionless path is passed through
# untouched. Proven by rendering the same bytes under two names —
# `md5sum` identical, `/tmp/x.md` rendered, `/tmp/x` did not. `tools`
# was never affected, because terminal-help.md is a real `.md` file.
#
# So the one non-negotiable rule for callers is: **the file you hand
# `md-view` must end in `.md`.** `guide` uses `mktemp --suffix=.md`.
#
# The flags below are not the fix; they make the result independent of
# the ambient environment, which is worth having once you have been
# burned once:
#
#   --style dark
#       `auto` asks the terminal for its background colour (OSC 11) and
#       picks light/dark from the answer. That round trip needs a
#       terminal that answers — true in alacritty, not true under
#       systemd or a bare pty, where it falls back to a style that
#       leaves the Markdown source visible. Every terminal in this
#       config is dark, so state it and never ask.
#
#   --width (measured, capped at 100)
#       glow falls back to 80 columns when it can't measure the
#       terminal. Several tables in these docs are wider than that and
#       reflowing them into 80 columns mangles them.
#
#   --config /dev/null
#       Defence in depth, NOT the bug — measured: an explicit flag does
#       beat a value in ~/.config/glow/glow.yml. But a stray `glow
#       config` run (there was one on this machine, leaving
#       `style: "auto"`, `width: 80`) can still change any setting we
#       don't pass explicitly, and these docs should render the same for
#       every account. An empty config file makes that guaranteed.
#
#   PAGER + LESS
#       `--pager` execs `$PAGER` directly (not through a shell), and the
#       session's PAGER is a bare `less`. Flags therefore go in `$LESS`,
#       which less honours however it is invoked. less is referenced by
#       store path so `--mouse` (less >= 551) is guaranteed — scrolling
#       with the wheel matters for the audience these docs are written
#       for — and `--RAW-CONTROL-CHARS` keeps the ANSI intact even if
#       $PAGER is ever pointed at an older less.
#
# Retire when: `tools` and `guide` are both gone, or glow learns to
#   sniff Markdown by content instead of by filename (at which point the
#   .md-suffix rule stops being load-bearing, though pinning the style
#   and pager is still worth keeping).
{ ... }:
let
  # A glamour style, authored here rather than picked from glow's
  # built-ins, for one reason: EVERY built-in style that has colours
  # renders H2-H6 with their literal `#` markers still attached
  # ("## Desktop tricks", "### Apps & tools"). Measured across
  # dark/light/dracula/tokyo-night — only `pink` replaces them, and its
  # palette doesn't belong here. On a page written for people who don't
  # know what Markdown is, leftover `##` reads as broken output.
  #
  # Colours are this desktop's palette (the Nord-ish set used by waybar,
  # fuzzel, mako and alacritty), so the guide looks like it belongs to
  # the machine rather than to glow.
  #
  # Schema note: keys are snake_case and a style file is used WHOLE —
  # glamour does not merge it over a built-in, so every element that
  # should be styled has to appear here. Missing elements silently
  # render unstyled, which is why this is a complete document rather
  # than a heading patch.
  fg = "#e5e9f0";
  dim = "#7b88a1";
  cyan = "#88c0d0";
  green = "#a3be8c";
  purple = "#b48ead";
  yellow = "#ebcb8b";
  blue = "#5e81ac";
  surface = "#3b4252";

  style = {
    document = {
      block_prefix = "\n";
      block_suffix = "\n";
      color = fg;
      margin = 2;
    };
    block_quote = {
      color = yellow;
      indent = 1;
      indent_token = "│ ";
    };
    paragraph = { };
    list.level_indent = 2;

    # The point of the whole file: headings carry no `#`. They're told
    # apart by colour and by a left bar, which survives being read by
    # someone who has never seen Markdown.
    heading = {
      block_suffix = "\n";
      color = cyan;
      bold = true;
    };
    h1 = {
      prefix = " ";
      suffix = " ";
      color = fg;
      background_color = blue;
      bold = true;
    };
    h2 = {
      prefix = "▌ ";
      color = cyan;
      bold = true;
    };
    h3 = {
      prefix = "";
      color = green;
      bold = true;
    };
    h4 = {
      prefix = "";
      color = purple;
      bold = true;
    };
    h5 = {
      prefix = "";
      color = purple;
      bold = false;
    };
    h6 = {
      prefix = "";
      color = dim;
      bold = false;
    };

    text = { };
    strikethrough.crossed_out = true;
    emph.italic = true;
    strong.bold = true;
    hr = {
      color = dim;
      format = "\n────────\n";
    };
    item.block_prefix = "• ";
    enumeration.block_prefix = ". ";
    task = {
      ticked = "[✓] ";
      unticked = "[ ] ";
    };
    link = {
      color = cyan;
      underline = true;
    };
    link_text = {
      color = green;
      bold = true;
    };
    image = {
      color = purple;
      underline = true;
    };
    image_text = {
      color = dim;
      format = "Image: {{.text}} →";
    };
    code = {
      prefix = " ";
      suffix = " ";
      color = yellow;
      background_color = surface;
    };
    code_block = {
      color = fg;
      margin = 2;
      chroma = {
        text.color = fg;
        error.color = "#bf616a";
        comment.color = dim;
        keyword.color = purple;
        keyword_reserved.color = purple;
        keyword_namespace.color = purple;
        keyword_type.color = yellow;
        operator.color = cyan;
        punctuation.color = fg;
        name.color = fg;
        name_builtin.color = cyan;
        name_function.color = cyan;
        name_class = {
          color = yellow;
          bold = true;
        };
        name_tag.color = cyan;
        name_attribute.color = green;
        name_decorator.color = yellow;
        literal_number.color = purple;
        literal_string.color = green;
        literal_string_escape.color = yellow;
        generic_emph.italic = true;
        generic_strong.bold = true;
        generic_deleted.color = "#bf616a";
        generic_inserted.color = green;
        generic_subheading.color = dim;
        background.background_color = "#2e3440";
      };
    };
    table = { };
    definition_list = { };
    definition_term = { };
    definition_description.block_prefix = "\n🠶 ";
    html_block = { };
    html_span = { };
  };
in
{
  # Published so the native-Windows side can serialise the SAME style
  # (flake-modules/windows/windows.nix ships it as an artifact and
  # profile.ps1's `md-view` points glow at it). One definition, so the
  # guide looks identical on both platforms.
  flake.lib.markdownStyle = style;

  flake.lib.mkMarkdownViewer = pkgs:
    let
      styleFile = pkgs.writeText "md-view-style.json" (builtins.toJSON style);
    in
    pkgs.writeShellApplication {
      name = "md-view";
      runtimeInputs = [ pkgs.coreutils pkgs.glow pkgs.gnugrep pkgs.gnused pkgs.mermaid-ascii ];
      # The mermaid emitter printf's literal Markdown fences, and
      # shellcheck reads a backtick inside single quotes as an attempted
      # command substitution (SC2016). They are fences. Same false
      # positive as flake-modules/displays.nix's embedded Python.
      excludeShellChecks = [ "SC2016" ];
      text = ''
        # ── Mermaid ───────────────────────────────────────────────────
        # glow renders a ```mermaid block as a syntax-highlighted code
        # block, i.e. as source. mermaid-ascii turns the common diagram
        # types into text, which is what a pager can actually show
        # (alacritty implements no image protocol, so the PNG/SVG that
        # mermaid-cli would emit is not displayable — and mermaid-cli is
        # a 2.1 GiB Chromium closure besides).
        #
        # It is applied CONSERVATIVELY, because mermaid-ascii 1.4.0
        # handles only a subset and fails in two different ways:
        #
        #   * Unsupported diagram TYPES (classDiagram, stateDiagram,
        #     erDiagram, pie, gantt, mindmap, …) exit non-zero. Easy —
        #     we keep the source.
        #   * Unsupported node SHAPES inside a flowchart exit ZERO and
        #     produce a WRONG diagram: `B{AC power}` renders as a box
        #     labelled "B{AC power}" *plus* a phantom node "B". Only
        #     `id[square]` is understood; `(round)`, `((circle))`,
        #     `{diamond}`, `>flag]`, `[[sub]]`, `[(db)]` are not.
        #
        # A silently wrong diagram is worse than none — decision
        # diamonds are everywhere in real READMEs — so blocks using
        # those shapes are left as source. Sequence diagrams and
        # square-node flowcharts (including edge labels and subgraphs)
        # render correctly and are the case this exists for.
        #
        # Net effect: never worse than before, better where it is safe.
        # Normalise the flowchart dialect down to the subset
        # mermaid-ascii understands, so a diagram is DRAWN rather than
        # dumped as source. Every rule is lossy in *styling* only —
        # topology, labels and edge labels are preserved exactly:
        #
        #   node shapes  (round) ((circle)) ([stadium]) [[sub]] [(db)]
        #                {diamond} {{hex}} >flag] [/par/] [\tra/]  ->  [label]
        #   edge styles  ==>  -.->  ---  --o  --x                  ->  -->
        #                -- txt -->  == txt ==>  -. txt .->        ->  -->|txt|
        #
        # A decision node therefore renders as a box rather than a
        # rhombus. That is a real loss, but a small one next to the
        # alternative — mermaid-ascii parses `B{Ready?}` as a node whose
        # *id* is the whole string and invents a second node `B`, i.e. a
        # confidently wrong picture. Reviewed the alternatives before
        # settling on this (see this module's header).
        #
        # `sed -E`; the rules are ordered longest-delimiter-first so
        # `((circle))` is not eaten by the `(round)` rule.
        # Split in two passes on purpose — see mermaid_labels_simple
        # below. These first rules are anchored on a `[` immediately
        # after the node id, so they cannot collide with anything inside
        # an ordinary `[label]`, and running them first turns compound
        # shapes into plain labels *before* the label-safety check looks
        # at them (otherwise `D[(db)]` reads as a label containing a
        # paren and disables normalisation for the whole block).
        mermaid_norm_bracket='
          s/([A-Za-z0-9_])\[\[([^]]*)\]\]/\1[\2]/g
          s/([A-Za-z0-9_])\[\(([^]]*)\)\]/\1[\2]/g
          s|([A-Za-z0-9_])\[[/\\]([^]]*)[/\\]\]|\1[\2]|g
        '

        # These can match inside a label (`A[call func(x)]`), so they run
        # only when every label is known to be free of the characters
        # they key on. Ordered longest-delimiter-first so `((circle))` is
        # not eaten by the `(round)` rule.
        mermaid_norm_rest='
          s/([A-Za-z0-9_])\(\(\(([^)]*)\)\)\)/\1[\2]/g
          s/([A-Za-z0-9_])\(\(([^)]*)\)\)/\1[\2]/g
          s/([A-Za-z0-9_])\(\[([^]]*)\]\)/\1[\2]/g
          s/([A-Za-z0-9_])\(([^)]*)\)/\1[\2]/g
          s/([A-Za-z0-9_])\{\{([^}]*)\}\}/\1[\2]/g
          s/([A-Za-z0-9_])\{([^}]*)\}/\1[\2]/g
          s/([A-Za-z0-9_])>([^]]*)\]/\1[\2]/g
          s/--[[:space:]]+([^->|]+[^->|[:space:]])[[:space:]]*-->/-->|\1|/g
          s/==[[:space:]]+([^=>|]+[^=>|[:space:]])[[:space:]]*==>/-->|\1|/g
          s/-\.[[:space:]]+([^.>|]+[^.>|[:space:]])[[:space:]]*\.->/-->|\1|/g
          s/==>/-->/g
          s/-\.->/-->/g
          s/(\]|[A-Za-z0-9_])[[:space:]]*--[ox][[:space:]]*/\1 --> /g
          s/(\]|[A-Za-z0-9_])[[:space:]]*---[[:space:]]*([A-Za-z0-9_])/\1 --> \2/g
        '

        # The rules above are text substitutions with no notion of what
        # is a node and what is a label, so a label that itself contains
        # a bracket, brace, paren or arrow can be rewritten by mistake:
        # `C[a{b}]` would become `C[a[b]]`, and `A[x ==> y]` would have
        # its text altered. Both are exactly the "confidently wrong"
        # outcome this whole design exists to avoid.
        #
        # So: if ANY label looks like that, don't normalise this block at
        # all. That only ever costs an optimisation — a block needing no
        # normalisation still renders, and one that did falls through to
        # being shown as source. It can never produce a wrong diagram.
        mermaid_labels_simple() {
          local rest="$1" whole inner
          while [[ $rest =~ \[([^]]*)\] ]]; do
            # Copy the captures out IMMEDIATELY: the `=~` below is itself
            # a match, and a failed match resets BASH_REMATCH to an empty
            # array, so referring to BASH_REMATCH[0] afterwards trips
            # `set -o nounset`.
            whole="''${BASH_REMATCH[0]}"
            inner="''${BASH_REMATCH[1]}"
            if [[ $inner =~ [\{\(\[]|--|==|\> ]]; then
              return 1
            fi
            rest="''${rest#*"$whole"}"
          done
          return 0
        }

        mermaid_emit() {
          local src="$1" head="" line art body
          local shapes='[A-Za-z0-9_](\[\[|\[\(|\[/|\[\\|[({>])'

          # Strip YAML front matter (```mermaid blocks may open with a
          # `---` / `title:` / `---` preamble). mermaid-ascii aborts with
          # "missing graph definition" on it.
          body=""
          local in_fm=0 seen=0
          while IFS= read -r line; do
            if [ "$seen" -eq 0 ] && [ -n "''${line//[[:space:]]/}" ]; then
              seen=1
              if [ "''${line//[[:space:]]/}" = "---" ]; then
                in_fm=1
                continue
              fi
            fi
            if [ "$in_fm" -eq 1 ]; then
              [ "''${line//[[:space:]]/}" = "---" ] && in_fm=0
              continue
            fi
            body+="$line"$'\n'
          done <<<"$src"
          [ -n "$body" ] || body="$src"

          # First meaningful line decides the diagram type.
          while IFS= read -r line; do
            line="''${line#"''${line%%[![:space:]]*}"}"
            [ -z "$line" ] && continue
            case "$line" in '%%'*) continue ;; esac
            head="$line"
            break
          done <<<"$body"

          # Flowcharts get normalised; sequence diagrams are already
          # handled natively and the rules above are flowchart-specific,
          # so they are left alone.
          if [[ $head == graph* || $head == flowchart* ]]; then
            body="$(sed -E "$mermaid_norm_bracket" <<<"$body")"
            if mermaid_labels_simple "$body"; then
              body="$(sed -E "$mermaid_norm_rest" <<<"$body")"
            fi
          fi

          # Backstop: anything the normaliser could not reach is still a
          # construct mermaid-ascii would mis-draw, so keep the source.
          if [[ $head == graph* || $head == flowchart* ]] \
             && [[ $body =~ $shapes ]]; then
            printf '```mermaid\n%s```\n' "$src"
            return
          fi

          if art="$(mermaid-ascii -f /dev/stdin <<<"$body" 2>/dev/null)" \
             && [ -n "$art" ]; then
            # Fenced, so glow shows it verbatim instead of reflowing the
            # box-drawing characters into prose. The explicit newline
            # matters: mermaid-ascii does not terminate its last line,
            # so the closing fence would otherwise land on it.
            printf '```\n%s\n```\n' "$art"
          else
            printf '```mermaid\n%s```\n' "$src"
          fi
        }

        # Rewrite ```mermaid blocks on stdin, pass everything else
        # through. Pure bash: no grep/sed, so md-view's closure stays as
        # small as the rendering allows.
        mermaid_filter() {
          local line block="" in_block=0
          while IFS= read -r line || [ -n "$line" ]; do
            if [ "$in_block" -eq 0 ]; then
              case "$line" in
                '```mermaid' | '```mermaid '* | '~~~mermaid' | '~~~mermaid '*)
                  in_block=1
                  block=""
                  ;;
                *) printf '%s\n' "$line" ;;
              esac
              continue
            fi
            case "$line" in
              '```'* | '~~~'*)
                in_block=0
                mermaid_emit "$block"
                ;;
              *) block+="$line"$'\n' ;;
            esac
          done
          # Unterminated block: emit what we swallowed, verbatim.
          if [ "$in_block" -eq 1 ]; then
            printf '```mermaid\n%s' "$block"
          fi
        }

        if [ "$#" -gt 1 ]; then
          echo "usage: md-view [file]   (no file, or '-', reads stdin)" >&2
          exit 2
        fi

        src="''${1:--}"

        if [ "$src" = "-" ] && [ -t 0 ]; then
          echo "usage: md-view [file]   (no file, or '-', reads stdin)" >&2
          exit 2
        fi

        if [ "$src" != "-" ] && [ ! -r "$src" ]; then
          echo "md-view: cannot read '$src'" >&2
          exit 1
        fi

        # Piped or redirected: hand the source over unchanged, so
        # `tools > notes.md`, `guide | grep` and `md-view x.md | head`
        # all keep working.
        if [ ! -t 1 ]; then
          if [ "$src" = "-" ]; then cat; else cat "$src"; fi
          exit 0
        fi

        # Normalise the input to a path ending in `.md`. glow decides
        # whether to render Markdown from the FILE EXTENSION and passes
        # anything else through as plain text (see this module's header),
        # so stdin, a `.markdown`, or a plain `README` would otherwise
        # render as source. Copying is cheap next to what glow then does.
        #
        # Mermaid blocks are rewritten in the same pass, which is why a
        # `.md` input can still need a temp copy.
        tmp=""
        case "$src" in
          *.md) doc="$src" ;;
          *)
            tmp="$(mktemp --suffix=.md)"
            doc="$tmp"
            if [ "$src" = "-" ]; then cat >"$doc"; else cat "$src" >"$doc"; fi
            ;;
        esac
        # shellcheck disable=SC2064  # expand the paths now, not at exit
        trap "rm -f '$tmp'" EXIT

        if grep -q '^\(```\|~~~\)mermaid' "$doc" 2>/dev/null; then
          rendered="$(mktemp --suffix=.md)"
          # shellcheck disable=SC2064
          trap "rm -f '$tmp' '$rendered'" EXIT
          if mermaid_filter <"$doc" >"$rendered"; then
            doc="$rendered"
          fi
        fi

        # Reattach stdin to the terminal before rendering. Three things
        # depend on it:
        #   * glow reads the document from STDIN in preference to its
        #     file argument whenever stdin isn't a terminal. On the
        #     `md-view < notes.md` / `… | md-view` paths we have already
        #     drained stdin into $doc, so glow would be handed an empty
        #     document and print nothing at all.
        #   * `stty size` below measures via stdin, and reports nothing
        #     when stdin is a redirected file.
        #   * the pager needs a live terminal to take keystrokes.
        if [ -r /dev/tty ]; then
          exec </dev/tty
        fi

        width=100
        cols=$(stty size 2>/dev/null | cut -d' ' -f2 || true)
        case "$cols" in
          "" | *[!0-9]*) cols=0 ;;
        esac
        if [ "$cols" -ge 40 ] && [ "$cols" -lt "$width" ]; then
          width="$cols"
        fi

        CLICOLOR_FORCE=1 \
        PAGER=${pkgs.lib.getExe pkgs.less} \
        LESS="--RAW-CONTROL-CHARS --mouse --quit-if-one-screen" \
          glow --config /dev/null --style ${styleFile} --width "$width" --pager "$doc"
      '';
    };
}
