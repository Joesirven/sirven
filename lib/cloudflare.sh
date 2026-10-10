# shellcheck shell=bash
# cloudflare tunnel transport, the documented second path. every step is plan output only in
# the alpha cut.
#
# interactive once: cloudflared tunnel login opens a browser for your zone, and you create an
# access application with a service token in the dashboard. after that the agent client
# connects with the service token and its SSH key. no email codes: the access policy allows
# the service token only.
# reads: PREFIX, PACKAGE, CONFIG_DIR, SERVICE_USER

CLOUDFLARE_REASON="the cloudflare tunnel path is documented in the alpha cut; its plan and apply come later"
CLOUDFLARE_HOSTNAME="agent.example.com"

cloudflare_tunnel_name() {
  printf '%s-agent' "$PACKAGE"
}

cloudflare_config() {
  cat <<END
tunnel: $(cloudflare_tunnel_name)
credentials-file: $CONFIG_DIR/cloudflared-credentials.json
ingress:
  - hostname: $CLOUDFLARE_HOSTNAME
    service: ssh://localhost:22
  - service: http_status:404
END
}

# true when cloudflared runs as a system service, on either operating system. read only.
cloudflare_service_installed() {
  systemctl is-enabled --quiet cloudflared 2>/dev/null || launchctl list 2>/dev/null | grep -q com.cloudflare.cloudflared
}

plan_cloudflare() {
  local tunnel config credentials
  tunnel="$(cloudflare_tunnel_name)"
  config="$(rooted "$CONFIG_DIR/cloudflared.yml")"
  credentials="$(rooted "$CONFIG_DIR/cloudflared-credentials.json")"
  plan_section "transport: cloudflare tunnel"
  plan_note "replace $CLOUDFLARE_HOSTNAME with a hostname in your own zone."
  plan_owner "authorize this machine for your zone, once, in the browser" \
    "run: cloudflared tunnel login"
  plan_planonly "create the tunnel" \
    "cloudflared tunnel create --credentials-file $credentials $tunnel" \
    "$CLOUDFLARE_REASON" \
    "[ -f $credentials ]"
  plan_planonly "write the tunnel configuration" \
    "cat > $config <<'END'
$(cloudflare_config)
END" \
    "$CLOUDFLARE_REASON" \
    "[ -f $config ]"
  plan_planonly "point the hostname at the tunnel" \
    "cloudflared tunnel route dns $tunnel $CLOUDFLARE_HOSTNAME" \
    "$CLOUDFLARE_REASON"
  plan_tag always
  plan_owner "put cloudflare access in front, with a service token" \
    "cloudflare dashboard, access, applications: add $CLOUDFLARE_HOSTNAME as a self-hosted application.
policy action: service auth, allowing only a new service token for your agent client.
do not add email code login or any other login method."
  plan_planonly "run the tunnel as a system service" \
    "cloudflared --config $config service install" \
    "$CLOUDFLARE_REASON" \
    "cloudflare_service_installed"
  plan_note "the agent client connects with: ssh -o ProxyCommand='cloudflared access ssh --hostname %h --service-token-id <token> --service-token-secret <secret>' $SERVICE_USER@$CLOUDFLARE_HOSTNAME"
}
