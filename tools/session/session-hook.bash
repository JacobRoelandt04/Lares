# session-hook.bash -- the terminal half of session restore (docs/session.md, docs/contracts/session.md).
#
# Install (the user's own step; ~/.bashrc is theirs): source it LAST, after starship's init, e.g.
#
#     [ -f ~/.local/state/lares/shell/current/tools/session/session-hook.bash ] && \
#         . ~/.local/state/lares/shell/current/tools/session/session-hook.bash
#
# (`lares setup` prints the line and checks it.) It does two things, both with shell builtins only:
#
#   THE MARK. While a command runs, the line as it was TYPED stands in
#   $XDG_RUNTIME_DIR/lares-session/tty/pts-<n> (0600, tmpfs: the kind of its first word and of every command word in it,
#   an alias's value, the line); at the next prompt the file is emptied. A session
#   snapshot reads it beside /proc: /proc gives the real argv (what an alias expanded to), the mark gives the words a
#   shell needs to run it again (a pipeline, a function, `FOO=1 cmd`). No fork: PS0 runs it through bash 5.3's
#   `${ ...; }`; an older bash gets no mark and the snapshot falls back to the argv.
#
#   THE CLAIM. A terminal that session restore opened carries LARES_SESSION_TOKEN; its pending command is the file
#   $XDG_RUNTIME_DIR/lares-session/pending/<token> ("run" or "type" on the first line, the command after it). The first
#   shell to rename that file owns it (a nested shell finds none), and at its first prompt
#     run   the command is put in the history and evaluated in THIS shell (quit the program: a prompt);
#     type  the command is put in the history and written at the prompt, NOT executed: the prompt asks the terminal
#           for its status (ESC [ 5 n), the terminal's answer (ESC [ 0 n) arrives as a key, and the key's binding fills
#           the line. Nothing is injected into the tty, no remote control is used; a terminal that never answers leaves
#           an empty prompt with the command one Up away.
#
# It never runs anything the restore did not hand it, and never by itself: no token, no claim.

case $- in *i*) ;; *) return 0 2> /dev/null || exit 0 ;; esac
[ -n "${__LARES_SESSION_HOOK-}" ] && return 0
__LARES_SESSION_HOOK=1

__lares_sr_dir="${XDG_RUNTIME_DIR:-/run/user/$UID}/lares-session"
__lares_sr_mark_file=""
__lares_sr_marked=""
__lares_sr_lastnum=""
__lares_sr_cmd=""
__lares_sr_mode=""

# The tty's name, once (the one fork of this file, at the shell's start).
if [ -t 0 ]; then
    __lares_sr_tty=$(tty 2> /dev/null)
    case $__lares_sr_tty in
        /dev/pts/*)
            # The file is made here, 0600, once: every later write keeps its mode and costs no fork.
            if (umask 077; mkdir -p "$__lares_sr_dir/tty" && : > "$__lares_sr_dir/tty/pts-${__lares_sr_tty#/dev/pts/}") 2> /dev/null; then
                __lares_sr_mark_file="$__lares_sr_dir/tty/pts-${__lares_sr_tty#/dev/pts/}"
            fi ;;
    esac
    unset __lares_sr_tty
fi

# __lares_sr_write <text> -- the mark, by builtins. Line 1: what KIND of word the line starts with (bash's own `type -t`:
# alias, function, builtin, keyword, file, or nothing for `FOO=1 cmd`), then, tab-separated, a triple for every word of
# the line that names a command: the word, its kind, an alias's value. Line 2: the first word's alias value. The rest:
# the line. The restore re-runs a line by itself only when the word that stands for the RUNNING program is a program or
# an alias for one (a function may do anything after the program that is on screen); the triples are what lets it find
# that word in a chain (`cd repo; lg`: the cd is done, `lg` is an alias of the lazygit that runs).
__lares_sr_write() {
    [ -n "$__lares_sr_mark_file" ] || return 0
    local w=${1#"${1%%[![:space:]]*}"} kind alias="" map="" k a n=0
    local -a words
    w=${w%%[[:space:]]*}
    kind=${ builtin type -t -- "$w" 2> /dev/null; }
    [ "$kind" = alias ] && alias=${BASH_ALIASES[$w]-}
    IFS=$' \t\n;&|()' read -r -d '' -a words <<< "$1"
    for w in "${words[@]}"; do
        [ "$n" -lt 48 ] || break
        n=$((n + 1))
        case $w in '' | -* | *=*) continue ;; esac
        case $map in *$'\t'"$w"$'\t'*) continue ;; esac
        k=${ builtin type -t -- "$w" 2> /dev/null; }
        [ -n "$k" ] || continue
        a=""
        [ "$k" = alias ] && a=${BASH_ALIASES[$w]-}
        a=${a//[$'\t\n']/ }
        map+=$'\t'"$w"$'\t'"$k"$'\t'"$a"
    done
    printf '%s%s\n%s\n%s\n' "$kind" "$map" "${alias//$'\n'/ }" "$1" > "$__lares_sr_mark_file" 2> /dev/null
    __lares_sr_marked=1
}

# PS0: the line just read. A line bash did not keep (HISTCONTROL=ignorespace) leaves the history number where it was:
# then `history 1` is an OLDER line and the mark says nothing.
__lares_sr_mark() {
    [ -n "$__lares_sr_mark_file" ] || return 0
    local h num
    h=${ HISTTIMEFORMAT='' builtin history 1; }
    [[ $h =~ ^[[:space:]]*([0-9]+)\*?[[:space:]]+(.*)$ ]] || return 0
    num=${BASH_REMATCH[1]}
    if [ "$num" = "$__lares_sr_lastnum" ]; then
        : > "$__lares_sr_mark_file" 2> /dev/null
        return 0
    fi
    __lares_sr_lastnum=$num
    __lares_sr_write "${BASH_REMATCH[2]}"
}

# bash redraws the prompt's last line after a `bind -x` command, which sends the status query AGAIN: the answer to that
# one (and to every later redraw of this prompt: a resize, Ctrl+L) must be swallowed, so the key is re-bound to an empty
# macro -- unbound, readline would insert the answer's last letter ("n") into the line; still bound to this function, the
# two would ping-pong for ever. The empty macro stays for the shell's life: a late answer never prints.
__lares_sr_fill() {
    READLINE_LINE=$__lares_sr_cmd
    READLINE_POINT=${#READLINE_LINE}
    bind '"\e[0n": ""' 2> /dev/null
    __lares_sr_cmd=""
}

# The prompt hook: empties the mark; at the FIRST prompt of a restored terminal, carries the claim out.
__lares_sr_prompt() {
    local __lares_sr_status=$?
    if [ -n "$__lares_sr_marked" ]; then
        __lares_sr_marked=""
        : > "$__lares_sr_mark_file" 2> /dev/null
    fi
    if [ -n "$__lares_sr_mode" ]; then
        local mode=$__lares_sr_mode
        __lares_sr_mode=""
        case $mode in
            run)
                local cmd=$__lares_sr_cmd
                __lares_sr_cmd=""
                builtin history -s -- "$cmd"
                __lares_sr_write "$cmd"
                printf '\e]2;%s\a' "${cmd//[[:cntrl:]]}"
                eval "$cmd"
                __lares_sr_marked=""
                : > "$__lares_sr_mark_file" 2> /dev/null ;;
            type)
                builtin history -s -- "$__lares_sr_cmd"
                bind -x '"\e[0n": __lares_sr_fill' 2> /dev/null && PS1+='\[\e[5n\]' ;;
        esac
    fi
    return $__lares_sr_status
}

# The claim: an atomic rename, so exactly one shell gets the command.
if [ -n "${LARES_SESSION_TOKEN-}" ]; then
    case $LARES_SESSION_TOKEN in
        *[!A-Za-z0-9_-]*) ;;
        *)
            if mv -n -- "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN" "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$" 2> /dev/null \
                && [ -f "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$" ]; then
                {
                    IFS= read -r __lares_sr_mode
                    __lares_sr_cmd=$(cat)
                } < "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$"
                rm -f -- "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$"
                case $__lares_sr_mode in run | type) ;; *) __lares_sr_mode="" ;; esac
                [ -n "$__lares_sr_cmd" ] || __lares_sr_mode=""
            fi ;;
    esac
    unset LARES_SESSION_TOKEN
fi

# Last in PROMPT_COMMAND: after starship has rebuilt PS1 (the status query is appended to THAT prompt).
PROMPT_COMMAND=("${PROMPT_COMMAND[@]}" "__lares_sr_prompt")

# PS0, without a fork (bash 5.3). An older bash keeps its PS0 and the snapshot reads /proc alone.
if [ -n "$__lares_sr_mark_file" ] && { [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; }; then
    PS0+='${ __lares_sr_mark; }'
fi
