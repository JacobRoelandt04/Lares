# sudo-offer.bash -- when a command in the terminal fails for want of root, offer to run it again with sudo: one key.
#
# Install (the user's own step; ~/.bashrc is theirs): source it AFTER starship's init, e.g.
#
#     eval "$(starship init bash)"
#     [ -f ~/.config/quickshell/tools/shell/sudo-offer.bash ] && . ~/.config/quickshell/tools/shell/sudo-offer.bash
#
# It never runs anything by itself: it offers, never auto-runs. After a failed command whose OUTPUT says it was
# refused for permissions ("Permission denied", "Operation not permitted", pacman's "unless you are root", ...) it prints
#
#     ↳ sudo cat /etc/shadow      y run it with sudo · any other key: no
#
# and reads ONE key: `y` runs exactly the line shown (sudo asks as it always does -- the face scan, then the password);
# any other printable key is handed back to the prompt as if it had been typed there (so a user who goes on typing loses
# nothing), Enter / Esc / Ctrl+C just dismiss.
#
# How it sees the output: kitty's own record of the last command's output (`kitten @ get-text --extent last_cmd_output`,
# kitty's shell integration -- on by default -- marks where each command's output starts and ends). Outside kitty, or
# when kitty has no record, the only signal left is exit status 126 ("found but not executable"). Nothing is captured,
# no stream is redirected: a program's stderr stays a terminal (progress bars, colours).
#
# Never offered: a line that already asks for root (sudo, doas, pkexec, run0, su), Ctrl+C (130), a line bash did not keep
# in its history (HISTCONTROL=ignorespace: then the line we could re-run might be an older one), an alias / function /
# builtin as the command (root's shell does not have them), an ssh "Permission denied (publickey...)".
# A compound line (a pipe, a list, a redirection, a substitution) is offered as `sudo bash -c '<line>'`: the part that
# needed root may be the redirection, which the user's own shell performs (`echo x > /etc/foo`).

case $- in *i*) ;; *) return 0 2> /dev/null || exit 0 ;; esac
[ -n "${__SUDO_OFFER_LOADED-}" ] && return 0
__SUDO_OFFER_LOADED=1

__SUDO_OFFER_RE='permission denied|operation not permitted|unless you are root|must be (run as )?root|are you root\?|need(s)? to be root|requires (root|superuser) privileges?|only root can|interactive authentication required|you must be the superuser'
__SUDO_OFFER_NOT_RE='permission denied \((publickey|password|keyboard-interactive)|permission denied, please try again'
__sudo_offer_lastnum=""
__sudo_offer_seen=""

# __sudo_offer_kitten <args...> -- `kitten @ <args>` with a deadline. Without a remote-control socket (kitty.conf has no
# listen_on: the usual case) kitten talks to kitty over the TERMINAL, which only the foreground process group may do. A plain
# `timeout` puts its command in a process group of its own: the terminal stops kitten (SIGTTOU), timeout's TERM wakes it only
# for it to be stopped again restoring the terminal, and timeout waits for ever -- the prompt never came back and Ctrl+C reached
# nothing (`pacman -S` in kitty). --foreground keeps it in the shell's group; -k ends a stuck one.
__sudo_offer_kitten() { timeout --foreground -k 1 2 kitten @ "$@"; }

# __sudo_offer_runline <line> -> the command that would run, or nothing when the line is not one to offer.
__sudo_offer_runline() {
    local line="$1" first
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || return 1
    first="${line%%[[:space:]]*}"
    case "$first" in sudo|doas|pkexec|run0|su|*=*) return 1 ;; esac
    case "$line" in
        *[\|\;\&\<\>\`]*|*'$('*)
            printf "sudo bash -c %q" "$line" ;;
        *)
            [ "$(type -t -- "$first" 2> /dev/null)" = file ] || return 1
            printf 'sudo %s' "$line" ;;
    esac
}

# __sudo_offer_refused <status> -> 0 when the last command's output (or, without one, its status) says "no permission".
__sudo_offer_refused() {
    local st="$1" out=""
    if [ -n "${KITTY_WINDOW_ID-}" ] && command -v kitten > /dev/null 2>&1; then
        out=$(__sudo_offer_kitten get-text --extent last_cmd_output 2> /dev/null | tail -n 40)
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | grep -qiE -- "$__SUDO_OFFER_NOT_RE" && return 1
        printf '%s\n' "$out" | grep -qiE -- "$__SUDO_OFFER_RE"
        return
    fi
    [ "$st" = 126 ]
}

__sudo_offer_precmd() {
    local st="${1-$?}" num line run k rest
    num=$(HISTTIMEFORMAT='' history 1 | awk '{print $1}')
    if [ -z "${__sudo_offer_seen-}" ] || [ "$num" = "$__sudo_offer_lastnum" ]; then
        __sudo_offer_seen=1; __sudo_offer_lastnum="$num"; return "$st"      # the first prompt, or no new history line
    fi
    __sudo_offer_lastnum="$num"
    case "$st" in 0|130) return "$st" ;; esac
    line=$(HISTTIMEFORMAT='' history 1 | sed -E 's/^ *[0-9]+\*? *//')
    run=$(__sudo_offer_runline "$line") || return "$st"
    __sudo_offer_refused "$st" || return "$st"
    printf '\e[2m↳\e[0m %s      \e[2my run it with sudo · any other key: no\e[0m' "$run"
    IFS= read -rsn1 k
    printf '\r\e[2K'
    if [ "$k" = y ] || [ "$k" = Y ]; then
        history -s "$run"
        __sudo_offer_lastnum=$(HISTTIMEFORMAT='' history 1 | awk '{print $1}')
        printf '%s\n' "$run"
        eval "$run"
        return $?
    fi
    if [ "$k" = $'\e' ]; then
        IFS= read -rsn8 -t 0.02 rest       # the rest of an escape sequence (an arrow key) is not the prompt's
    elif [ -n "$k" ] && [[ "$k" == [[:print:]] ]] && [ -n "${KITTY_WINDOW_ID-}" ]; then
        printf '%s' "$k" | __sudo_offer_kitten send-text --stdin > /dev/null 2>&1
    fi
    return "$st"
}

if declare -F starship_precmd > /dev/null; then
    # starship runs its prompt command itself and hands it the user's status (STARSHIP_CMD_STATUS) through this hook.
    if [ -n "${starship_precmd_user_func-}" ] && [ "$starship_precmd_user_func" != __sudo_offer_starship ]; then
        __sudo_offer_chain="$starship_precmd_user_func"
    fi
    __sudo_offer_starship() {
        __sudo_offer_precmd "${STARSHIP_CMD_STATUS:-0}"
        [ -n "${__sudo_offer_chain-}" ] && "$__sudo_offer_chain"
        return 0
    }
    starship_precmd_user_func=__sudo_offer_starship
else
    PROMPT_COMMAND="__sudo_offer_precmd \$?${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
