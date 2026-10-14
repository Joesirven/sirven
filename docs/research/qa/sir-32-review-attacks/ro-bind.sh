#!/usr/bin/env bash
# run on the server host (not in the harness runner): the same host folder mounted twice, read-write at /rw and read-only at /ro.
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^sirven-harness-linux:' | head -1)"
avail="$(free -m | awk '/^Mem:/ {print $7}')"; [ "$avail" -ge 800 ] || { echo "STOP: $avail MB"; exit 9; }
rm -rf /tmp/sir32-mnt && mkdir -p /tmp/sir32-mnt && cp -r /tmp/sir32-src /tmp/sir32-mnt/pkg && chmod -R a+rwX /tmp/sir32-mnt
docker run --rm --label sir32-review=1 --network none --memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 --cap-drop NET_RAW \
  -v /tmp/sir32-mnt:/rw -v /tmp/sir32-mnt:/ro:ro "$IMAGE" bash -c '
  useradd -m agent
  echo "mounts: $(grep -E " /(rw|ro) " /proc/mounts | awk "{print \$2, \$4}" | tr "\n" ";")"
  echo "owner of /ro/pkg/lib/trust.sh: $(stat -c %U:%u /ro/pkg/lib/trust.sh); mode $(stat -c %a /ro/pkg/lib/trust.sh)"
  runuser -u agent -- bash -c "printf \"\ntouch /tmp/ROOT-RAN-ROBIND\n\" >> /rw/pkg/lib/kill_switch.sh && echo agent edited the library through /rw"
  cd /ro/pkg && bash install.sh revoke --all --yes --transport none > /tmp/o 2>&1; echo "revoke from /ro/pkg: exit $?"; head -3 /tmp/o | cut -c1-200
  [ -e /tmp/ROOT-RAN-ROBIND ] && echo "FINDING: root ran code the agent edited, from a read-only mount claim" || echo "agent code did not run"
' < /dev/null
rm -rf /tmp/sir32-mnt
