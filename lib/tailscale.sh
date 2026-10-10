# shellcheck shell=bash
# tailscale transport, the first path. plan and documentation in the alpha cut: the plan writes
# a policy snippet you paste yourself and shows the one tailscale up it would run. nothing here
# runs against a real tailnet.
#
# interactive once: you log in to the tailscale admin console in a browser and make one tagged
# auth key. after that the machine joins with that key, and the agent client connects over
# SSH with its own key.
# reads: PREFIX, PACKAGE, CONFIG_DIR, SERVICE_USER

TAILSCALE_REASON="tailscale apply is plan output in the alpha cut; it is never run against a real tailnet yet"

tailscale_auth_key_file() {
  printf '%s/tailscale-auth-key' "$CONFIG_DIR"
}

# policy snippet in the tailscale policy file syntax, which allows comments.
tailscale_policy_snippet() {
  cat <<'END'
// paste into your tailnet policy file, merging with what is there.
// replace you@example.com with your own tailscale login.
// only your devices reach the agent, and only on the SSH port.
{
  "tagOwners": {
    "tag:agent": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["you@example.com"],
      "dst": ["tag:agent:22"]
    }
  ]
}
END
}

plan_tailscale() {
  local key_file staged
  key_file="$(rooted "$(tailscale_auth_key_file)")"
  plan_section "transport: tailscale"
  staged="$(tailscale_policy_snippet | stage_file tailscale-policy-snippet.hujson)"
  layout_write_file "write the tailnet policy snippet" "$CONFIG_DIR/tailscale-policy-snippet.hujson" 0644 "$staged" \
    "tag:agent, reachable only from your login, only on port 22"
  plan_owner "paste the policy snippet into your tailnet policy" \
    "tailscale admin console, access controls: merge $CONFIG_DIR/tailscale-policy-snippet.hujson and put your login in place of you@example.com."
  plan_owner "make one tagged auth key, once, in the browser" \
    "tailscale admin console, settings, keys: generate an auth key with tag:agent, pre-approved, not reusable.
save it as $(tailscale_auth_key_file), owned by root, mode 0600. this is the only interactive step." \
    "[ -f $key_file ] || tailscale status --self --json 2>/dev/null | grep -q '\"tag:agent\"'"
  plan_planonly "join the tailnet as a tagged device with that key" \
    "tailscale up --auth-key=file:$key_file --advertise-tags=tag:agent" \
    "$TAILSCALE_REASON" \
    "tailscale status --self --json 2>/dev/null | grep -q '\"tag:agent\"'"
  plan_planonly "remove the used auth key from disk" \
    "rm -f $key_file" \
    "$TAILSCALE_REASON" \
    "[ ! -e $key_file ]"
  plan_note "the agent client connects with: ssh $SERVICE_USER@<this machine's tailnet name>. tailscale ssh stays off; the machine's own SSH server and keys are used."
}
