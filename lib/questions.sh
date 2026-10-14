# shellcheck shell=bash
# the setup questions: at most two, asked before the plan is built, each with its default shown.
#
#   1. access level   default observer, the smallest level
#   2. path to grant  default the current folder when the level's policy accepts it, else none
#
# everything else has a default and a flag. a value set by a flag or an environment variable is
# never asked. with --yes, or with no terminal to ask on (a pipeline runner has none), nothing is
# asked: the level is observer and no path is granted, because a grant needs a person to name
# the path.
#
# environment overrides, for curl | bash in automation:
#   SIRVEN_LEVEL        observer, builder, or operator
#   SIRVEN_PATH         paths to grant, separated by colons, or none
#   SIRVEN_YES          1 or yes: same as --yes
#   SIRVEN_INTERACTIVE  yes asks on standard input even when it is not a terminal (tests use
#                       this), no never asks
#
# reads: ROOT_DIR, OPERATING_SYSTEM, PACKAGE, SERVICE_USER, LEVEL, GRANT_PATHS, ASSUME_YES
# sets:  LEVEL, GRANT_PATHS, SETUP_MODE (flags, asked, or defaults), SETUP_REASON

SETUP_DEFAULT_LEVEL=observer

# _setup_terminal: print where to read answers from (stdin or tty), or nothing when nothing may
# be asked. curl | bash has a pipe on standard input but a person at the terminal, so the
# controlling terminal is used when standard error is one and it can be opened.
_setup_terminal() {
  case "${SIRVEN_INTERACTIVE:-}" in
    yes) printf 'stdin'; return 0 ;;
    no) return 0 ;;
  esac
  if [ -t 0 ]; then
    printf 'stdin'
  elif [ -t 2 ] && (: < /dev/tty) 2>/dev/null; then
    printf 'tty'
  fi
}

# _setup_valid_level LEVEL: true for a level that has a file in levels/.
_setup_valid_level() {
  case "$1" in
    observer | builder | operator) return 0 ;;
  esac
  return 1
}

# _setup_grantable LEVEL PATH: true when the grant compiler would accept PATH at LEVEL.
_setup_grantable() {
  python3 "$ROOT_DIR/lib/grant_compiler.py" record --level "$ROOT_DIR/levels/$1.json" \
    --user "$SERVICE_USER" --os "$OPERATING_SYSTEM" --package "$PACKAGE" --path "$2" \
    > /dev/null 2>&1
}

# _setup_default_path LEVEL: the current folder when it can be granted at LEVEL, else nothing.
_setup_default_path() {
  local here
  here="$(pwd -P 2>/dev/null)" || return 0
  if _setup_grantable "$1" "$here"; then
    printf '%s' "$here"
  fi
}

# _setup_paths_from_text TEXT: GRANT_PATHS from colon separated TEXT; none or empty means none.
_setup_paths_from_text() {
  local rest="$1" path
  GRANT_PATHS=()
  [ "$rest" = none ] && return 0
  while [ -n "$rest" ]; do
    path="${rest%%:*}"
    if [ "$path" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
    if [ -n "$path" ]; then GRANT_PATHS[${#GRANT_PATHS[@]}]="$path"; fi
  done
}

# _setup_ask PROMPT DEFAULT: print the numbered prompt on standard error and read one answer into
# SETUP_ANSWER, the default when the answer is empty or the input has ended.
_setup_ask() {
  local prompt="$1" default="$2"
  printf '%s/%s %s [%s]: ' "$SETUP_NUMBER" "$SETUP_COUNT" "$prompt" "$default" >&2
  SETUP_ANSWER=""
  # a terminal echoes the newline; a pipe or the end of input does not.
  if ! IFS= read -r SETUP_ANSWER <&3 || [ "$SETUP_TERMINAL" != terminal ]; then
    printf '\n' >&2
  fi
  SETUP_ANSWER="$(printf '%s' "$SETUP_ANSWER" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$SETUP_ANSWER" ] || SETUP_ANSWER="$default"
}

_setup_ask_level() {
  local tries=0
  say "  observer  read only. sees files, changes nothing." >&2
  say "  builder   reads and writes inside the path. builds and tests there." >&2
  say "  operator  builder, plus restarts the services you list. never root." >&2
  while :; do
    _setup_ask "access level" "$SETUP_DEFAULT_LEVEL"
    SETUP_ANSWER="$(lowercase "$SETUP_ANSWER")"
    if _setup_valid_level "$SETUP_ANSWER"; then
      LEVEL="$SETUP_ANSWER"
      return 0
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || usage_error "access level must be observer, builder, or operator"
    say "  type observer, builder, or operator, or press enter for $SETUP_DEFAULT_LEVEL." >&2
  done
}

_setup_ask_path() {
  local default tries=0 shown
  default="$(_setup_default_path "$LEVEL")"
  shown="${default:-none}"
  say "  the one folder the agent may use at $LEVEL. add more later with --path. none grants nothing." >&2
  while :; do
    _setup_ask "path to grant" "$shown"
    # shellcheck disable=SC2088 # the quoted "~/" is a literal prefix the person typed, matched on purpose
    case "$SETUP_ANSWER" in
      none) GRANT_PATHS=(); return 0 ;;
      "~") SETUP_ANSWER="$HOME" ;;
      "~/"*) SETUP_ANSWER="$HOME/${SETUP_ANSWER#"~/"}" ;;
    esac
    case "$SETUP_ANSWER" in
      /*)
        if _setup_grantable "$LEVEL" "$SETUP_ANSWER"; then
          GRANT_PATHS=("$SETUP_ANSWER")
          return 0
        fi
        say "  $SETUP_ANSWER cannot be granted at $LEVEL: it is too broad, or holds keys or the package's own files." >&2
        ;;
      *) say "  type an absolute path like /home/you/code/app, or none." >&2 ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || usage_error "no grantable path given; rerun with --path PATH or answer none"
  done
}

# setup_from_environment: answers from SIRVEN_* for anything a flag left open, checked before
# preflight so a bad value stops the run first.
setup_from_environment() {
  if [ -z "$LEVEL" ] && [ -n "${SIRVEN_LEVEL:-}" ]; then
    _setup_valid_level "$SIRVEN_LEVEL" || usage_error "SIRVEN_LEVEL must be observer, builder, or operator, got '$SIRVEN_LEVEL'"
    LEVEL="$SIRVEN_LEVEL"
  fi
  if [ "$PATHS_GIVEN" = no ] && [ -n "${SIRVEN_PATH:-}" ]; then
    _setup_paths_from_text "$SIRVEN_PATH"
    PATHS_GIVEN=yes
  fi
  case "${SIRVEN_INTERACTIVE:-}" in
    '' | yes | no) ;;
    *) usage_error "SIRVEN_INTERACTIVE must be yes or no, got '$SIRVEN_INTERACTIVE'" ;;
  esac
  case "$(lowercase "${SIRVEN_YES:-}")" in
    1 | yes | true) ASSUME_YES=yes ;;
  esac
}

# setup_questions: fill LEVEL and GRANT_PATHS left open by flags and the environment, from
# answers, else from defaults. install only; revoke asks nothing.
setup_questions() {
  local terminal="" asked=no
  SETUP_MODE=flags
  SETUP_REASON=""

  if [ "$COMMAND" != install ] || { [ -n "$LEVEL" ] && [ "$PATHS_GIVEN" = yes ]; }; then
    LEVEL="${LEVEL:-$SETUP_DEFAULT_LEVEL}"
    return 0
  fi

  if [ "$ASSUME_YES" = yes ]; then
    SETUP_REASON="--yes"
  else
    terminal="$(_setup_terminal)"
    [ -n "$terminal" ] || SETUP_REASON="no terminal to ask on"
  fi

  if [ -n "$terminal" ]; then
    SETUP_TERMINAL=terminal
    if [ "$terminal" = tty ]; then
      exec 3< /dev/tty
    else
      [ -t 0 ] || SETUP_TERMINAL=pipe
      exec 3<&0
    fi
    SETUP_NUMBER=0
    SETUP_COUNT=0
    [ -n "$LEVEL" ] || SETUP_COUNT=$((SETUP_COUNT + 1))
    [ "$PATHS_GIVEN" = yes ] || SETUP_COUNT=$((SETUP_COUNT + 1))
    say "$PACKAGE setup: press enter to accept the default in brackets." >&2
    if [ -z "$LEVEL" ]; then SETUP_NUMBER=$((SETUP_NUMBER + 1)); _setup_ask_level; asked=yes; fi
    if [ "$PATHS_GIVEN" = no ]; then SETUP_NUMBER=$((SETUP_NUMBER + 1)); _setup_ask_path; PATHS_GIVEN=yes; asked=yes; fi
    exec 3<&-
    say "" >&2
    [ "$asked" = no ] || SETUP_MODE=asked
    return 0
  fi

  # shellcheck disable=SC2034 # the documented output in the header above; no file in this repository reads it yet
  SETUP_MODE=defaults
  LEVEL="${LEVEL:-$SETUP_DEFAULT_LEVEL}"
  say "using defaults ($SETUP_REASON): level $LEVEL, paths $(setup_describe_paths)." >&2
  say "  to choose: --level LEVEL --path PATH, or SIRVEN_LEVEL and SIRVEN_PATH." >&2
}

# setup_describe_paths: the granted paths for the plan header, or what having none means.
setup_describe_paths() {
  local index=0 text=""
  if [ "${#GRANT_PATHS[@]}" -eq 0 ]; then
    printf 'none (the agent can use only its own home)'
    return 0
  fi
  while [ "$index" -lt "${#GRANT_PATHS[@]}" ]; do
    [ -z "$text" ] || text="$text, "
    text="$text${GRANT_PATHS[index]}"
    index=$((index + 1))
  done
  printf '%s' "$text"
}
