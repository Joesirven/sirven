#!/bin/sh
# a stand-in for the Tailscale command: logs every call, answers status from a fixture, and
# fails or stalls on request. it never touches a real tailnet.
printf '%s\n' "$*" >> "$FAKE_TAILSCALE_LOG"
echo "Warning: client version \"1.0\" != tailscaled server version \"1.1\"" >&2
case "$1" in
  status) cat "$FAKE_TAILSCALE_STATUS" ;;
  *)
    if [ -n "$FAKE_TAILSCALE_FAIL" ]; then echo "$FAKE_TAILSCALE_FAIL" >&2; exit 1; fi
    if [ -n "$FAKE_TAILSCALE_STALL" ]; then sleep 5; fi
    ;;
esac
