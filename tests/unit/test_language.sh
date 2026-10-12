# shellcheck shell=bash
# house style for every file the package ships: no em or en dashes, and terms spelled out.
# allowed short forms: URL, JSON, HTTP, SSH, API, SQL, iOS, MIT, and literal command names.

package_files() {
  (
    cd "$REPO_DIR" || exit 1
    for path in install.sh uninstall.sh Makefile bin README.md docs/PERMISSIONS.md docs/connector lib levels tests; do
      [ -e "$path" ] && find "$path" -type f
    done
  ) | grep -v '^tests/unit/test_language.sh$' | sort
}

test_no_em_or_en_dashes() {
  local em en hits
  em="$(printf '\342\200\224')"
  en="$(printf '\342\200\223')"
  hits="$(cd "$REPO_DIR" && package_files | while IFS= read -r file; do grep -n -e "$em" -e "$en" "$file" | sed "s|^|$file:|"; done)"
  assert_eq "" "$hits" "em or en dashes found"
}

test_no_acronyms() {
  local pattern hits
  pattern='\b(ACLs?|OS|CLI|UID|GID|PID|TODO|FIXME|IP|DNS|UTC|ISO|PIN|OTP|VM|VPN|TCP|UDP|EOF|TTY|CPU|YAML|CI|UI|IDs?|OK)\b|\be\.g\.|\bi\.e\.'
  hits="$(cd "$REPO_DIR" && package_files | while IFS= read -r file; do grep -n -E "$pattern" "$file" | sed "s|^|$file:|"; done)"
  assert_eq "" "$hits" "acronyms found; spell the term out"
}
