# shellcheck shell=bash
# house style for every file the package ships: no em or en dashes, and terms spelled out.
# allowed short forms: URL, JSON, HTTP, SSH, API, SQL, iOS, MIT, and literal command names.

package_files() {
  (
    cd "$REPO_DIR" || exit 1
    for path in install.sh uninstall.sh Makefile bin README.md docs/PERMISSIONS.md docs/runtime-interface.md docs/allowlist-review.md allowlist lib levels tests docs/app-interfaces.md app copy docs/connector; do
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

# concierge-ops is operations material, not shipped, but it carries the same rules: terms
# spelled out (plus the operations shorthand that tends to creep in), and em-dashes sparingly.
test_concierge_documents_keep_the_house_style() {
  local em pattern hits
  em="$(printf '\342\200\224')"
  pattern='\b(ACLs?|OS|CLI|UID|GID|PID|TODO|FIXME|IP|DNS|UTC|ISO|PIN|OTP|VM|VPN|TCP|UDP|EOF|TTY|CPU|YAML|CI|UI|IDs?|OK|SLA|SLO|PA|MCP|KB|T&S|PTO|W-2|1099|FAQ|ETA|KPI|ASAP|FYI)\b|\be\.g\.|\bi\.e\.'
  hits="$(cd "$REPO_DIR" && find concierge-ops -type f | sort | while IFS= read -r file; do grep -n -E "$pattern" "$file" | sed "s|^|$file:|"; done)"
  assert_eq "" "$hits" "acronyms found in concierge-ops; spell the term out"
  # em-dashes sparingly: never more than one in a paragraph.
  hits="$(cd "$REPO_DIR" && find concierge-ops -name '*.md' | sort | while IFS= read -r file; do
    awk -v em="$em" -v file="$file" 'BEGIN { RS = "" } { n = gsub(em, em); if (n > 1) print file ": paragraph " NR " has " n }' "$file"
  done)"
  assert_eq "" "$hits" "more than one em-dash in a paragraph"
}
