#!/usr/bin/env bash
# run one attack script (or all of them) in a throwaway container, the way the harness scenarios run: the repository mounted
# read only at /src and copied to /srv/pkg, no network, removed afterwards. never touches this machine.
#   bash docs/research/qa/sir-1-33-review-attacks/run.sh t1-key-file-trust.sh
#   bash docs/research/qa/sir-1-33-review-attacks/run.sh          (all of them)
# exit status: 0 when every attack script's checks passed (each script ends in 'finish'), 1 when one did not.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/../../../.." && pwd)"
ENGINE="${SIRVEN_HARNESS_ENGINE:-docker}"
image="sirven-harness-linux:$(shasum "$REPO_DIR/tests/harness/Dockerfile.linux" | cut -c1-12)"
"$ENGINE" image inspect "$image" >/dev/null 2>&1 || "$ENGINE" build -q -t "$image" -f "$REPO_DIR/tests/harness/Dockerfile.linux" "$REPO_DIR/tests/harness" >/dev/null || exit 2
failed=0
if [ "$#" -gt 0 ]; then scripts=("$@"); else scripts=(t[0-9]-*.sh); fi
for script in "${scripts[@]}"; do
  printf '\n##### %s\n' "$script"
  "$ENGINE" run --rm --network none --memory 256m --pids-limit 256 --cap-drop NET_RAW -v "$REPO_DIR":/src:ro "$image" \
    bash -c 'cp -r /src /srv/pkg && SRC=/srv/pkg exec bash "$0"' "/src/docs/research/qa/sir-1-33-review-attacks/$script" < /dev/null || failed=$((failed + 1))
done
printf '\n%s attack scripts, %s with a failed check\n' "${#scripts[@]}" "$failed"
[ "$failed" -eq 0 ]
