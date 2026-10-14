#!/usr/bin/env bash
# SIR-32, from the review (b1-kill-at-each-step). the installer process group is killed just before the Kth
# state-changing command of revoke --all, for every K there is. after each kill: (mode A) run revoke again and it must
# end in the clean end state; (mode B) a plain install must be refused (exit 2) and must change nothing about the
# account, whichever step the kill landed on: a revoke that stopped halfway is never undone by an install.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2
# the wrappers live where root looks for the tools (it resets its search path, so a folder put first on PATH is ignored): each
# real tool is copied to NAME.real and replaced by a script that counts the calls that change state and kills the installer's
# process group just before the Kth. a call that does not match passes straight through.
cat > /tmp/wrap.tpl <<'SCRIPT'
#!/bin/bash
# the name it was called by (pkill and pgrep are links to one file), the real tool beside it
name=$(basename "$0")
real=@REAL@
case "$name" in
  usermod | pkill) ;;
  rm) case "$*" in *agent-quiesce*) ;; *) exec -a "$name" "$real" "$@" ;; esac ;;
  mv) case "$*" in *.revoked*) ;; *) exec -a "$name" "$real" "$@" ;; esac ;;
  python3*) case "$*" in *kill_switch.py*remove-keys*|*access_control_snapshot.py*restore*) ;; *) exec -a "$name" "$real" "$@" ;; esac ;;
  *) exec -a "$name" "$real" "$@" ;;
esac
n=$(( $(cat /tmp/kcount 2>/dev/null || echo 0) + 1 )); echo "$n" > /tmp/kcount
if [ "$n" = "$(cat /tmp/ktarget 2>/dev/null)" ]; then
  echo "before call $n: $name $*" > /tmp/kkill.log
  kill -KILL -- "-$KPGID"; echo "group kill did not stop us (rc $?)" >> /tmp/kkill.log; sleep 5; exit 137
fi
exec -a "$name" "$real" "$@"
SCRIPT
for c in usermod pkill python3 rm mv; do
  real="$(readlink -f "$(command -v "$c")")"
  cp -p "$real" "$real.real"
  sed -e "s|@REAL@|$real.real|" /tmp/wrap.tpl > "$real.wrapped"
  chmod 755 "$real.wrapped"
  mv "$real.wrapped" "$real"
done

fresh() {
  bash /var/lib/sirven/package/uninstall.sh >/dev/null 2>&1
  rm -rf /home/agent /etc/sirven /var/lib/sirven /var/log/sirven /srv/app; userdel agent >/dev/null 2>&1; groupdel agent >/dev/null 2>&1
  mkdir -p /srv/app && echo f > /srv/app/f
  bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1 || echo "FRESH INSTALL FAILED"
  mkdir -p /tmp/k && [ -f /tmp/k/id ] || ssh-keygen -q -t ed25519 -N '' -f /tmp/k/id
  cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys; chown agent:agent /home/agent/.ssh/authorized_keys
  setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
  sleep 0.3
}
state() {
  echo "locked=$(getent shadow agent | cut -d: -f2 | cut -c1) expire='$(getent shadow agent | cut -d: -f8)' shell=$(getent passwd agent | cut -d: -f7 | sed 's|.*/||') procs=$(pgrep -u agent | wc -l) keys=$([ -e /home/agent/.ssh/authorized_keys ] && echo y || echo n) acl=$(getfacl -p /srv/app 2>/dev/null | grep -c user:agent) record=$(ls /etc/sirven/grants 2>/dev/null | tr '\n' ',') marker=$([ -e /var/lib/sirven/agent-quiesce.json ] && echo y || echo n)"
}
revoke_killing() {  # K
  echo 0 > /tmp/kcount; echo "$1" > /tmp/ktarget; rm -f /tmp/kkill.log
  setsid -w bash -c 'export KPGID=$$; exec bash install.sh revoke --all --yes --transport none' > /tmp/rev.out 2>&1
  REV_STATUS=$?
}
revoke_plain() { echo 0 > /tmp/ktarget; bash install.sh revoke --all --yes --transport none > /tmp/rev2.out 2>&1; REV2=$?; }

echo "== clean run =="
fresh; revoke_killing 0; echo "exit $REV_STATUS: $(state)"; world_accounts | grep -v '^agent' > /tmp/clean.accounts; world_acls /srv > /tmp/clean.acls
total="$(cat /tmp/kcount)"; echo "wrapped calls in a clean run: $total"
[ "$total" -ge 6 ] && pass "the sweep wraps $total state-changing calls in a clean run" || fail "the sweep wraps only $total calls: the wrappers are not where root looks for the tools, so nothing is tested"

echo "== mode A: kill before call K, run revoke again =="
for k in $(seq 1 $((total + 1))); do
  fresh; revoke_killing "$k"
  killed="$(cat /tmp/kkill.log 2>/dev/null || echo 'not killed') [installer exit $REV_STATUS; audit: started=$(grep -c revoke_started /var/log/sirven/audit.jsonl) steps=$(grep -c '"operation": "revoke", "step"' /var/log/sirven/audit.jsonl) finished=$(grep -c revoke_finished /var/log/sirven/audit.jsonl)]"
  s1="$(state)"
  revoke_plain
  s2="$(state)"
  printf 'K=%s %s\n   killed:   %s\n   state:    %s\n   rerun:    exit %s -> %s\n' "$k" "" "$killed" "$s1" "$REV2" "$s2"
  [ "$REV2" = 0 ] || fail "K=$k: the rerun did not finish (exit $REV2)"
  case "$s2" in *"procs=0 keys=n acl=0 record=agent.json.revoked, marker=n") pass "K=$k: rerun ends in the clean end state" ;; *) fail "K=$k: rerun end state differs: $s2" ;; esac
done

echo "== mode B: kill before call K, then a plain install =="
for k in $(seq 1 $((total))); do
  fresh; revoke_killing "$k"
  s1="$(state)"
  out="$(bash install.sh --yes --level builder --transport none --path /srv/app 2>&1)"; st=$?
  s2="$(state)"
  printf 'K=%s state: %s\n   plain install exit %s -> %s\n' "$k" "$s1" "$st" "$s2"
  if [ "$st" = 2 ] && [ "$s1" = "$s2" ] && grep -q 'was cut off by the kill switch' <<< "$out"; then
    pass "K=$k: a plain install is refused (exit 2) and changes nothing"
  else
    fail "K=$k: a plain install after a stopped revoke: exit $st, before [$s1], after [$s2]"
  fi
done

finish
