# shellcheck shell=bash
# bash 3.2 is the floor (macos /bin/bash), and only newer bash runs these tests on linux. so
# scan every shell file for features bash 3.2 lacks.

shell_files() {
  (
    cd "$REPO_DIR" || exit 1
    for path in install.sh uninstall.sh bin/sirven; do
      [ -f "$path" ] && printf '%s\n' "$path"
    done
    find lib tests components -type f -name '*.sh'
  ) | grep -v '^tests/unit/test_portability.sh$' | sort
}

# scan PATTERN WHAT: no shell file may match the extended regular expression PATTERN.
scan() {
  local hits
  hits="$(cd "$REPO_DIR" && shell_files | while IFS= read -r file; do grep -n -E -- "$1" "$file" | sed "s|^|$file:|"; done)"
  assert_eq "" "$hits" "$2 needs a bash newer than 3.2"
}

test_no_associative_arrays_or_array_readers() {
  scan '(declare|local|typeset) -[a-zA-Z]*A|\b(mapfile|readarray)\b' "associative arrays or mapfile"
}

test_no_case_changing_expansions() {
  scan '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^|,)' "\${name^} or \${name,}"
}

test_no_newer_redirections_or_coprocesses() {
  scan '&>>|\|&|\bcoproc\b|\{[A-Za-z_][A-Za-z0-9_]*\}[<>]' "&>>, |&, coproc, or {name}> redirection"
}

test_no_newer_builtins_and_options() {
  scan '(declare|local) -n\b|\[\[ -v |wait -n|shopt -s (globstar|lastpipe|autocd)|printf .*%\(|\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Za-z]\}|EPOCHSECONDS|EPOCHREALTIME|SRANDOM|BASHPID' \
    "namerefs, -v tests, wait -n, newer shopt options, printf time, \${name@op}, or newer variables"
}

test_no_negative_array_indexes_or_case_fallthrough() {
  scan '\[-[0-9]+\]\}|;;&|;&[[:space:]]*$' "negative array indexes or case fallthrough"
}

test_no_whole_array_expansion() {
  # "${name[@]}" on an empty array is an unbound variable error under set -u before bash 4.4.
  scan '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]' "expanding a whole array"
}
