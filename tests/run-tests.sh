#!/usr/bin/env bash
#
# Offline test suite for cl. The clipboard is never touched: each case runs in
# a sandbox whose PATH holds only the base tools and the stand-ins of
# tests/stub for the clipboard programs it names, and the OSC 52 sequence goes
# to a file.
#
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
#
# Usage: tests/run-tests.sh [name-filter]

# The cases are called by their names (t_NAME), which the linter cannot
# follow, and the scripts in single quotes are meant for the shell they run in.
# shellcheck disable=SC2329,SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CL="$ROOT/cl"
STUB="$ROOT/tests/stub/clipstub"
FILTER="${1:-}"
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/cl-tests.XXXXXX")
SANDBOX=$(cd "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT

ESC=$(printf '\033')
BEL=$(printf '\007')
NL='
'

# The tools a case may use, found once on the PATH of the person running the
# tests; the clipboard programs are absent unless a case asks for a stand-in.
BASE_TOOLS="bash sh env cat head tail wc tr sed od cp mv rm mkdir mktemp ls ln chmod touch find
grep base64 cksum sleep timeout file perl tee dirname basename cmp diff sort printf kill python3 zsh
date readlink"
BASE_LINKS="$SANDBOX/base"
mkdir -p "$BASE_LINKS"
for t in $BASE_TOOLS; do
    p=$(command -v "$t" 2> /dev/null) || continue
    case "$p" in /*) ln -s "$p" "$BASE_LINKS/$t" ;; esac
done
HAVE_TIMEOUT=0
[ -e "$BASE_LINKS/timeout" ] && HAVE_TIMEOUT=1
HAVE_PY=0
[ -e "$BASE_LINKS/python3" ] && HAVE_PY=1

if [ "$(command uname -s)" = Darwin ]; then
    export LC_ALL=en_US.UTF-8
else
    export LC_ALL=C.UTF-8
fi
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

N=0
W=""
OUT=""
ERR=""
RC=0

# A fresh world for one case, where only the named clipboard programs exist.
world() {
    local s
    N=$((N + 1))
    W="$SANDBOX/w$N"
    mkdir -p "$W/bin" "$W/state" "$W/tmp" "$W/files"
    for s in "$BASE_LINKS"/*; do
        ln -s "$(readlink "$s")" "$W/bin/$(basename "$s")"
    done
    ln -s "$CL" "$W/bin/cl"
    ln -s "$STUB" "$W/bin/uname"
    for s in "$@"; do
        ln -s "$STUB" "$W/bin/$s"
    done
    unset WAYLAND_DISPLAY DISPLAY TMUX SSH_CONNECTION SSH_CLIENT SSH_TTY CL_VIA CL_TIMEOUT CL_TTY \
        CL_STUB_HANG CL_STUB_FAIL CL_STUB_COPYQ CL_STUB_LINGER CL_STUB_UNAME HC_TERMINAL_ID \
        TERM_PROGRAM XDG_CURRENT_DESKTOP NO_COLOR 2> /dev/null || true
    export PATH="$W/bin"
    # No case writes to a real terminal: the terminal is a file that cannot be
    # opened, unless a case names one.
    export CL_TTY="$W/no-terminal/tty"
    export CL_STUB_DIR="$W/state"
    export TMPDIR="$W/tmp"
    export TERM=xterm-256color
}

# Run cl with standard input from /dev/null (or the file in IN), keeping
# standard output, standard error and the status.
IN=/dev/null
run_cl() {
    "$CL" "$@" < "$IN" > "$W/out" 2> "$W/err"
    RC=$?
    OUT=$(tr -d '\000' < "$W/out")
    ERR=$(cat "$W/err")
    IN=/dev/null
}

# Run a command in a pseudo-terminal: standard input, output and error are a
# terminal; OUT holds what the terminal showed, without carriage returns.
run_pty() {
    python3 -I -c '
import os, pty, sys
status = pty.spawn(sys.argv[1:])
if hasattr(os, "waitstatus_to_exitcode"):
    sys.exit(os.waitstatus_to_exitcode(status))
sys.exit(status >> 8)
' "$@" < /dev/null > "$W/pty" 2>&1
    RC=$?
    OUT=$(tr -d '\r' < "$W/pty")
}

# What a stand-in selection holds: clip [SELECTION] [TYPE].
clip() {
    local sel=${1:-clipboard} want=${2:-} t slot
    [ -f "$CL_STUB_DIR/$sel/types" ] || return 1
    while IFS= read -r t; do
        if [ -z "$want" ] || [ "$t" = "$want" ]; then
            slot=$(printf '%s' "$t" | tr '/;=' '___')
            cat "$CL_STUB_DIR/$sel/$slot"
            return 0
        fi
    done < "$CL_STUB_DIR/$sel/types"
    return 1
}

types_of() {
    cat "$CL_STUB_DIR/${1:-clipboard}/types" 2> /dev/null
}

calls() {
    cat "$CL_STUB_DIR/calls" 2> /dev/null
}

# A selection filled beforehand, to see that a failure leaves it alone.
prefill() {
    mkdir -p "$CL_STUB_DIR/clipboard"
    printf '%s' "$1" > "$CL_STUB_DIR/clipboard/text_plain"
    printf 'text/plain\n' > "$CL_STUB_DIR/clipboard/types"
}

CASE_OK=1
CASE_WHY=""
expect() {
    # expect DESCRIPTION CONDITION...: one check of the current case.
    local what=$1
    shift
    if ! "$@"; then
        CASE_OK=0
        CASE_WHY="$CASE_WHY${NL}      failed: $what"
    fi
}
eq() { [ "$1" = "$2" ]; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1" "$2"; }

run_case() {
    # run_case NAME DESCRIPTION: run the function t_NAME as one case.
    local name=$1 what=$2
    if [ -n "$FILTER" ]; then
        case "$name" in *"$FILTER"*) ;; *) return ;; esac
    fi
    CASE_OK=1
    CASE_WHY=""
    if "t_$name"; then :; fi
    if [ "$CASE_OK" -eq 1 ]; then
        PASS=$((PASS + 1))
        printf 'ok    %-16s %s\n' "$name" "$what"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
        printf 'FAIL  %-16s %s%s\n' "$name" "$what" "$CASE_WHY"
        printf '      status %s\n      stdout: %s\n      stderr: %s\n' "$RC" "$OUT" "$ERR"
    fi
}

skip_case() {
    if [ -n "$FILTER" ]; then
        case "$1" in *"$FILTER"*) ;; *) return ;; esac
    fi
    SKIP=$((SKIP + 1))
    printf 'skip  %-16s %s\n' "$1" "$2"
}

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------

t_basic() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl printf 'hello world\n\n'
    expect "status 0" eq "$RC" 0
    expect "the text without its final newlines" eq "$(clip)" "hello world"
    expect "offered as plain text" eq "$(types_of)" "text/plain"
    expect "the output still on standard output" eq "$(cat "$W/out")" "hello world"
    expect "wl-copy did the copy" has "$(calls)" "wl-copy [--type] [text/plain]"
    expect "no temporary file left" eq "$(ls -A "$TMPDIR")" ""
}

t_failure() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    prefill "old content"
    run_cl sh -c 'echo partial; exit 3'
    expect "status 3 passes through" eq "$RC" 3
    expect "the clipboard keeps what it had" eq "$(clip)" "old content"
    expect "the reason is said" has "$ERR" "nothing copied: sh stopped with status 3"
    expect "the output was still shown" eq "$OUT" "partial"
}

t_notfound() {
    world wl-copy
    export WAYLAND_DISPLAY=wayland-test
    run_cl no-such-command-here x
    expect "status 127" eq "$RC" 127
    expect "the name is said" has "$ERR" "no command named no-such-command-here"
    printf 'echo hi\n' > "$W/files/script.sh"
    run_cl "$W/files/script.sh"
    expect "a file that is not executable gives 126" eq "$RC" 126
    run_cl "$W/files"
    expect "a folder gives 126" eq "$RC" 126
    expect "no copy was attempted" lacks "$(calls)" "wl-copy"
    run_cl cl_die x
    expect "a function of cl never runs as a command" eq "$RC" 127
}

t_empty() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    prefill "old content"
    run_cl true
    expect "status 1" eq "$RC" 1
    expect "the clipboard keeps what it had" eq "$(clip)" "old content"
    expect "the reason is said" has "$ERR" "true printed nothing"
}

t_arguments() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl printf '%s|' 'a b' "c'd" '$HOME' '*' ''
    expect "spaces, quotes, dollars and stars arrive intact" eq "$(clip)" "a b|c'd|\$HOME|*||"
}

t_escapes() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl printf '\033[1;31mred\033[0m and \033]8;;https://example.org\033\\a link\033]8;;\033\\\n'
    expect "colours and hyperlinks removed" eq "$(clip)" "red and a link"
    run_cl -r printf '\033[31mred\033[0m\n'
    expect "-r keeps the bytes" eq "$(clip | od -An -c | tr -d ' \n')" '033[31mred033[0m\n'
}

t_stdout() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    "$CL" printf 'a\nb\nc\n' > "$W/piped" 2> /dev/null
    expect "the next program gets the output unchanged" eq "$(od -An -c "$W/piped" | tr -d ' \n')" 'a\nb\nc\n'
    expect "and the copy is made" eq "$(clip)" "a${NL}b${NL}c"
    "$CL" sh -c 'i=0; while [ $i -lt 20000 ]; do echo "line $i"; i=$((i + 1)); done' 2> /dev/null | head -n 2 > "$W/head"
    RC=${PIPESTATUS[0]}
    expect "a reader that stops early does not stop the copy" eq "$(clip | wc -l | tr -d ' ')" 19999
    expect "and cl still succeeds" eq "$RC" 0
    expect "the reader got its lines" eq "$(cat "$W/head")" "line 0${NL}line 1"
}

png_file() {
    printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' |
        base64 -d > "$1"
}

t_picture() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    png_file "$W/files/dot.png"
    run_cl cat "$W/files/dot.png"
    expect "status 0" eq "$RC" 0
    expect "offered as image/png" eq "$(types_of)" "image/png"
    clip clipboard image/png > "$W/back.png"
    expect "the bytes are identical" cmp -s "$W/files/dot.png" "$W/back.png"
}

t_picture_tty() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    png_file "$W/files/dot.png"
    run_pty "$CL" cat "$W/files/dot.png"
    expect "the picture is not shown on the terminal" lacks "$OUT" "IHDR"
    expect "the confirmation names it" has "$OUT" "copied a picture (PNG, 1 x 1"
}

t_confirm() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test NO_COLOR=1
    run_pty "$CL" printf 'two\nlines\n'
    expect "the output is shown" has "$OUT" "two${NL}lines"
    expect "one line says what was copied" has "$OUT" "✓ copied 2 lines, 9 characters"
    run_pty "$CL" -s printf 'a fairly long line to see its start in the preview\n'
    expect "-s hides the output and shows its start" has "$OUT" "✓ copied 1 line, 50 characters: a fairly long line"
    expect "-s shows it once" eq "$(printf '%s' "$OUT" | grep -c 'a fairly long')" 1
    run_pty "$CL" -q printf 'quiet\n'
    expect "-q says nothing more" eq "$OUT" "quiet"
    run_pty "$CL"
    expect "cl alone prints its usage" has "$OUT" "Usage: cl"
    expect "and exits with 125" eq "$RC" 125
}

t_wayland() {
    world wl-copy wl-paste xclip copyq
    export WAYLAND_DISPLAY=wayland-test DISPLAY=:9
    run_cl printf 'x'
    expect "Wayland first in a Wayland session" has "$(calls)" "wl-copy"
    expect "nothing else tried" lacks "$(calls)" "xclip"
}

t_x11() {
    world xclip
    export DISPLAY=:9
    run_cl printf 'via xclip'
    expect "xclip in an X11 session" eq "$(clip)" "via xclip"
    expect "the clipboard selection" has "$(calls)" "xclip [-selection] [clipboard] [-in]"
    world xsel
    export DISPLAY=:9
    run_cl printf 'via xsel'
    expect "xsel when xclip is absent" eq "$(clip)" "via xsel"
}

t_copyq_lost() {
    world copyq wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test CL_STUB_COPYQ=lost
    run_cl -f "$ROOT/README.md"
    expect "status 0" eq "$RC" 0
    expect "a CopyQ copy that never reaches Wayland gives way to wl-copy" eq "$(types_of)" "text/uri-list"
    expect "after waiting at most a second" has "$(calls)" "wl-paste [--list-types]"
}

t_copyq() {
    world copyq
    run_cl printf 'via copyq'
    expect "CopyQ when it runs and no display program is there" eq "$(clip)" "via copyq"
    world copyq
    export CL_STUB_COPYQ=off
    run_cl printf 'x'
    expect "a CopyQ that does not run is passed over" eq "$RC" 125
    expect "with the reason" has "$ERR" "no clipboard is reachable here"
}

t_terminal() {
    world wl-copy
    export WAYLAND_DISPLAY=wayland-test SSH_CONNECTION="10.0.0.1 22 10.0.0.2 22" CL_TTY="$W/tty"
    run_cl printf 'from far away'
    expect "status 0" eq "$RC" 0
    expect "in SSH, the terminal and not the display" lacks "$(calls)" "wl-copy"
    local seq data
    seq=$(cat "$W/tty")
    expect "an OSC 52 sequence for the clipboard" has "$seq" "${ESC}]52;c;"
    data=${seq#"${ESC}]52;c;"}
    data=${data%"$BEL"}
    expect "it decodes to the text" eq "$(printf '%s' "$data" | base64 -d)" "from far away"
    run_cl -p printf 'middle'
    expect "-p aims at the primary selection" has "$(cat "$W/tty")" "${ESC}]52;p;"
}

t_terminal_size() {
    world
    export CL_TTY="$W/tty"
    run_cl sh -c 'i=0; while [ $i -lt 15000 ]; do echo "a line of about sixty characters for the size limit test"; i=$((i + 1)); done'
    expect "a text over 768 KB is refused" eq "$RC" 125
    expect "with the reason" has "$ERR" "longer than the 768 KB a terminal takes"
}

t_tmux() {
    world tmux
    export TMUX="/tmp/tmux-1/default,1,0" SSH_TTY=/dev/pts/9 CL_TTY="$W/tty"
    run_cl printf 'into tmux'
    expect "tmux load-buffer -w takes it" has "$(calls)" "tmux [load-buffer] [-w] [-]"
    expect "the text" eq "$(clip tmuxbuffer)" "into tmux"
}

t_macos() {
    world pbcopy pbpaste
    export CL_STUB_UNAME=Darwin
    run_cl printf 'on a Mac'
    expect "pbcopy on macOS" eq "$(clip)" "on a Mac"
}

t_none() {
    world
    run_cl printf 'x'
    expect "no clipboard anywhere gives 125" eq "$RC" 125
    expect "and says so" has "$ERR" "no clipboard is reachable"
}

t_fallback() {
    if [ "$HAVE_TIMEOUT" -eq 0 ]; then
        return 0
    fi
    world wl-copy xclip
    export WAYLAND_DISPLAY=wayland-test DISPLAY=:9 CL_TIMEOUT=1 CL_STUB_HANG=wl-copy
    run_cl printf 'despite a hang'
    expect "status 0" eq "$RC" 0
    expect "xclip took over" eq "$(clip)" "despite a hang"
}

t_linger() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test CL_STUB_LINGER=1
    local start end got
    start=$(date +%s 2> /dev/null || echo 0)
    got=$("$CL" printf 'quick' 2> /dev/null)
    end=$(date +%s 2> /dev/null || echo 0)
    expect "a command substitution gets the output" eq "$got" "quick"
    expect "and does not wait for the clipboard program's child" [ $((end - start)) -lt 3 ]
}

t_primary() {
    world wl-copy wl-paste xclip
    export WAYLAND_DISPLAY=wayland-test
    prefill "kept"
    run_cl -p printf 'middle click'
    expect "the primary selection holds it" eq "$(clip primary)" "middle click"
    expect "the clipboard is untouched" eq "$(clip)" "kept"
    world xclip
    export DISPLAY=:9
    run_cl -p printf 'x11 primary'
    expect "xclip aims at the primary selection" eq "$(clip primary)" "x11 primary"
}

t_always() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -a sh -c 'echo "an error report"; exit 2'
    expect "status 2 kept" eq "$RC" 2
    expect "the output copied all the same" eq "$(clip)" "an error report"
}

t_stderr() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -e sh -c 'echo out; echo err >&2; echo out2'
    expect "both streams, in order" eq "$(clip)" "out${NL}err${NL}out2"
    run_cl -ae sh -c 'echo "fatal: no such file" >&2; exit 1'
    expect "an error message of a failing command" eq "$(clip)" "fatal: no such file"
    expect "with its status" eq "$RC" 1
}

t_paste() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    prefill "pasted text"
    run_cl -o
    expect "-o prints the clipboard" eq "$OUT" "pasted text"
    expect "status 0" eq "$RC" 0
    png_file "$W/files/dot.png"
    "$CL" cat "$W/files/dot.png" > /dev/null 2>&1
    "$CL" -o > "$W/pasted.png" 2> /dev/null
    expect "a picture goes into a file" cmp -s "$W/files/dot.png" "$W/pasted.png"
    run_pty "$CL" -o
    expect "but not onto a terminal" eq "$RC" 125
    expect "which is told where to send it" has "$OUT" "cl -o > picture.png"
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -o
    expect "an empty clipboard gives 1" eq "$RC" 1
}

t_clear() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    prefill "to be cleared"
    run_cl --clear
    expect "status 0" eq "$RC" 0
    expect "the clipboard is empty" eq "$(types_of)" ""
}

t_markdown() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -cm printf 'x\n'
    expect "the command line and its output in a console block" \
        eq "$(clip)" "\`\`\`console$NL\$ printf 'x\\n'${NL}x$NL\`\`\`"
    run_cl -m printf 'a ``` inside\n'
    expect "a longer fence when the text holds three backticks" \
        eq "$(clip)" "\`\`\`\`text${NL}a \`\`\` inside$NL\`\`\`\`"
    run_cl -c echo 'my file.txt'
    expect "-c alone quotes only the words that need it" eq "$(clip)" "\$ echo 'my file.txt'${NL}my file.txt"
}

t_quote() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -Q printf 'plain\nwith space\nit'"'"'s\n'
    expect "every line quoted when it needs it" eq "$(clip)" "plain$NL'with space'$NL'it'\\''s'"
    run_cl -Q -j ' ' printf '/a b/c\n/d\n'
    expect "-Q and -j together: one line for the shell" eq "$(clip)" "'/a b/c' /d"
}

t_join() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -j ', ' printf 'a\nb\nc\n'
    expect "lines joined" eq "$(clip)" "a, b, c"
    run_cl -j, printf 'x\ny\n'
    expect "an attached separator" eq "$(clip)" "x,y"
    run_cl -sqj: printf 'p\nq\n'
    expect "a separator at the end of a cluster" eq "$(clip)" "p:q"
}

t_files() {
    world copyq wl-copy
    export WAYLAND_DISPLAY=wayland-test
    local base
    base=$(cd "$W/files" && pwd -P)
    printf 'one' > "$W/files/My Notes été.txt"
    printf 'two' > "$W/files/b.pdf"
    run_cl -f "$W/files/My Notes été.txt" "$W/files/b.pdf"
    expect "status 0" eq "$RC" 0
    expect "a list of addresses" eq "$(clip clipboard text/uri-list | tr -d '\r')" \
        "file://$base/My%20Notes%20%C3%A9t%C3%A9.txt${NL}file://$base/b.pdf"
    expect "lines ended by CR LF" has "$(clip clipboard text/uri-list | od -An -c | tr -d ' \n')" 'txt\r\n'
    expect "the last one too" eq "$(clip clipboard text/uri-list | tail -c 2 | od -An -c | tr -d ' \n')" '\r\n'
    expect "the form of GNOME Files" eq "$(clip clipboard x-special/gnome-copied-files)" \
        "copy${NL}file://$base/My%20Notes%20%C3%A9t%C3%A9.txt${NL}file://$base/b.pdf"
    expect "the paths as text" eq "$(clip clipboard text/plain)" "$base/My Notes été.txt$NL$base/b.pdf"
    expect "through CopyQ, which offers all three" lacks "$(calls)" "wl-copy"
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    printf 'two' > "$W/files/b.pdf"
    run_cl -f "$W/files/b.pdf"
    expect "without CopyQ, wl-copy offers the list of addresses" eq "$(types_of)" "text/uri-list"
    png_file "$W/files/dot.png"
    run_cl -f "$W/files/dot.png"
    expect "one picture goes as the picture" eq "$(types_of)" "image/png"
    run_cl -f "$W/files/missing.pdf"
    expect "a missing file gives 125" eq "$RC" 125
    world xclip
    export DISPLAY=:9
    printf 'two' > "$W/files/b.pdf"
    run_cl -f "$W/files/b.pdf"
    expect "xclip offers the list of addresses" eq "$(types_of)" "text/uri-list"
}

wait_for_empty() {
    local i=0
    while [ "$i" -lt 50 ]; do
        [ -z "$(clip 2> /dev/null)" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

t_secret() {
    world copyq wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test CL_STUB_COPYQ_READ=empty
    run_cl -S --clear-after 1 printf 's3cr3t-value\n'
    expect "status 0" eq "$RC" 0
    expect "never on standard output" eq "$OUT" ""
    expect "never in an argument of a program" lacks "$(calls)" "s3cr3t"
    expect "through CopyQ with the secret mark" eq "$(types_of)" "text/plain${NL}x-kde-passwordManagerHint"
    expect "the mark says secret" eq "$(clip clipboard x-kde-passwordManagerHint)" "secret"
    expect "the clipboard is emptied after the delay, read through wl-paste" wait_for_empty
    sleep 0.3
    expect "the checksum file is gone" eq "$(ls -A "$TMPDIR")" ""
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl -S --clear-after 1 printf 'another secret'
    expect "without CopyQ, wl-copy takes it as plain text" eq "$(types_of)" "text/plain"
    prefill "copied since"
    sleep 2
    expect "a newer copy is left alone" eq "$(clip)" "copied since"
    world xclip
    export DISPLAY=:9
    run_cl -S --clear-after 1 printf 'third secret'
    expect "xclip takes it as text" eq "$(types_of)" "UTF8_STRING"
    expect "and it is read back and cleared" wait_for_empty
}

t_status() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    printf 'x\n' > "$W/in"
    IN="$W/in"
    run_cl
    expect "a pipe is copied" eq "$(clip)" "x"
    printf 'y\n' > "$W/in"
    IN="$W/in"
    run_cl --status 2
    expect "--status 2 copies nothing" eq "$(clip)" "x"
    expect "and exits with 2" eq "$RC" 2
    IN="$W/in"
    run_cl --status 2 -a -c --line 'll -h'
    expect "--line gives -c its command line" eq "$(clip)" "\$ ll -h${NL}y"
    IN="$W/in"
    run_cl --status 1 --line 'll -h'
    expect "and the messages their name" has "$ERR" "ll stopped with status 1"
}

t_interrupt() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl sh -c 'echo before; kill -INT $$'
    expect "a command stopped by Ctrl+C gives 130" eq "$RC" 130
    expect "nothing copied" eq "$(types_of)" ""
    expect "the reason is said" has "$ERR" "interrupted"
}

t_options() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    run_cl --no-such-option ls
    expect "an unknown option gives 125" eq "$RC" 125
    run_cl -x ls
    expect "an unknown short option too" eq "$RC" 125
    run_cl --via nowhere printf x
    expect "an unknown route too" eq "$RC" 125
    run_cl -- printf 'after a double dash'
    expect "-- ends the options" eq "$(clip)" "after a double dash"
    run_cl --version
    expect "--version prints the version first" eq "$OUT" "cl 1.0.0"
    run_cl --help
    expect "--help prints the usage" has "$OUT" "Usage:"
}

t_via() {
    world wl-copy wl-paste xclip
    export WAYLAND_DISPLAY=wayland-test DISPLAY=:9
    run_cl --via x11 printf 'forced'
    expect "--via x11 skips Wayland" lacks "$(calls)" "wl-copy"
    export CL_VIA=terminal CL_TTY="$W/tty"
    run_cl printf 'by the variable'
    expect "CL_VIA does the same" has "$(cat "$W/tty")" "${ESC}]52;c;"
}

t_doctor() {
    world wl-copy wl-paste copyq xclip
    export WAYLAND_DISPLAY=wayland-test DISPLAY=:9
    run_cl --doctor
    expect "status 0" eq "$RC" 0
    expect "names the session" has "$OUT" "Wayland (wayland-test)"
    expect "names the first route" has "$OUT" "wayland (wl-clipboard 2.2.1 (stub))"
    expect "and what follows it" has "$OUT" "if it fails: copyq, x11"
    expect "secrets go through CopyQ" has "$OUT" "Secrets     copyq"
    expect "changes nothing" eq "$(types_of)" ""
}

t_completion() {
    world
    local got
    got=$(bash --norc --noprofile -c '
        eval "$(cl --completion bash)"
        _comp_command_offset() { printf "offset=%s\n" "$1"; }
        COMP_WORDS=(cl -c git che); COMP_CWORD=3; _cl
        COMP_WORDS=(cl -j " " ls ""); COMP_CWORD=4; _cl
        COMP_WORDS=(cl --vi); COMP_CWORD=1; COMPREPLY=(); _cl; printf "%s\n" "${COMPREPLY[@]}"
        COMP_WORDS=(cl --via w); COMP_CWORD=2; COMPREPLY=(); _cl; printf "%s\n" "${COMPREPLY[@]}"
        COMP_WORDS=(cl -s prin); COMP_CWORD=2; COMPREPLY=(); _cl; printf "%s\n" "${COMPREPLY[@]}"
    ' 2>&1)
    expect "the wrapped command is completed as itself" has "$got" "offset=2"
    expect "an option with its argument is skipped" has "$got" "offset=3"
    expect "cl's options are offered" has "$got" "--via"
    expect "the routes after --via" has "$got" "wayland"
    expect "command names in the place of the command" has "$got" "printf"
    if [ -e "$W/bin/zsh" ]; then
        cl --completion zsh > "$W/_cl"
        expect "the zsh completion parses" zsh -n "$W/_cl"
    fi
}

t_shell() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    local got
    got=$(bash --norc --noprofile -c '
        shopt -s expand_aliases
        eval "$(cl --shell-init bash)"
        alias greet="printf hello"
        myfn() { printf "from a function\n"; }
        badfn() { echo oops; return 4; }
        cl greet > /dev/null; printf "<%s>" "$?"
        cl myfn > /dev/null; printf "<%s>" "$?"
        cl -c myfn > /dev/null; printf "<%s>" "$?"
        cl badfn > /dev/null; printf "<%s>" "$?"
        cl printf plain > /dev/null; printf "<%s>" "$?"
    ' 2> /dev/null)
    expect "the function returns the statuses" has "$got" "<0><0><0><4><0>"
    expect "the program got the last copy" eq "$(clip)" "plain"
    got=$(bash --norc --noprofile -c '
        shopt -s expand_aliases
        eval "$(cl --shell-init bash)"
        alias greet="printf hello"
        cl greet > /dev/null
    ' 2> /dev/null)
    expect "an alias runs in the shell" eq "$(clip)" "hello"
    bash --norc --noprofile -c '
        eval "$(cl --shell-init bash)"
        myfn() { printf "from a function\n"; }
        cl -c myfn > /dev/null
    ' 2> /dev/null
    expect "a function, with -c naming it" eq "$(clip)" "\$ myfn${NL}from a function"
}

t_copykey() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test
    python3 -I -c '
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "--norc", "--noprofile", "-i"])
def send(b, wait=0.5):
    os.write(fd, b)
    time.sleep(wait)
    while select.select([fd], [], [], 0.1)[0]:
        try:
            os.read(fd, 65536)
        except OSError:
            break
time.sleep(0.5)
send(b"eval \"$(cl --shell-init bash)\"\n", 1.0)
send(b"echo a line typed and not run")
send(b"\x18\x17", 1.0)
send(b"\x15")
send(b"exit\n")
os.waitpid(pid, 0)
' > /dev/null 2>&1
    expect "Ctrl+X Ctrl+W copies the line being typed" eq "$(clip)" "echo a line typed and not run"
}

t_open_line() {
    world wl-copy wl-paste
    export WAYLAND_DISPLAY=wayland-test NO_COLOR=1
    run_pty "$CL" printf 'no newline at the end'
    expect "the confirmation starts on a line of its own" has "$OUT" "no newline at the end${NL}✓ copied 1 line"
}

# ---------------------------------------------------------------------------

printf 'cl test suite, bash %s\n' "$BASH_VERSION"
run_case basic "the output of a command that succeeds is copied without its final newline"
run_case failure "a failing command copies nothing and its status passes through"
run_case notfound "a missing command gives 127, one that cannot run 126"
run_case empty "a command that prints nothing copies nothing (status 1)"
run_case arguments "the arguments reach the command exactly as written"
run_case escapes "colour and hyperlink codes are removed, and -r keeps them"
run_case stdout "the output still reaches the screen or the next program"
run_case picture "a PNG picture is copied byte for byte with its type"
if [ "$HAVE_PY" -eq 1 ]; then
    run_case picture_tty "a picture is not shown on a terminal while it is copied"
    run_case confirm "one line says what was copied; -s and -q change it"
else
    skip_case picture_tty "needs python3 for a pseudo-terminal"
    skip_case confirm "needs python3 for a pseudo-terminal"
fi
run_case wayland "Wayland goes first in a Wayland session"
run_case x11 "xclip, else xsel, in an X11 session"
run_case copyq "CopyQ when it runs, and not when it does not"
run_case copyq_lost "a CopyQ copy that never reaches the Wayland side gives way to wl-copy"
run_case terminal "an SSH session copies through the terminal (OSC 52)"
run_case terminal_size "the terminal refuses a text over 768 KB"
run_case tmux "inside tmux in SSH, tmux passes the copy on"
run_case macos "pbcopy on macOS"
run_case none "no clipboard at all gives 125 with the reason"
if [ "$HAVE_TIMEOUT" -eq 1 ]; then
    run_case fallback "a wl-copy that hangs gives way to xclip within the time limit"
else
    skip_case fallback "needs the timeout program"
fi
run_case linger "the child of the clipboard program never holds the output open"
run_case primary "-p fills the primary selection and leaves the clipboard"
run_case always "-a copies the output of a failing command and keeps its status"
run_case stderr "-e copies the error stream too, in order"
if [ "$HAVE_PY" -eq 1 ]; then
    run_case paste "-o prints the clipboard; a picture only into a file"
else
    skip_case paste "needs python3 for a pseudo-terminal"
fi
run_case clear "--clear empties the clipboard"
run_case markdown "-c and -m give the command and its output as Markdown"
run_case quote "-Q quotes every line for the shell"
run_case join "-j joins the lines"
run_case files "-f puts files on the clipboard, and one picture as the picture"
run_case secret "-S keeps a secret off the screen and clears it after the delay"
run_case status "--status and --line carry a command run beforehand"
run_case interrupt "a command stopped by Ctrl+C copies nothing (status 130)"
run_case options "options, clusters, -- and the errors of usage"
run_case via "--via and CL_VIA force a route"
run_case doctor "--doctor names the session and the routes, and changes nothing"
run_case completion "the completion skips cl's options and completes the command"
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    run_case shell "the shell additions run aliases and functions"
else
    skip_case shell "the shell additions need bash 4 or newer"
fi
if [ "${BASH_VERSINFO[0]}" -ge 4 ] && [ "$HAVE_PY" -eq 1 ]; then
    run_case copykey "the keys Ctrl+X Ctrl+W copy the command line being typed"
else
    skip_case copykey "needs bash 4 or newer and python3"
fi
if [ "$HAVE_PY" -eq 1 ]; then
    run_case open_line "after an output without a final newline, the confirmation starts a new line"
else
    skip_case open_line "needs python3 for a pseudo-terminal"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
