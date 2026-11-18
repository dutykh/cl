#!/usr/bin/env bash
#
# cl: run a command and, when it succeeds, put what it printed on the clipboard.
#
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
#
# Homepage:  https://github.com/dutykh/cl
# License:   LGPL-2.1-or-later, see the LICENSE file of the distribution.
#
# Dependencies: bash 3.2 or newer, and one way to reach a clipboard: wl-copy of
# wl-clipboard in a Wayland session, CopyQ, xclip or xsel in an X11 session,
# pbcopy on macOS, or a terminal that accepts the OSC 52 sequence (Herdr,
# Ghostty, kitty, WezTerm, foot, iTerm2 and others), which is the way out of an
# SSH session. Optional: perl, which keeps a picture off the screen while it is
# copied, and file, which names the type of an output that is not text.
#
# Layout of the file: settings and messages, the routes to a clipboard (their
# choice, then copy, read and clear along each), the shaping of the text, the
# modes (a command, a pipe, files, paste, clear, doctor), the completion and the
# shell additions, the help, main.

# Some functions are reached only through a trap or a background job, which the
# linter cannot follow.
# shellcheck disable=SC2329

set -uo pipefail

CL_VERSION="1.0.0"

# Exit statuses besides that of the command, documented in the help and in the README.
readonly EX_EMPTY=1        # the command succeeded and printed nothing
readonly EX_CL=125         # cl itself failed: an option, no clipboard, the clipboard program
readonly EX_NOEXEC=126     # the command cannot be run
readonly EX_NOTFOUND=127   # no command of that name
readonly EX_INT=130        # interrupted by Ctrl+C

# The longest text sent through the terminal: 1 MiB once encoded in base64, the limit of Herdr.
readonly TERMINAL_LIMIT=786432

ESC=$'\033'
BEL=$'\007'
CR=$'\r'
NL=$'\n'

# Escape sequences removed from a copied text: colours and cursor moves (CSI),
# hyperlinks and titles (OSC), character sets, keypad modes.
SED_CSI="s/${ESC}\\[[0-?]*[ -/]*[@-~]//g"
SED_OSC="s/${ESC}\\][^${BEL}${ESC}]*(${BEL}|${ESC}\\\\)//g"
SED_CHARSET="s/${ESC}[()*+][0-9A-Za-z]//g"
SED_KEYPAD="s/${ESC}[=>]//g"

# The tee of the output: every byte goes to the file named first; the screen
# gets the same bytes, except that a terminal stops receiving them at the first
# NUL byte (a picture). A reader that goes away (cl cmd | head) stops the echo
# and not the copy.
IFS= read -r -d '' CL_PERL_TEE <<'PERL' || true
use strict;
use warnings;
my ($keep, $tty) = @ARGV;
open(my $fh, '>', $keep) or die "cl: cannot write $keep: $!\n";
binmode(STDIN);
binmode(STDOUT);
binmode($fh);
$SIG{PIPE} = 'IGNORE';
my ($show, $buf) = (1, '');
while (1) {
    my $n = sysread(STDIN, $buf, 65536);
    if (!defined $n) { next if $!{EINTR}; last; }
    last if $n == 0;
    print {$fh} $buf or die "cl: cannot write $keep: $!\n";
    next unless $show;
    if ($tty && index($buf, "\0") >= 0) { $show = 0; next; }
    my $off = 0;
    while ($off < $n) {
        my $w = syswrite(STDOUT, $buf, $n - $off, $off);
        if (!defined $w) { next if $!{EINTR}; $show = 0; last; }
        $off += $w;
    }
}
close($fh) or die "cl: cannot write $keep: $!\n";
PERL

# ---------------------------------------------------------------------------
# Global state, all assigned before use so that "set -u" stays meaningful
# ---------------------------------------------------------------------------

MODE="run"                # run, files, paste, clear, doctor, completion, shellinit, help, version
OPT_SILENT=0              # -s: the output is not shown
OPT_QUIET=0               # -q: no confirmation line
OPT_ALWAYS=0              # -a: copy even when the command fails
OPT_STDERR=0              # -e: the error stream is copied too
OPT_RAW=0                 # -r: the bytes as they came
OPT_PRIMARY=0             # -p: the primary selection
OPT_CMDLINE=0             # -c: the command line before its output
OPT_MARKDOWN=0            # -m: a Markdown code block
OPT_QUOTE=0               # -Q: every line quoted for the shell
OPT_JOIN=""               # -j: the separator of the joined lines
JOIN_SET=0
OPT_SECRET=0              # -S: a secret, cleared after a while
SHOWN_OPEN=0              # the output shown on the terminal ended without a newline
CLEAR_AFTER=""            # --clear-after: seconds before the clipboard is cleared
OPT_VIA="${CL_VIA:-}"     # --via: the route asked for
GIVEN_STATUS=""           # --status: the status of a command run beforehand
GIVEN_LINE=""             # --line: its command line
SHELL_ARG=""              # --completion and --shell-init: the shell
WORK=""                   # the private temporary folder of this run
CMD_NAME=""               # the command, as the messages name it
CMD_LINE=""               # the command line, as -c prints it
CMD_STATUS=0              # the status of the command, kept with -a
ROUTE_USED=""             # the route that took the copy
ROUTE_NOTES=""            # why the routes before it were passed over
COPYQ_STATE=""            # yes or no once CopyQ was asked whether it runs
CL_Q=""                   # result of cl_quote_word
CL_DESC=""                # result of the describe functions
CL_DETAIL=""              # the details of a picture: format, size

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

cl_colour() {
    [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]
}

# The line that says what was copied: at a terminal only, and not with -q.
cl_say_ok() {
    [ "$OPT_QUIET" -eq 1 ] && return 0
    [ -t 2 ] || return 0
    [ "$SHOWN_OPEN" -eq 1 ] && printf '\n' >&2
    if cl_colour; then
        printf '\033[32m✓\033[0m %s\n' "$1" >&2
    else
        printf '✓ %s\n' "$1" >&2
    fi
}

# A failure line: a mark at a terminal, the name of the program in a log.
cl_mark_fail() {
    if [ -t 2 ]; then
        [ "$SHOWN_OPEN" -eq 1 ] && printf '\n' >&2
        if cl_colour; then
            printf '\033[31m✗\033[0m %s\n' "$1" >&2
        else
            printf '✗ %s\n' "$1" >&2
        fi
    else
        printf 'cl: %s\n' "$1" >&2
    fi
}

# Nothing was copied because of the command (silenced by -q), then exit.
cl_nothing() {
    local status=$1
    shift
    [ "$OPT_QUIET" -eq 1 ] || cl_mark_fail "nothing copied: $*"
    exit "$status"
}

# cl itself cannot go on: always said.
cl_die() {
    local status=$1
    shift
    cl_mark_fail "$*"
    exit "$status"
}

cl_usage_error() {
    cl_die "$EX_CL" "$* (cl --help lists the options)"
}

cl_plural() {
    if [ "$1" -eq 1 ]; then
        printf '%s %s' "$1" "$2"
    else
        printf '%s %ss' "$1" "$2"
    fi
}

# The command, as the messages name it.
cl_what() {
    if [ -n "$CMD_NAME" ]; then
        printf '%s' "$CMD_NAME"
    else
        printf 'the command'
    fi
}

cl_have() {
    command -v "$1" > /dev/null 2>&1
}

cl_workdir() {
    [ -n "$WORK" ] && return 0
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/cl.XXXXXX") || cl_die "$EX_CL" "cannot make a temporary folder"
}

cl_cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf "$WORK"
    fi
}

cl_interrupted() {
    trap - INT TERM HUP
    [ "$OPT_QUIET" -eq 1 ] || cl_mark_fail "nothing copied: interrupted"
    exit "$1"
}

trap cl_cleanup EXIT
trap 'cl_interrupted "$EX_INT"' INT
trap 'cl_interrupted 143' TERM
trap 'cl_interrupted 129' HUP

cl_with_timeout() {
    local secs=${CL_TIMEOUT:-5}
    case "$secs" in '' | *[!0-9]*) secs=5 ;; esac
    if cl_have timeout; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# A short reason from the error file of a clipboard program.
cl_reason() {
    local status=$1 prog=$2 err=$3 line=""
    if [ "$status" -eq 124 ] && cl_have timeout; then
        printf '%s did not answer within %s s' "$prog" "${CL_TIMEOUT:-5}"
        return
    fi
    [ -s "$err" ] && line=$(head -n 1 "$err")
    if [ -n "$line" ]; then
        printf '%s failed: %s' "$prog" "$line"
    else
        printf '%s failed with status %s' "$prog" "$status"
    fi
}

cl_note() {
    if [ -z "$ROUTE_NOTES" ]; then
        ROUTE_NOTES=$1
    else
        ROUTE_NOTES="$ROUTE_NOTES; $1"
    fi
}

# ---------------------------------------------------------------------------
# The routes to a clipboard
# ---------------------------------------------------------------------------

cl_in_ssh() {
    [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]
}

cl_is_macos() {
    [ "$(uname -s 2> /dev/null)" = Darwin ]
}

cl_copyq_runs() {
    if [ -z "$COPYQ_STATE" ]; then
        COPYQ_STATE=no
        if cl_have copyq && cl_with_timeout copyq eval -- 1 > /dev/null 2>&1; then
            COPYQ_STATE=yes
        fi
    fi
    [ "$COPYQ_STATE" = yes ]
}

cl_tty_opens() {
    if [ -n "${CL_TTY:-}" ]; then
        { : >> "$CL_TTY"; } 2> /dev/null
        return
    fi
    { : > /dev/tty; } 2> /dev/null
}

# Whether a route can be tried here.
cl_route_ready() {
    case "$1" in
        wayland) [ -n "${WAYLAND_DISPLAY:-}" ] && cl_have wl-copy ;;
        copyq) cl_copyq_runs ;;
        x11) [ -n "${DISPLAY:-}" ] && { cl_have xclip || cl_have xsel; } ;;
        macos) cl_have pbcopy ;;
        tmux) [ -n "${TMUX:-}" ] && cl_have tmux ;;
        terminal) cl_tty_opens ;;
        *) return 1 ;;
    esac
}

# The routes for a kind of copy, in the order they are tried: text, picture,
# files, secret, read (for -o and for the check before a secret is cleared).
cl_routes_for() {
    local kind=$1 list
    if [ -n "$OPT_VIA" ]; then
        printf '%s' "$OPT_VIA"
        return
    fi
    if cl_in_ssh; then
        case "$kind" in
            text | clear) list="tmux terminal x11" ;;
            secret) list="terminal x11" ;;
            picture | files) list="x11" ;;
            read) list="x11" ;;
        esac
    elif cl_is_macos; then
        case "$kind" in
            text | clear) list="macos copyq tmux terminal" ;;
            secret) list="copyq macos terminal" ;;
            picture | files) list="copyq" ;;
            read) list="macos copyq" ;;
        esac
    else
        case "$kind" in
            text | clear) list="wayland copyq x11 tmux terminal" ;;
            secret) list="copyq wayland x11 terminal" ;;
            picture) list="wayland copyq x11" ;;
            files) list="copyq wayland x11" ;;
            read) list="wayland copyq x11" ;;
        esac
    fi
    # The primary selection is reached by wl-copy, xclip, xsel, the terminal,
    # and read through CopyQ.
    if [ "$OPT_PRIMARY" -eq 1 ]; then
        local r kept=""
        for r in $list; do
            case "$r:$kind" in
                wayland:* | x11:* | terminal:* | copyq:read) kept="$kept $r" ;;
            esac
        done
        list=$kept
    fi
    printf '%s' "$list"
}

cl_valid_route() {
    case "$1" in
        wayland | copyq | x11 | macos | tmux | terminal) return 0 ;;
    esac
    return 1
}

# Copy a file along one route. The kind is text, secret (a text that CopyQ
# keeps out of its history), files (a list of addresses, which CopyQ offers
# in three forms) or the MIME type of a picture or other data.
cl_copy_via() {
    local route=$1 f=$2 kind=$3 type err status sel
    case "$kind" in
        text | secret) type=text ;;
        files) type=text/uri-list ;;
        *) type=$kind ;;
    esac
    cl_workdir
    err="$WORK/err.$route"
    : > "$err"
    case "$route" in
        wayland)
            local -a args=()
            [ "$OPT_PRIMARY" -eq 1 ] && args=(--primary)
            if [ "$type" = text ]; then
                args=(${args[@]+"${args[@]}"} --type text/plain)
            else
                args=(${args[@]+"${args[@]}"} --type "$type")
            fi
            # Its child serves the clipboard from the background: no stream of
            # ours may stay open in it, or the reader of our output would wait.
            cl_with_timeout wl-copy "${args[@]}" < "$f" > /dev/null 2> "$err"
            status=$?
            [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" wl-copy "$err")"; return 1; }
            ;;
        x11)
            sel=clipboard
            [ "$OPT_PRIMARY" -eq 1 ] && sel=primary
            if cl_have xclip; then
                if [ "$type" = text ]; then
                    cl_with_timeout xclip -selection "$sel" -in < "$f" > /dev/null 2> "$err"
                else
                    cl_with_timeout xclip -selection "$sel" -t "$type" -in < "$f" > /dev/null 2> "$err"
                fi
                status=$?
                [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" xclip "$err")"; return 1; }
                cl_wait_wayland "$kind" "$f" "$type" || { cl_note "the copy of xclip did not reach the Wayland programs"; return 1; }
            elif [ "$type" = text ] && cl_have xsel; then
                cl_with_timeout xsel "--$sel" --input < "$f" > /dev/null 2> "$err"
                status=$?
                [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" xsel "$err")"; return 1; }
                cl_wait_wayland "$kind" "$f" "$type" || { cl_note "the copy of xsel did not reach the Wayland programs"; return 1; }
            else
                cl_note "xsel takes text only"
                return 1
            fi
            ;;
        copyq)
            if [ "$OPT_PRIMARY" -eq 1 ]; then
                cl_note "CopyQ cannot set the primary selection"
                return 1
            fi
            case "$kind" in
                text) cl_with_timeout copyq copy text/plain - < "$f" > /dev/null 2> "$err" ;;
                secret) cl_with_timeout copyq copy text/plain - x-kde-passwordManagerHint secret < "$f" > /dev/null 2> "$err" ;;
                files)
                    # After --, CopyQ takes the data as written (a backslash
                    # in a file name stays a backslash). Each form is read
                    # whole, with its final CR LF.
                    local uris gnome paths
                    uris=$(cat "$f"; printf x)
                    gnome=$(cat "$WORK/gnome"; printf x)
                    paths=$(cat "$WORK/paths"; printf x)
                    cl_with_timeout copyq copy -- text/uri-list "${uris%x}" \
                        x-special/gnome-copied-files "${gnome%x}" \
                        text/plain "${paths%x}" < /dev/null > /dev/null 2> "$err"
                    ;;
                *) cl_with_timeout copyq copy "$type" - < "$f" > /dev/null 2> "$err" ;;
            esac
            status=$?
            [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" copyq "$err")"; return 1; }
            cl_wait_wayland "$kind" "$f" "$type" || { cl_note "the copy of CopyQ did not reach the Wayland programs"; return 1; }
            ;;
        macos)
            if [ "$type" != text ]; then
                cl_note "pbcopy takes text only"
                return 1
            fi
            LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pbcopy < "$f" > /dev/null 2> "$err"
            status=$?
            [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" pbcopy "$err")"; return 1; }
            ;;
        tmux)
            if [ "$type" != text ]; then
                cl_note "tmux takes text only"
                return 1
            fi
            tmux load-buffer -w - < "$f" > /dev/null 2> "$err"
            status=$?
            [ "$status" -eq 0 ] || { cl_note "$(cl_reason "$status" tmux "$err")"; return 1; }
            ;;
        terminal)
            if [ "$type" != text ]; then
                cl_note "the terminal takes text only"
                return 1
            fi
            cl_osc52 "$f" || return 1
            ;;
        *)
            cl_note "no route named $route"
            return 1
            ;;
    esac
    ROUTE_USED=$route
    return 0
}

# In a Wayland session a copy made through X11 (CopyQ, xclip) reaches the
# Wayland programs a few tens of milliseconds later. Wait for it, at most a
# second, so that the copy is in place when cl returns; a copy that never
# arrives counts as failed. A wl-paste that does not answer ends the check.
cl_wait_wayland() {
    local kind=$1 f=$2 type=$3 want="" got st i=0
    if [ -z "${WAYLAND_DISPLAY:-}" ] || ! cl_have wl-paste || [ "$OPT_PRIMARY" -eq 1 ]; then
        return 0
    fi
    case "$kind" in
        text | secret) want=$(cksum < "$f") ;;
        files) type=text/uri-list ;;
    esac
    while [ "$i" -lt 20 ]; do
        if [ -n "$want" ]; then
            got=$(CL_TIMEOUT=1 cl_with_timeout wl-paste --no-newline --type text/plain 2> /dev/null | cksum)
            st=${PIPESTATUS[0]}
            [ "$got" = "$want" ] && return 0
        else
            got=$(CL_TIMEOUT=1 cl_with_timeout wl-paste --list-types 2> /dev/null)
            st=$?
            case "$NL$got$NL" in *"$NL$type$NL"*) return 0 ;; esac
        fi
        [ "$st" -eq 124 ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

# The OSC 52 sequence: the terminal puts the text on the clipboard of the
# machine where its window is, however many SSH sessions lie between.
cl_osc52() {
    local f=$1 size data target=c seq tty
    size=$(($(wc -c < "$f")))
    if [ "$size" -gt "$TERMINAL_LIMIT" ]; then
        cl_note "the text ($((size / 1024)) KB) is longer than the 768 KB a terminal takes"
        return 1
    fi
    if ! cl_tty_opens; then
        cl_note "no terminal is attached"
        return 1
    fi
    [ "$OPT_PRIMARY" -eq 1 ] && target=p
    data=$(base64 < "$f" | tr -d '\r\n')
    seq="${ESC}]52;${target};${data}${BEL}"
    # Inside tmux the sequence travels wrapped, for a tmux that lets it through.
    if [ -n "${TMUX:-}" ]; then
        seq="${ESC}Ptmux;${seq//${ESC}/${ESC}${ESC}}${ESC}\\"
    fi
    tty=${CL_TTY:-/dev/tty}
    if ! { printf '%s' "$seq" > "$tty"; } 2> /dev/null; then
        cl_note "the terminal could not be written"
        return 1
    fi
    return 0
}

# Try the routes of a kind in turn; the first that takes the copy wins.
cl_copy() {
    local kind=$1 f=$2 type=$3 route tried=0
    for route in $(cl_routes_for "$kind"); do
        cl_valid_route "$route" || cl_usage_error "no route named $route; the routes are wayland, copyq, x11, macos, tmux and terminal"
        if [ -z "$OPT_VIA" ] && ! cl_route_ready "$route"; then
            continue
        fi
        tried=1
        cl_copy_via "$route" "$f" "$type" && return 0
    done
    if [ "$tried" -eq 0 ]; then
        case "$kind" in
            picture | files)
                if cl_in_ssh; then
                    cl_note "a picture or a file cannot travel through the terminal of an SSH session"
                else
                    cl_note "a picture or a file needs wl-copy, CopyQ or xclip in a desktop session"
                fi
                ;;
            *) cl_note "no clipboard is reachable here (no Wayland or X11 session, no CopyQ, no terminal); cl --doctor says more" ;;
        esac
    fi
    return 1
}

# Print what a route holds now, as text (the check before a secret is cleared,
# and -o).
cl_read_via() {
    local route=$1 sel=clipboard
    [ "$OPT_PRIMARY" -eq 1 ] && sel=primary
    case "$route" in
        wayland)
            if [ "$OPT_PRIMARY" -eq 1 ]; then
                cl_with_timeout wl-paste --primary --no-newline --type text 2> /dev/null
            else
                cl_with_timeout wl-paste --no-newline --type text 2> /dev/null
            fi
            ;;
        copyq)
            if [ "$OPT_PRIMARY" -eq 1 ]; then
                cl_with_timeout copyq selection 2> /dev/null
            else
                cl_with_timeout copyq clipboard 2> /dev/null
            fi
            ;;
        x11)
            if cl_have xclip; then
                cl_with_timeout xclip -selection "$sel" -o 2> /dev/null
            else
                cl_with_timeout xsel "--$sel" --output 2> /dev/null
            fi
            ;;
        macos) LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pbpaste 2> /dev/null ;;
        *) return 1 ;;
    esac
}

# What the clipboard of the desktop holds, as text, read by the program that
# sees it best: wl-paste in a Wayland session (CopyQ cannot read it there
# without the focus), else xclip or xsel, pbpaste, CopyQ.
cl_read_back() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] && cl_have wl-paste; then
        cl_read_via wayland
    elif [ -n "${DISPLAY:-}" ] && { cl_have xclip || cl_have xsel; }; then
        cl_read_via x11
    elif cl_is_macos && cl_have pbpaste; then
        cl_read_via macos
    elif cl_copyq_runs; then
        cl_read_via copyq
    else
        return 1
    fi
}

# Empty the clipboard along one route.
cl_clear_via() {
    local route=$1 sel=clipboard empty
    [ "$OPT_PRIMARY" -eq 1 ] && sel=primary
    case "$route" in
        wayland)
            if [ "$OPT_PRIMARY" -eq 1 ]; then
                cl_with_timeout wl-copy --primary --clear > /dev/null 2>&1
            else
                cl_with_timeout wl-copy --clear > /dev/null 2>&1
            fi
            ;;
        copyq) printf '' | cl_with_timeout copyq copy text/plain - > /dev/null 2>&1 ;;
        x11)
            if cl_have xclip; then
                cl_with_timeout xclip -selection "$sel" -in < /dev/null > /dev/null 2>&1
            else
                cl_with_timeout xsel "--$sel" --clear > /dev/null 2>&1
            fi
            ;;
        macos) pbcopy < /dev/null > /dev/null 2>&1 ;;
        tmux) printf '' | tmux load-buffer -w - > /dev/null 2>&1 ;;
        terminal)
            cl_workdir
            empty="$WORK/empty"
            : > "$empty"
            cl_osc52 "$empty"
            ;;
        *) return 1 ;;
    esac
}

# A detached job empties the clipboard after a delay, if it still holds what
# cl put there. Only the checksum waits, in a file of its own; through the
# terminal and tmux nothing can be read back, so the clipboard is emptied then
# whatever it holds.
cl_schedule_clear() {
    local secs=$1 f=$2 route=$ROUTE_USED sumfile
    sumfile=$(mktemp "${TMPDIR:-/tmp}/cl-clear.XXXXXX") || return 1
    cksum < "$f" > "$sumfile"
    cl_clear_job "$secs" "$route" "$sumfile" < /dev/null > /dev/null 2>&1 &
    disown 2> /dev/null || true
    return 0
}

# The detached job itself, with a temporary folder of its own.
cl_clear_job() {
    local secs=$1 route=$2 sumfile=$3 WORK=""
    trap '' HUP INT TERM
    sleep "$secs"
    case "$route" in
        terminal | tmux) cl_clear_via "$route" ;;
        *)
            if [ "$(cl_read_back | cksum)" = "$(cat "$sumfile")" ]; then
                cl_clear_via "$route"
                # A clipboard that still holds it is emptied on the Wayland side.
                if [ "$(cl_read_back | cksum)" = "$(cat "$sumfile")" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && cl_have wl-copy; then
                    cl_clear_via wayland
                fi
            fi
            ;;
    esac
    rm -f "$sumfile"
    cl_cleanup
}

# ---------------------------------------------------------------------------
# The text
# ---------------------------------------------------------------------------

cl_has_nul() {
    local all clean
    all=$(wc -c < "$1")
    clean=$(LC_ALL=C tr -d '\000' < "$1" | wc -c)
    [ $((all)) -ne $((clean)) ]
}

cl_mime() {
    local t=""
    if cl_have file; then
        t=$(file -b --mime-type "$1" 2> /dev/null)
    fi
    case "$t" in
        */*) printf '%s' "$t" ;;
        *) printf 'application/octet-stream' ;;
    esac
}

# Quote a word for the shell only when it needs it; the result is in CL_Q.
cl_quote_word() {
    local w=$1 out="" part
    case "$w" in
        '')
            CL_Q="''"
            return
            ;;
        *[!A-Za-z0-9_./:=@%^,+-]*) ;;
        *)
            CL_Q=$w
            return
            ;;
    esac
    while :; do
        case "$w" in
            *\'*)
                part=${w%%\'*}
                out=$out$part"'\\''"
                w=${w#*\'}
                ;;
            *)
                out=$out$w
                break
                ;;
        esac
    done
    CL_Q="'$out'"
}

cl_quote_words() {
    local w line=""
    for w in "$@"; do
        cl_quote_word "$w"
        if [ -z "$line" ]; then
            line=$CL_Q
        else
            line="$line $CL_Q"
        fi
    done
    printf '%s' "$line"
}

# Shape the captured output into the text that is copied: escape sequences
# removed, lines quoted, lines joined, the command line first, the Markdown
# fence around, final newlines removed.
cl_shape() {
    local in=$1 out=$2 body line first acc fence lang
    if [ "$OPT_RAW" -eq 1 ] && [ "$OPT_QUOTE$OPT_CMDLINE$OPT_MARKDOWN$JOIN_SET" = 0000 ]; then
        cp "$in" "$out"
        return
    fi
    if [ "$OPT_RAW" -eq 0 ]; then
        if LC_ALL=C sed -E -e "$SED_CSI" -e "$SED_OSC" -e "$SED_CHARSET" -e "$SED_KEYPAD" "$in" > "$WORK/clean" 2> /dev/null; then
            in="$WORK/clean"
        fi
    fi
    body=$(cat "$in")
    while :; do
        case "$body" in
            *"$CR") body=${body%"$CR"} ;;
            *"$NL") body=${body%"$NL"} ;;
            *) break ;;
        esac
    done
    if [ "$OPT_QUOTE" -eq 1 ]; then
        acc=""
        first=1
        while IFS= read -r line || [ -n "$line" ]; do
            cl_quote_word "$line"
            if [ "$first" -eq 1 ]; then
                acc=$CL_Q
                first=0
            else
                acc="$acc$NL$CL_Q"
            fi
        done <<EOF
$body
EOF
        body=$acc
    fi
    if [ "$JOIN_SET" -eq 1 ]; then
        acc=""
        first=1
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$first" -eq 1 ]; then
                acc=$line
                first=0
            else
                acc="$acc$OPT_JOIN$line"
            fi
        done <<EOF
$body
EOF
        body=$acc
    fi
    if [ "$OPT_CMDLINE" -eq 1 ] && [ -n "$CMD_LINE" ]; then
        body="\$ $CMD_LINE$NL$body"
    fi
    if [ "$OPT_MARKDOWN" -eq 1 ]; then
        fence='```'
        lang=text
        [ "$OPT_CMDLINE" -eq 1 ] && lang=console
        while :; do
            case "$body" in
                *"$fence"*) fence="$fence\`" ;;
                *) break ;;
            esac
        done
        body="$fence$lang$NL$body$NL$fence"
    fi
    printf '%s' "$body" > "$out"
}

cl_size_words() {
    local n=$1
    if [ "$n" -lt 1024 ]; then
        cl_plural "$n" byte
    elif [ "$n" -lt 1048576 ]; then
        printf '%s KB' $(((n + 512) / 1024))
    else
        printf '%s.%s MB' $((n / 1048576)) $(((n % 1048576) * 10 / 1048576))
    fi
}

cl_count_lines() {
    local lines
    lines=$(($(wc -l < "$1")))
    [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ] && lines=$((lines + 1))
    printf '%s' "$lines"
}

# CL_DESC: "2 lines, 41 characters", with the start of the text for -s.
cl_describe_text() {
    local f=$1 lines chars first
    lines=$(cl_count_lines "$f")
    chars=$(($(wc -m < "$f")))
    CL_DESC="$(cl_plural "$lines" line), $(cl_plural "$chars" character)"
    if [ "$OPT_SILENT" -eq 1 ] && [ "$OPT_SECRET" -eq 0 ]; then
        first=$(head -n 1 "$f")
        if [ "${#first}" -gt 60 ]; then
            first="${first:0:60}…"
        elif [ "$lines" -gt 1 ]; then
            first="$first …"
        fi
        CL_DESC="$CL_DESC: $first"
    fi
}

# CL_DESC: "a picture (PNG, 1240 x 1754, 312 KB)" or "data (application/pdf, 2.1 MB)".
cl_describe_binary() {
    local f=$1 type=$2 size dims="" fmt
    size=$(($(wc -c < "$f")))
    if cl_have file; then
        dims=$(file -b "$f" 2> /dev/null | grep -oE '[0-9]+ ?x ?[0-9]+' | head -n 1 | sed -E 's/ ?x ?/ x /')
    fi
    case "$type" in
        image/*)
            fmt=$(printf '%s' "${type#image/}" | tr '[:lower:]' '[:upper:]')
            if [ -n "$dims" ]; then
                CL_DETAIL="$fmt, $dims, $(cl_size_words "$size")"
            else
                CL_DETAIL="$fmt, $(cl_size_words "$size")"
            fi
            CL_DESC="a picture ($CL_DETAIL)"
            ;;
        *)
            CL_DETAIL="$type, $(cl_size_words "$size")"
            CL_DESC="data ($CL_DETAIL)"
            ;;
    esac
}

cl_where() {
    local w=""
    case "$ROUTE_USED" in
        terminal) w=" through the terminal" ;;
        tmux) w=" through tmux" ;;
    esac
    [ "$OPT_PRIMARY" -eq 1 ] && w="$w to the primary selection"
    [ -n "$ROUTE_NOTES" ] && w="$w ($ROUTE_NOTES)"
    [ "$CMD_STATUS" -ne 0 ] && w="$w; the command stopped with status $CMD_STATUS"
    printf '%s' "$w"
}

cl_clear_delay() {
    if [ -n "$CLEAR_AFTER" ]; then
        printf '%s' "$CLEAR_AFTER"
    elif [ "$OPT_SECRET" -eq 1 ]; then
        printf '45'
    fi
}

# Copy the captured output (a text or a picture) and say what was copied.
cl_copy_output() {
    local out=$1 text type delay tail_msg=""
    cl_workdir
    if cl_has_nul "$out"; then
        if [ "$OPT_SECRET" -eq 1 ]; then
            cl_die "$EX_CL" "nothing copied: a secret is text, and this output is not"
        fi
        type=$(cl_mime "$out")
        cl_copy picture "$out" "$type" || cl_die "$EX_CL" "nothing copied: $ROUTE_NOTES"
        cl_describe_binary "$out" "$type"
        if [ "$OPT_QUOTE$OPT_CMDLINE$OPT_MARKDOWN$JOIN_SET" != 0000 ]; then
            CL_DESC="$CL_DESC, as it came (-c, -m, -Q and -j shape a text only)"
        fi
        delay=$(cl_clear_delay)
        if [ -n "$delay" ]; then
            cl_schedule_clear "$delay" "$out"
            tail_msg="; the clipboard is cleared in $delay s"
        fi
        cl_say_ok "copied $CL_DESC$(cl_where)$tail_msg"
        return 0
    fi
    text="$WORK/text"
    cl_shape "$out" "$text"
    if [ ! -s "$text" ]; then
        cl_nothing "$EX_EMPTY" "$(cl_what) printed only escape sequences or blank lines"
    fi
    if [ "$OPT_SECRET" -eq 1 ]; then
        cl_copy secret "$text" secret || cl_die "$EX_CL" "nothing copied: $ROUTE_NOTES"
    else
        cl_copy text "$text" text || cl_die "$EX_CL" "nothing copied: $ROUTE_NOTES"
    fi
    cl_describe_text "$text"
    delay=$(cl_clear_delay)
    if [ -n "$delay" ]; then
        cl_schedule_clear "$delay" "$text"
        case "$ROUTE_USED" in
            terminal | tmux) tail_msg="; the clipboard is emptied in $delay s, whatever it then holds" ;;
            *) tail_msg="; the clipboard is cleared in $delay s if it still holds it" ;;
        esac
    fi
    if [ "$OPT_SECRET" -eq 1 ]; then
        [ "$ROUTE_USED" = copyq ] && tail_msg="$tail_msg, and CopyQ keeps it out of its history"
        cl_say_ok "copied a secret of $(cl_plural "$(cl_count_lines "$text")" line)$(cl_where)$tail_msg"
    else
        cl_say_ok "copied $CL_DESC$(cl_where)$tail_msg"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# The modes
# ---------------------------------------------------------------------------

# The tee of the command's output: the screen and the file at once.
cl_tee() {
    local tty=0
    [ -t 1 ] && tty=1
    if cl_have perl; then
        perl -e "$CL_PERL_TEE" "$1" "$tty"
    else
        tee "$1"
    fi
}

cl_alias_hint() {
    # shellcheck disable=SC2016
    printf ' (an alias or a function of bash runs after: eval "$(cl --shell-init bash)")'
}

# Refuse a command that cannot run, with the status a shell would give.
cl_check_command() {
    local name=$1 kind
    case "$name" in
        */*)
            if [ -d "$name" ]; then
                cl_nothing "$EX_NOEXEC" "$name is a folder, not a command"
            elif [ ! -e "$name" ]; then
                cl_nothing "$EX_NOTFOUND" "no command named $name"
            elif [ ! -x "$name" ]; then
                cl_nothing "$EX_NOEXEC" "$name cannot be run (it is not executable)"
            fi
            ;;
        *)
            kind=$(type -t "$name" 2> /dev/null)
            case "$kind" in
                builtin | file) ;;
                *)
                    # The functions of cl itself never run in place of a command.
                    if ! type -P "$name" > /dev/null 2>&1; then
                        cl_nothing "$EX_NOTFOUND" "no command named $name$(cl_alias_hint)"
                    fi
                    ;;
            esac
            ;;
    esac
}

cl_after() {
    local status=$1 out=$2
    CMD_STATUS=$status
    # An output shown on the terminal without a final newline would run into
    # the line that follows.
    if [ "$OPT_SILENT" -eq 0 ] && [ "$OPT_SECRET" -eq 0 ] && [ -t 1 ] && [ -s "$out" ] &&
        [ -n "$(tail -c 1 "$out")" ] && ! cl_has_nul "$out"; then
        SHOWN_OPEN=1
    fi
    if [ "$status" -ne 0 ]; then
        case "$status" in
            129 | 130 | 131 | 137 | 143) cl_nothing "$status" "$(cl_what) was interrupted" ;;
        esac
        [ "$OPT_ALWAYS" -eq 1 ] || cl_nothing "$status" "$(cl_what) stopped with status $status"
    fi
    if [ ! -s "$out" ]; then
        local why
        if [ -n "$CMD_NAME" ]; then
            why="$CMD_NAME printed nothing; the clipboard keeps what it had"
        else
            why="nothing came through the pipe; the clipboard keeps what it had"
        fi
        if [ "$status" -ne 0 ]; then
            cl_nothing "$status" "$why"
        fi
        cl_nothing "$EX_EMPTY" "$why"
    fi
    cl_copy_output "$out"
    exit "$status"
}

cl_run() {
    local status out
    CMD_NAME=$1
    if [ -n "$GIVEN_LINE" ]; then
        CMD_LINE=$GIVEN_LINE
    else
        CMD_LINE=$(cl_quote_words "$@")
    fi
    cl_check_command "$1"
    cl_workdir
    out="$WORK/out"
    if [ "$OPT_SILENT" -eq 1 ] || [ "$OPT_SECRET" -eq 1 ]; then
        if [ "$OPT_STDERR" -eq 1 ]; then
            command "$@" > "$out" 2>&1
            status=$?
        else
            command "$@" > "$out"
            status=$?
        fi
    else
        if [ "$OPT_STDERR" -eq 1 ]; then
            command "$@" 2>&1 | cl_tee "$out"
            status=${PIPESTATUS[0]}
        else
            command "$@" | cl_tee "$out"
            status=${PIPESTATUS[0]}
        fi
    fi
    cl_after "$status" "$out"
}

cl_pipe() {
    local out
    CMD_LINE=$GIVEN_LINE
    CMD_NAME=${GIVEN_LINE%% *}
    cl_workdir
    out="$WORK/out"
    if [ "$OPT_SILENT" -eq 1 ] || [ "$OPT_SECRET" -eq 1 ]; then
        cat > "$out"
    else
        cl_tee "$out"
    fi
    cl_after "${GIVEN_STATUS:-0}" "$out"
}

cl_abspath() {
    local f=$1 dir base p
    if [ -d "$f" ]; then
        (cd "$f" && pwd -P)
        return
    fi
    dir=$(dirname "$f")
    base=$(basename "$f")
    p=$(cd "$dir" && pwd -P) || return 1
    [ "$p" = / ] && p=""
    printf '%s/%s\n' "$p" "$base"
}

# Percent-encoding of a path for a file:// address (RFC 3986): every byte
# but the letters, digits and - . _ ~ / becomes %XX.
cl_uri_escape() {
    local b ch out=""
    for b in $(printf '%s' "$1" | od -An -tx1 -v | tr 'a-f' 'A-F'); do
        case "$b" in
            2D | 2E | 2F | 5F | 7E | 3[0-9] | 4[1-9A-F] | 5[0-9A] | 6[1-9A-F] | 7[0-9A])
                printf -v ch '%b' "\\x$b"
                out=$out$ch
                ;;
            *) out="$out%$b" ;;
        esac
    done
    printf '%s' "$out"
}

cl_files() {
    local f abs n=0 names="" type delay tail_msg=""
    [ $# -gt 0 ] || cl_usage_error "-f needs at least one file"
    [ "$OPT_SECRET" -eq 0 ] || cl_usage_error "-S copies a text, not files"
    for f in "$@"; do
        [ -e "$f" ] || cl_die "$EX_CL" "nothing copied: no file named $f"
    done
    cl_workdir
    delay=$(cl_clear_delay)
    # One picture goes as the picture: it pastes into a message or a document.
    if [ $# -eq 1 ] && [ -f "$1" ]; then
        type=$(cl_mime "$1")
        case "$type" in
            image/*)
                cl_copy picture "$1" "$type" || cl_die "$EX_CL" "nothing copied: $ROUTE_NOTES"
                cl_describe_binary "$1" "$type"
                if [ -n "$delay" ]; then
                    cl_schedule_clear "$delay" "$1"
                    tail_msg="; the clipboard is cleared in $delay s"
                fi
                cl_say_ok "copied the picture $(basename "$1") ($CL_DETAIL)$(cl_where)$tail_msg"
                exit 0
                ;;
        esac
    fi
    : > "$WORK/uris"
    : > "$WORK/paths"
    printf 'copy' > "$WORK/gnome"
    for f in "$@"; do
        abs=$(cl_abspath "$f") || cl_die "$EX_CL" "nothing copied: cannot find where $f is"
        printf 'file://%s\r\n' "$(cl_uri_escape "$abs")" >> "$WORK/uris"
        printf '\nfile://%s' "$(cl_uri_escape "$abs")" >> "$WORK/gnome"
        if [ "$n" -eq 0 ]; then
            printf '%s' "$abs" >> "$WORK/paths"
        else
            printf '\n%s' "$abs" >> "$WORK/paths"
        fi
        n=$((n + 1))
        if [ "$n" -le 3 ]; then
            names="${names:+$names, }$(basename "$f")"
        fi
    done
    [ "$n" -gt 3 ] && names="$names and $((n - 3)) more"
    cl_copy files "$WORK/uris" files || cl_die "$EX_CL" "nothing copied: $ROUTE_NOTES"
    if [ -n "$delay" ]; then
        cl_schedule_clear "$delay" "$WORK/uris"
        tail_msg="; the clipboard is cleared in $delay s"
    fi
    cl_say_ok "copied $(cl_plural "$n" file): $names$(cl_where)$tail_msg"
    exit 0
}

# -o: what the clipboard holds, on standard output.
cl_paste() {
    local route types="" text_type="" image_type="" t tried=0
    cl_workdir
    for route in $(cl_routes_for read); do
        cl_valid_route "$route" || cl_usage_error "no route named $route"
        case "$route" in
            terminal | tmux) cl_die "$EX_CL" "the clipboard cannot be read through the terminal" ;;
        esac
        [ -n "$OPT_VIA" ] || cl_route_ready "$route" || continue
        tried=1
        case "$route" in
            wayland)
                local -a p=()
                [ "$OPT_PRIMARY" -eq 1 ] && p=(--primary)
                types=$(cl_with_timeout wl-paste ${p[@]+"${p[@]}"} --list-types 2> /dev/null)
                ;;
            copyq)
                if [ "$OPT_PRIMARY" -eq 1 ]; then
                    types=$(cl_with_timeout copyq selection '?' 2> /dev/null)
                else
                    types=$(cl_with_timeout copyq clipboard '?' 2> /dev/null)
                fi
                ;;
            x11)
                if cl_have xclip; then
                    local sel=clipboard
                    [ "$OPT_PRIMARY" -eq 1 ] && sel=primary
                    types=$(cl_with_timeout xclip -selection "$sel" -t TARGETS -o 2> /dev/null)
                else
                    types="text/plain"
                fi
                ;;
            macos) types="text/plain" ;;
        esac
        for t in $types; do
            case "$t" in
                text/plain* | UTF8_STRING | STRING | TEXT) [ -n "$text_type" ] || text_type=$t ;;
                image/*) [ -n "$image_type" ] || image_type=$t ;;
            esac
        done
        if [ -z "$types" ]; then
            cl_nothing "$EX_EMPTY" "the clipboard is empty"
        fi
        if [ -n "$text_type" ]; then
            cl_read_via "$route" > "$WORK/paste"
            cat "$WORK/paste"
            if [ -t 1 ] && [ -s "$WORK/paste" ] && [ -n "$(tail -c 1 "$WORK/paste")" ]; then
                printf '\n'
            fi
            exit 0
        fi
        if [ -n "$image_type" ]; then
            if [ -t 1 ]; then
                cl_die "$EX_CL" "the clipboard holds a picture ($image_type); send it to a file: cl -o > picture.${image_type#image/}"
            fi
            case "$route" in
                wayland) cl_with_timeout wl-paste ${p[@]+"${p[@]}"} --no-newline --type "$image_type" ;;
                copyq) cl_with_timeout copyq clipboard "$image_type" ;;
                x11) cl_with_timeout xclip -selection "${sel:-clipboard}" -t "$image_type" -o ;;
            esac
            exit $?
        fi
        cl_die "$EX_CL" "the clipboard holds neither text nor a picture (types: $(printf '%s' "$types" | tr '\n' ' '))"
    done
    [ "$tried" -eq 1 ] || cl_die "$EX_CL" "no clipboard can be read here; cl --doctor says more"
    cl_die "$EX_CL" "the clipboard could not be read"
}

cl_clear() {
    local route
    for route in $(cl_routes_for clear); do
        cl_valid_route "$route" || cl_usage_error "no route named $route"
        [ -n "$OPT_VIA" ] || cl_route_ready "$route" || continue
        if cl_clear_via "$route"; then
            ROUTE_USED=$route
            cl_say_ok "cleared the clipboard$(cl_where)"
            exit 0
        fi
    done
    cl_die "$EX_CL" "the clipboard could not be cleared; cl --doctor says more"
}

cl_version_of() {
    local v
    case "$1" in
        wl-copy) v=$(wl-copy --version 2> /dev/null | head -n 1) ;;
        xclip) v=$(xclip -version 2>&1 | head -n 1) ;;
        xsel) v=$(xsel --version 2>&1 | head -n 1) ;;
        copyq) v=$(copyq --version 2> /dev/null | head -n 1) ;;
        tmux) v=$(tmux -V 2> /dev/null) ;;
        perl) v=$(perl -e 'printf "perl %vd", $^V' 2> /dev/null) ;;
        file) v=$(file --version 2> /dev/null | head -n 1) ;;
        *) v=$1 ;;
    esac
    printf '%s' "${v:-$1}"
}

cl_doctor_route() {
    case "$1" in
        wayland) printf 'wayland (%s)' "$(cl_version_of wl-copy)" ;;
        copyq) printf 'copyq (%s, running)' "$(cl_version_of copyq)" ;;
        x11) if cl_have xclip; then printf 'x11 (%s)' "$(cl_version_of xclip)"; else printf 'x11 (%s)' "$(cl_version_of xsel)"; fi ;;
        macos) printf 'macos (pbcopy)' ;;
        tmux) printf 'tmux (%s)' "$(cl_version_of tmux)" ;;
        terminal) printf 'terminal (OSC 52, text up to 768 KB, if the terminal accepts it)' ;;
    esac
}

cl_doctor_line() {
    local label=$1 kind=$2 r ready="" first="" rest=""
    for r in $(cl_routes_for "$kind"); do
        cl_valid_route "$r" || continue
        cl_route_ready "$r" || continue
        ready="$ready $r"
    done
    for r in $ready; do
        if [ -z "$first" ]; then
            first=$(cl_doctor_route "$r")
        else
            rest="${rest:+$rest, }$r"
        fi
    done
    if [ -z "$first" ]; then
        printf '%-11s none reachable\n' "$label"
    elif [ -n "$rest" ]; then
        printf '%-11s %s; if it fails: %s\n' "$label" "$first" "$rest"
    else
        printf '%-11s %s\n' "$label" "$first"
    fi
}

# --doctor: what cl sees and which way a copy would go. Nothing changes.
cl_doctor() {
    local session="" term=""
    printf 'cl %s\n' "$CL_VERSION"
    if cl_in_ssh; then
        session="an SSH session"
    elif cl_is_macos; then
        session="macOS"
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        session="${session:+$session, }Wayland ($WAYLAND_DISPLAY)"
    fi
    if [ -n "${DISPLAY:-}" ]; then
        session="${session:+$session, }X11 ($DISPLAY)"
    fi
    [ -n "${XDG_CURRENT_DESKTOP:-}" ] && session="$session, desktop $XDG_CURRENT_DESKTOP"
    printf '%-11s %s\n' "Session" "${session:-no graphical session}"
    if [ -n "${HC_TERMINAL_ID:-}" ]; then
        term="Herdr terminal $HC_TERMINAL_ID, which accepts OSC 52"
    elif [ -n "${TERM_PROGRAM:-}" ]; then
        term="$TERM_PROGRAM"
    fi
    [ -n "${TMUX:-}" ] && term="${term:+$term, }inside tmux"
    if cl_tty_opens; then
        term="${term:+$term, }attached"
    else
        term="${term:+$term, }none attached (a script or an agent)"
    fi
    printf '%-11s %s\n' "Terminal" "$term"
    cl_doctor_line "Text" text
    cl_doctor_line "Pictures" picture
    cl_doctor_line "Files" files
    cl_doctor_line "Secrets" secret
    cl_doctor_line "Paste (-o)" read
    if [ "$COPYQ_STATE" = yes ]; then
        printf '%-11s %s\n' "History" "CopyQ keeps every copy but the secrets"
    fi
    if cl_have perl; then
        printf '%-11s %s\n' "Screen" "a picture is kept off the screen ($(cl_version_of perl))"
    else
        printf '%-11s %s\n' "Screen" "without perl, a picture would be shown as raw bytes"
    fi
    printf 'Nothing was changed.\n'
}

# ---------------------------------------------------------------------------
# The completion and the shell additions
# ---------------------------------------------------------------------------

cl_completion() {
    case "$1" in
        bash)
            cat << 'EOS'
# bash completion for cl, from "cl --completion bash".
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
_cl() {
    local cur prev i word offset=0
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    i=1
    while [ "$i" -lt "$COMP_CWORD" ]; do
        word=${COMP_WORDS[i]}
        case "$word" in
            --) offset=$((i + 1)); break ;;
            -j|--join|--via|--clear-after|--status|--line|--completion|--shell-init) i=$((i + 2)) ;;
            -f|--file) return 0 ;;
            -*) i=$((i + 1)) ;;
            *) offset=$i; break ;;
        esac
    done
    if [ "$offset" -eq 0 ] || [ "$offset" -ge "$COMP_CWORD" ]; then
        case "$prev" in
            --via) COMPREPLY=($(compgen -W "wayland copyq x11 macos tmux terminal" -- "$cur")); return 0 ;;
            --completion) COMPREPLY=($(compgen -W "bash zsh" -- "$cur")); return 0 ;;
            --shell-init) COMPREPLY=($(compgen -W "bash" -- "$cur")); return 0 ;;
            -j|--join|--clear-after|--status|--line) return 0 ;;
        esac
        if [ "$offset" -eq 0 ] && [[ $cur == -* ]]; then
            COMPREPLY=($(compgen -W "-s --silent -q --quiet -a --always -e --stderr -r --raw -p --primary -c --command -m --markdown -Q --quote -j --join -f --file -S --secret --clear-after -o --paste --clear --via --doctor --completion --shell-init --status --line -h --help -V --version --" -- "$cur"))
        else
            COMPREPLY=($(compgen -c -- "$cur"))
        fi
        return 0
    fi
    if declare -F _comp_command_offset > /dev/null 2>&1; then
        _comp_command_offset "$offset"
    elif declare -F _command_offset > /dev/null 2>&1; then
        _command_offset "$offset"
    fi
}
complete -F _cl -o bashdefault -o default cl
EOS
            ;;
        zsh)
            cat << 'EOS'
#compdef cl
# zsh completion for cl, from "cl --completion zsh".
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
_arguments -s -S \
    '(-s --silent)'{-s,--silent}'[do not show the output]' \
    '(-q --quiet)'{-q,--quiet}'[no confirmation line]' \
    '(-a --always)'{-a,--always}'[copy even when the command fails]' \
    '(-e --stderr)'{-e,--stderr}'[copy the error stream too]' \
    '(-r --raw)'{-r,--raw}'[copy the bytes as they came]' \
    '(-p --primary)'{-p,--primary}'[use the primary selection]' \
    '(-c --command)'{-c,--command}'[put the command line first]' \
    '(-m --markdown)'{-m,--markdown}'[wrap in a Markdown code block]' \
    '(-Q --quote)'{-Q,--quote}'[quote every line for the shell]' \
    '(-j --join)'{-j,--join}'[join the lines with a separator]:separator: ' \
    '(-S --secret)'{-S,--secret}'[a secret: never shown, cleared after 45 s]' \
    '--clear-after[seconds before the clipboard is cleared]:seconds: ' \
    '--via[the route to the clipboard]:route:(wayland copyq x11 macos tmux terminal)' \
    '(- *)'{-f,--file}'[put files on the clipboard]:*:file:_files' \
    '(- *)'{-o,--paste}'[print the clipboard]' \
    '(- *)--clear[empty the clipboard]' \
    '(- *)--doctor[say which way a copy would go]' \
    '(- *)--completion[print a completion script]:shell:(bash zsh)' \
    '(- *)--shell-init[print the shell additions]:shell:(bash)' \
    '(- *)'{-h,--help}'[show the help]' \
    '(- *)'{-V,--version}'[show the version]' \
    '(-)1:command: _command_names -e' \
    '*::arguments: _normal'
EOS
            ;;
        *) cl_usage_error "--completion takes bash or zsh" ;;
    esac
}

cl_shell_init() {
    case "$1" in
        bash) ;;
        *) cl_usage_error "--shell-init takes bash" ;;
    esac
    cat << 'EOS'
# The shell additions of cl, from "cl --shell-init bash".
# Author: Dr. Denys Dutykh (Mathematics Department, Khalifa University of
#         Science and Technology, Abu Dhabi, UAE).
#
# The function cl runs a first word that is an alias, a function or a builtin
# of this shell in the shell itself (cl ll, cl history 5), then hands its
# output and status to the program cl. Any other command goes to the program
# directly. The keys Ctrl+X Ctrl+W copy the command line being typed (not
# Ctrl+X Ctrl+C: the terminal turns Ctrl+C into an interrupt before bash sees it).
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    cl() {
        local i=1 word kind tmp status line errs=0
        local -a opts=()
        while [ "$i" -le "$#" ]; do
            word=${!i}
            case "$word" in
                --) i=$((i + 1)); break ;;
                -j|--join|--via|--clear-after|--status|--line)
                    opts+=("$word")
                    i=$((i + 1))
                    opts+=("${!i}")
                    i=$((i + 1))
                    ;;
                -f|--file|-o|--paste|--clear|--doctor|--completion|--shell-init|-h|--help|-V|--version)
                    command cl "$@"
                    return
                    ;;
                --stderr) errs=1; opts+=("$word"); i=$((i + 1)) ;;
                --*) opts+=("$word"); i=$((i + 1)) ;;
                -j*) opts+=("$word"); i=$((i + 1)) ;;
                -?*)
                    case "$word" in -*e*) errs=1 ;; esac
                    opts+=("$word")
                    i=$((i + 1))
                    ;;
                *) break ;;
            esac
        done
        if [ "$i" -gt "$#" ]; then
            command cl "$@"
            return
        fi
        word=${!i}
        kind=$(type -t -- "$word" 2> /dev/null)
        case "$kind" in
            alias | function | builtin | keyword) ;;
            *)
                command cl "$@"
                return
                ;;
        esac
        line=$(printf '%q ' "${@:i}")
        line=${line% }
        tmp=$(mktemp "${TMPDIR:-/tmp}/cl-shell.XXXXXX") || return 125
        if [ "$errs" -eq 1 ]; then
            eval "$line" > "$tmp" 2>&1
        else
            eval "$line" > "$tmp"
        fi
        status=$?
        command cl --status "$status" --line "$line" ${opts[@]+"${opts[@]}"} < "$tmp"
        status=$?
        rm -f "$tmp"
        return "$status"
    }
    if [[ $- == *i* ]]; then
        __cl_copy_line() {
            [ -n "$READLINE_LINE" ] || return 0
            if printf '%s' "$READLINE_LINE" | command cl -s -q; then
                printf '\r\033[K✓ copied the command line\n' >&2
            fi
        }
        bind -x '"\C-x\C-w": __cl_copy_line'
    fi
fi
EOS
}

# ---------------------------------------------------------------------------
# The help
# ---------------------------------------------------------------------------

cl_help() {
    cat << 'EOS'
cl: run a command and, when it succeeds, put what it printed on the clipboard.

Usage:
  cl [OPTIONS] COMMAND [ARGUMENTS...]   run COMMAND; copy its output if it succeeds
  COMMAND | cl [OPTIONS]                copy what comes through the pipe
  cl -f FILE...                         put files (or one picture) on the clipboard
  cl -o                                 print what the clipboard holds
  cl --clear                            empty the clipboard

The output appears as usual while it is copied; the final newlines and the
colour codes are left out of the copy, and one line on the terminal says what
was copied. A command that fails copies nothing: the clipboard keeps what it
had. Options of cl come before the command; "--" ends them.

Options:
  -s, --silent        do not show the output; the confirmation shows its start
  -q, --quiet         no confirmation line
  -a, --always        copy even when the command fails (its status is kept)
  -e, --stderr        copy the error stream too, in the order it came
  -r, --raw           copy the bytes as they came, colour codes and final newline
  -p, --primary       use the primary selection (middle click) instead
  -c, --command       put the command line before the output: "$ cmd"
  -m, --markdown      wrap the copy in a Markdown code block
  -Q, --quote         quote every line for the shell (paths with spaces)
  -j, --join SEP      join the lines with SEP, for example: cl -j ' ' ls
  -f, --file FILE...  put the files on the clipboard (Ctrl+V in Files,
                      Telegram or a mail attaches them); one picture goes as
                      the picture
  -S, --secret        a secret: never shown, kept out of the CopyQ history,
                      cleared after 45 s if the clipboard still holds it
      --clear-after SEC   clear the clipboard after SEC seconds
  -o, --paste         print the clipboard (a picture only into a file)
      --clear         empty the clipboard
      --via ROUTE     wayland, copyq, x11, macos, tmux or terminal
      --doctor        say which way a copy would go here; nothing changes
      --completion SHELL  print the completion for bash or zsh
      --shell-init bash   print the shell additions: aliases and functions
                      after cl, and Ctrl+X Ctrl+W copies the line being typed
                      (eval "$(cl --shell-init bash)" in ~/.bashrc)
      --status N      with a pipe: the status of the command that wrote it
      --line TEXT     with a pipe: its command line, for -c and the messages
  -h, --help          this help
  -V, --version       the version

Where the copy goes: in a Wayland session through wl-copy, else CopyQ, else
xclip or xsel; on macOS through pbcopy. In an SSH session, or with no desktop
at all, the terminal takes it (the OSC 52 sequence, text up to 768 KB) and puts
it on the clipboard of the machine where its window is: Herdr, Ghostty, kitty,
WezTerm and foot accept it, iTerm2 once allowed in its settings, and tmux
passes it on.

Exit status: that of the command, so "cl cmd && ..." reads as "cmd && ...";
1 when the command printed nothing (nothing is copied); 125 when cl itself
fails (an option, no clipboard, the clipboard program); 126 and 127 when the
command cannot run or does not exist; 130 after Ctrl+C.

Environment: CL_VIA (a route, as --via), CL_TIMEOUT (seconds a clipboard
program may take, 5), CL_TTY (where the OSC 52 sequence goes instead of the
terminal), NO_COLOR.

Examples:
  cl realpath notes.txt          the full path, ready for Ctrl+V
  cl git rev-parse HEAD          the commit, without its newline
  cl -cm julia --version         the command and its answer, as Markdown
  cl -Q realpath "My Papers"/*   quoted paths, safe to paste into a terminal
  cl !!                          the previous command, run again
  ls *.pdf | cl -j ', '          the names, on one line
  cl -f paper.pdf                the file itself, to attach
  cl pdftoppm -png -r 150 -f 3 -l 3 paper.pdf    page 3 as a picture
  cl -S cat ~/.config/service/token              a secret, for 45 s
EOS
}

cl_short_usage() {
    cat << 'EOS'
Usage: cl [OPTIONS] COMMAND [ARGUMENTS...]   (cl --help for more)
       COMMAND | cl [OPTIONS]
EOS
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cl_need_arg() {
    [ "$1" -ge 2 ] || cl_usage_error "$2 needs $3"
}

cl_number() {
    case "$2" in
        '' | *[!0-9]*) cl_usage_error "$1 needs a whole number of seconds or a status, not '$2'" ;;
    esac
}

cl_main() {
    local first rest
    while [ $# -gt 0 ]; do
        case "$1" in
            --)
                shift
                break
                ;;
            -s | --silent) OPT_SILENT=1 ;;
            -q | --quiet) OPT_QUIET=1 ;;
            -a | --always) OPT_ALWAYS=1 ;;
            -e | --stderr) OPT_STDERR=1 ;;
            -r | --raw) OPT_RAW=1 ;;
            -p | --primary) OPT_PRIMARY=1 ;;
            -c | --command) OPT_CMDLINE=1 ;;
            -m | --markdown) OPT_MARKDOWN=1 ;;
            -Q | --quote) OPT_QUOTE=1 ;;
            -S | --secret) OPT_SECRET=1 ;;
            -j | --join)
                cl_need_arg $# "$1" "a separator, for example: -j ' '"
                OPT_JOIN=$2
                JOIN_SET=1
                shift
                ;;
            --join=*)
                OPT_JOIN=${1#--join=}
                JOIN_SET=1
                ;;
            -j?*)
                OPT_JOIN=${1#-j}
                JOIN_SET=1
                ;;
            --clear-after)
                cl_need_arg $# "$1" "a number of seconds"
                cl_number "$1" "$2"
                CLEAR_AFTER=$2
                shift
                ;;
            --clear-after=*)
                CLEAR_AFTER=${1#--clear-after=}
                cl_number --clear-after "$CLEAR_AFTER"
                ;;
            --via)
                cl_need_arg $# "$1" "a route: wayland, copyq, x11, macos, tmux or terminal"
                OPT_VIA=$2
                shift
                ;;
            --via=*) OPT_VIA=${1#--via=} ;;
            --status)
                cl_need_arg $# "$1" "the status of the command"
                cl_number "$1" "$2"
                GIVEN_STATUS=$2
                shift
                ;;
            --status=*)
                GIVEN_STATUS=${1#--status=}
                cl_number --status "$GIVEN_STATUS"
                ;;
            --line)
                cl_need_arg $# "$1" "the command line"
                GIVEN_LINE=$2
                shift
                ;;
            --line=*) GIVEN_LINE=${1#--line=} ;;
            -f | --file)
                MODE=files
                shift
                break
                ;;
            -o | --paste) MODE="paste" ;;
            --clear) MODE=clear ;;
            --doctor) MODE=doctor ;;
            --completion)
                cl_need_arg $# "$1" "a shell: bash or zsh"
                MODE=completion
                SHELL_ARG=$2
                shift
                ;;
            --completion=*)
                MODE=completion
                SHELL_ARG=${1#--completion=}
                ;;
            --shell-init)
                cl_need_arg $# "$1" "a shell: bash"
                MODE=shellinit
                SHELL_ARG=$2
                shift
                ;;
            --shell-init=*)
                MODE=shellinit
                SHELL_ARG=${1#--shell-init=}
                ;;
            -h | --help) MODE=help ;;
            -V | --version) MODE=version ;;
            --*) cl_usage_error "unknown option $1" ;;
            -?)
                cl_usage_error "unknown option $1"
                ;;
            -?*)
                # A cluster of short options: -sq, -cm, -aej' '.
                first=${1:1:1}
                rest=${1:2}
                shift
                set -- "-$first" "-$rest" "$@"
                continue
                ;;
            *) break ;;
        esac
        shift
    done
    if [ -n "$OPT_VIA" ]; then
        cl_valid_route "$OPT_VIA" || cl_usage_error "no route named $OPT_VIA; the routes are wayland, copyq, x11, macos, tmux and terminal"
    fi
    case "$MODE" in
        help)
            cl_help
            exit 0
            ;;
        version)
            printf 'cl %s\n' "$CL_VERSION"
            exit 0
            ;;
        completion)
            cl_completion "$SHELL_ARG"
            exit 0
            ;;
        shellinit)
            cl_shell_init "$SHELL_ARG"
            exit 0
            ;;
        doctor)
            cl_doctor
            exit 0
            ;;
        paste) cl_paste ;;
        clear) cl_clear ;;
        files) cl_files "$@" ;;
    esac
    if [ $# -gt 0 ]; then
        [ -z "$GIVEN_STATUS" ] || cl_usage_error "--status goes with a pipe, not with a command"
        cl_run "$@"
    elif [ ! -t 0 ]; then
        cl_pipe
    else
        cl_short_usage >&2
        exit "$EX_CL"
    fi
}

cl_main "$@"
