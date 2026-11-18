#!/usr/bin/env bash
#
# Installer for cl.
#
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
#
# Usage:
#   ./install.sh                     copy the program into ~/.local/bin
#   ./install.sh --link              link it from this checkout instead
#   ./install.sh --prefix /usr/local install into /usr/local/bin (needs sudo)
#   ./install.sh --uninstall         remove the command and its completions
#   curl -fsSL https://raw.githubusercontent.com/dutykh/cl/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/dutykh/cl/main"
PREFIX="${PREFIX:-$HOME/.local}"
UNINSTALL=0
NO_COMPLETION=0
LINK=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die()  { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOS'
Installer for cl.

  ./install.sh                     copy the program into ~/.local/bin
  ./install.sh --link              link it from this checkout instead, so that
                                   a "git pull" of the checkout updates it
  ./install.sh --prefix /usr/local install into /usr/local/bin (needs sudo)
  ./install.sh --uninstall         remove the command and its completions
  ./install.sh --no-completion     skip the bash and zsh completions
  curl -fsSL https://raw.githubusercontent.com/dutykh/cl/main/install.sh | bash
EOS
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || die "--prefix needs a folder, for example: --prefix /usr/local"
            PREFIX="$2"; shift 2 ;;
        --link)           LINK=1; shift ;;
        --uninstall)      UNINSTALL=1; shift ;;
        --no-completion)  NO_COMPLETION=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

BIN_DIR="$PREFIX/bin"
COMP_DIR="$PREFIX/share/bash-completion/completions"
ZSH_DIR="$PREFIX/share/zsh/site-functions"
TARGET="$BIN_DIR/cl"
USER_COMP="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"

# A checkout is used only when this script runs from a file inside it. Piped
# into bash, the script has no file, and the current folder must not be
# mistaken for a checkout: the program is downloaded instead.
SOURCE_DIR=""
script="${BASH_SOURCE[0]:-}"
if [ -n "$script" ] && [ -f "$script" ]; then
    SOURCE_DIR=$(cd "$(dirname "$script")" && pwd)
fi

if [ "$UNINSTALL" -eq 1 ]; then
    removed=0
    if [ -f "$TARGET" ] || [ -L "$TARGET" ]; then
        rm -f "$TARGET" && say "removed $TARGET" && removed=1
    fi
    for candidate in "$COMP_DIR/cl" "$ZSH_DIR/_cl"; do
        if [ -f "$candidate" ]; then rm -f "$candidate" && say "removed $candidate"; fi
    done
    # The completion in the user's own folder serves whichever cl is on the
    # PATH: it goes only when none is left.
    if [ "$removed" -eq 1 ] && [ -f "$USER_COMP/cl" ] && ! command -v cl >/dev/null 2>&1; then
        rm -f "$USER_COMP/cl" && say "removed $USER_COMP/cl"
    fi
    [ "$removed" -eq 1 ] || warn "no cl found in $BIN_DIR"
    say ""
    say "A line 'eval \"\$(cl --shell-init bash)\"' in ~/.bashrc, if you added one, stays there."
    exit 0
fi

mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"

if [ "$LINK" -eq 1 ]; then
    [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/cl" ] ||
        die "--link works from a checkout of the repository: git clone https://github.com/dutykh/cl"
    ln -sfn "$SOURCE_DIR/cl" "$TARGET"
    say "linked $TARGET to $SOURCE_DIR/cl"
elif [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/cl" ]; then
    # The new file takes the place of the old one in one step, so that a cl
    # at work never reads a half-written program.
    tmp="$TARGET.tmp.$$"
    cp "$SOURCE_DIR/cl" "$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$TARGET"
    say "installed $TARGET from this checkout"
else
    say "downloading cl from $REPO_RAW"
    tmp="$TARGET.tmp.$$"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REPO_RAW/cl" -o "$tmp" || { rm -f "$tmp"; die "download failed"; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$REPO_RAW/cl" -O "$tmp" || { rm -f "$tmp"; die "download failed"; }
    else
        die "curl or wget is needed to download the program"
    fi
    if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! grep -q '^CL_VERSION=' "$tmp"; then
        rm -f "$tmp"
        die "the downloaded file does not look like cl"
    fi
    chmod 0755 "$tmp"
    mv -f "$tmp" "$TARGET"
    say "installed $TARGET"
fi

if [ "$NO_COMPLETION" -eq 0 ]; then
    # Always mkdir the full completion path: "$PREFIX/share" being writable
    # does not mean that bash-completion/completions exists underneath it.
    if mkdir -p "$COMP_DIR" 2>/dev/null && [ -w "$COMP_DIR" ]; then
        "$TARGET" --completion bash > "$COMP_DIR/cl" 2>/dev/null &&
            say "bash completion installed in $COMP_DIR"
    elif mkdir -p "$USER_COMP" 2>/dev/null && [ -w "$USER_COMP" ]; then
        "$TARGET" --completion bash > "$USER_COMP/cl" 2>/dev/null &&
            say "bash completion installed in $USER_COMP"
    else
        warn "could not install the bash completion (no writable completions folder)"
    fi
    if mkdir -p "$ZSH_DIR" 2>/dev/null && [ -w "$ZSH_DIR" ]; then
        "$TARGET" --completion zsh > "$ZSH_DIR/_cl" 2>/dev/null &&
            say "zsh completion installed in $ZSH_DIR (add it to fpath if zsh does not see it)"
    fi
fi

found=""
for p in wl-copy copyq xclip xsel pbcopy; do
    if command -v "$p" >/dev/null 2>&1; then found="${found:+$found, }$p"; fi
done
if [ -z "$found" ]; then
    say ""
    warn "no clipboard program found (wl-copy, CopyQ, xclip, xsel, pbcopy): cl will copy"
    warn "through the terminal only (OSC 52); on Ubuntu, 'sudo apt install wl-clipboard' adds one"
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        say ""
        warn "$BIN_DIR is not on your PATH."
        say "Add it with:"
        say "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
        say "    source ~/.bashrc"
        ;;
esac

say ""
say "Next steps:"
say "    cl realpath README.md                     the full path, ready for Ctrl+V"
say "    cl --doctor                               which way a copy goes on this machine"
say "    echo 'eval \"\$(cl --shell-init bash)\"' >> ~/.bashrc"
say "                                              aliases and functions after cl, and"
say "                                              Ctrl+X Ctrl+W copies the line being typed"
say "    cl --help                                 everything else"
