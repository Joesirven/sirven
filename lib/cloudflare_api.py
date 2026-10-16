#!/usr/bin/env python3
"""cloudflare_api.py: the few Cloudflare API calls the tunnel transport makes, and the record file it keeps.

run as: python3 -I cloudflare_api.py ACTION ARGUMENT...  (from lib/cloudflare_tunnel.sh, never by hand)

the API token is read from the first line of standard input and nowhere else: never from the command line, never from the
environment. it is sent only as the Authorization header, and whatever the API or the network says back is printed with the
token blanked out. every action prints one JSON value on standard output and nothing else there.

exit status: 0 done, 1 failed (says why on standard error), 2 refused for a bad argument, 3 not found.

API actions (they need the token):
  verify ACCOUNT                         the token can list tunnels of ACCOUNT
  find-zone HOSTNAME                     the zone that holds HOSTNAME: {"id", "name"}
  tunnel-find ACCOUNT NAME               tunnels of ACCOUNT named exactly NAME: [{"id", "name"}]
  tunnel-create ACCOUNT NAME FILE        make a locally managed tunnel, keep its credentials in FILE (mode 0600): {"id", "name"}
  tunnel-get ACCOUNT TUNNEL              {"id", "name", "deleted"}
  tunnel-delete ACCOUNT TUNNEL           end its connections, delete it; a tunnel that is already gone is done
  record-find ZONE HOSTNAME              every record of the zone named HOSTNAME: [{"id", "type", "content"}]
  record-create ZONE HOSTNAME TUNNEL     an alias record HOSTNAME to the tunnel: {"id"}
  record-get ZONE RECORD                 {"id", "type", "name", "content"}
  record-delete ZONE RECORD              delete it; a record that is already gone is done
record file actions (no token, no network):
  marker-set FILE KEY=VALUE...           add or replace fields of the JSON record FILE (mode 0600, replaced in one step)
  marker-get FILE KEY                    print one field; exit 3 when the file or the field is not there

SIRVEN_CLOUDFLARE_API replaces the API address for the tests, and is honored only in a test run, and only when it names this machine
itself (http://127.0.0.1:PORT or http://localhost:PORT). a test run is: a process that is not root (it can only hurt its own
account), or root with a file /run/sirven-test-run that is a plain file owned by root and writable by nobody else, which only the
test container's own setup makes. an environment alone is not enough as root: root's environment can be inherited from anywhere, and
any local account can listen on a port of this machine, so an address on this machine is not an address that cannot take the token
anywhere else. in every other case the override is ignored, with a note, and the real address is used.

this program clears the proxy and certificate variables of its environment (http_proxy and the like, SSL_CERT_FILE, SSL_CERT_DIR,
SSLKEYLOGFILE, OPENSSL_CONF) before it loads the ssl module, and again before it calls the API, uses no proxy, and follows no redirect: the Authorization header is sent to the one address
and to no other.
"""
import os

# what changes where a request goes, which certificates are trusted, or where TLS secrets are written, whatever the caller had in its
# environment: proxies, certificate files, a key log file, and the OpenSSL configuration file. cleared here, before anything below
# loads the ssl module (urllib.request does): OpenSSL reads OPENSSL_CONF once, when the module is loaded, so clearing it afterwards
# would change nothing. compared in lower case for the proxy ones.
CLEARED_EXACT = ("SSL_CERT_FILE", "SSL_CERT_DIR", "SSLKEYLOGFILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "OPENSSL_CONF")
CLEARED_LOWER = ("http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy")


def clear_environment():
    for name in list(os.environ):
        if name in CLEARED_EXACT or name.lower() in CLEARED_LOWER:
            del os.environ[name]


clear_environment()

import base64  # noqa: E402 (after the environment is cleared, on purpose)
import json  # noqa: E402
import re  # noqa: E402
import stat  # noqa: E402
import sys  # noqa: E402
import urllib.error  # noqa: E402
import urllib.parse  # noqa: E402
import urllib.request  # noqa: E402

DEFAULT_BASE = "https://api.cloudflare.com/client/v4"
ACCOUNT = re.compile(r"^[0-9a-f]{32}$")
TUNNEL = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
RECORD = re.compile(r"^[0-9a-f]{32}$")
HOSTNAME = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")
NAME = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
FIELD = re.compile(r"^[a-z_]{1,40}$")
TIMEOUT = 30


class Failure(Exception):
    def __init__(self, message, status=1):
        Exception.__init__(self, message)
        self.status = status


TEST_RUN_MARKER = "/run/sirven-test-run"
def test_run():
    """not root, or root with the marker file only the test container's setup makes (see the top of this file)"""
    if os.geteuid() != 0:
        return True
    try:
        info = os.lstat(TEST_RUN_MARKER)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022


def api_base():
    seam = os.environ.get("SIRVEN_CLOUDFLARE_API", "")
    if not seam:
        return DEFAULT_BASE
    parsed = urllib.parse.urlsplit(seam)
    if not (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost") and parsed.username is None):
        sys.stderr.write("note: SIRVEN_CLOUDFLARE_API names an address that is not this machine, so it is ignored.\n")
        return DEFAULT_BASE
    if not test_run():
        sys.stderr.write("note: SIRVEN_CLOUDFLARE_API is for test runs only, and this is not one, so it is ignored.\n")
        return DEFAULT_BASE
    return seam.rstrip("/")


def check(pattern, value, what):
    if not pattern.match(value):
        raise Failure("%s '%s' is not in the form Cloudflare uses" % (what, value[:80]), 2)
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """refuses every redirect: a redirect to another address would be sent the Authorization header (or, from https to http, in plain)"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure("the API answered with a redirect (HTTP %d); sirven follows no redirect, because it would send the token along" % code)


class Client:
    def __init__(self, token):
        if not token:
            raise Failure("there is no API token on standard input", 2)
        self.token = token
        clear_environment()
        self.base = api_base()
        # no proxy at all (an empty table, not the environment's) and no redirect
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def blank(self, text):
        return text.replace(self.token, "[token hidden]")

    def call(self, method, path, body=None, query=None):
        """returns (HTTP status, decoded JSON or None). only a network failure raises."""
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Authorization", "Bearer " + self.token)
        request.add_header("Content-Type", "application/json")
        try:
            with self.opener.open(request, timeout=TIMEOUT) as answer:
                status, raw = answer.status, answer.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        except (urllib.error.URLError, OSError) as error:
            raise Failure(self.blank("could not reach the Cloudflare API: %s" % error))
        try:
            return status, json.loads(raw.decode() or "null")
        except ValueError:
            return status, None

    def need(self, method, path, body=None, query=None, allow_missing=False):
        """the decoded answer; a 404 is returned as None when allow_missing, else every failure raises."""
        status, answer = self.call(method, path, body, query)
        if allow_missing and status == 404:
            return None
        ok = isinstance(answer, dict) and answer.get("success") is True and 200 <= status < 300
        if not ok:
            messages = []
            if isinstance(answer, dict):
                for item in answer.get("errors") or []:
                    if isinstance(item, dict):
                        messages.append("%s %s" % (item.get("code", ""), item.get("message", "")))
            detail = "; ".join(messages)[:300] or "no reason given"
            raise Failure(self.blank("Cloudflare answered HTTP %d for %s %s: %s" % (status, method, path, detail)))
        return answer


def result_list(answer):
    result = answer.get("result") if isinstance(answer, dict) else None
    return result if isinstance(result, list) else []


def verify(client, account):
    check(ACCOUNT, account, "account")
    client.need("GET", "/accounts/%s/cfd_tunnel" % account, query={"per_page": 1, "is_deleted": "false"})
    return {"ok": True}


def find_zone(client, hostname):
    check(HOSTNAME, hostname, "hostname")
    labels = hostname.split(".")
    for start in range(len(labels) - 1):
        candidate = ".".join(labels[start:])
        found = result_list(client.need("GET", "/zones", query={"name": candidate}))
        for zone in found:
            if isinstance(zone, dict) and zone.get("name") == candidate and RECORD.match(str(zone.get("id", ""))):
                return {"id": zone["id"], "name": candidate}
    raise Failure("no zone of this account holds %s (or the token cannot list zones: then give the zone number in SIRVEN_CLOUDFLARE_ZONE_ID)" % hostname)


def tunnel_find(client, account, name):
    check(ACCOUNT, account, "account")
    check(NAME, name, "tunnel name")
    found = result_list(client.need("GET", "/accounts/%s/cfd_tunnel" % account, query={"name": name, "is_deleted": "false"}))
    return [{"id": t["id"], "name": t["name"]} for t in found
            if isinstance(t, dict) and t.get("name") == name and TUNNEL.match(str(t.get("id", ""))) and not t.get("deleted_at")]


def write_credentials(path, account, tunnel_id, name, secret):
    temporary = "%s.new.%d" % (path, os.getpid())
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"AccountTag": account, "TunnelSecret": secret, "TunnelID": tunnel_id, "TunnelName": name}, handle)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.rename(temporary, path)
    except BaseException:
        if os.path.lexists(temporary):
            os.unlink(temporary)
        raise


def tunnel_create(client, account, name, path):
    check(ACCOUNT, account, "account")
    check(NAME, name, "tunnel name")
    secret = base64.b64encode(os.urandom(32)).decode()
    answer = client.need("POST", "/accounts/%s/cfd_tunnel" % account,
                         {"name": name, "config_src": "local", "tunnel_secret": secret})
    made = answer.get("result") if isinstance(answer.get("result"), dict) else {}
    tunnel_id = str(made.get("id", ""))
    if not TUNNEL.match(tunnel_id):
        raise Failure("Cloudflare made a tunnel but did not name it in a form this can use; look for %s in the dashboard" % name)
    try:
        write_credentials(path, account, tunnel_id, name, secret)
    except OSError as error:
        # a tunnel whose secret was not kept cannot be run, only deleted
        try:
            tunnel_delete(client, account, tunnel_id)
        except Failure:
            pass
        raise Failure("made the tunnel %s but could not keep its credentials in %s (%s); deleted it again if it could" % (tunnel_id, path, error.strerror))
    return {"id": tunnel_id, "name": name}


def tunnel_get(client, account, tunnel_id):
    check(ACCOUNT, account, "account")
    check(TUNNEL, tunnel_id, "tunnel")
    answer = client.need("GET", "/accounts/%s/cfd_tunnel/%s" % (account, tunnel_id), allow_missing=True)
    found = answer.get("result") if isinstance(answer, dict) else None
    if not isinstance(found, dict):
        raise Failure("no such tunnel", 3)
    return {"id": tunnel_id, "name": str(found.get("name", "")), "deleted": bool(found.get("deleted_at"))}


def tunnel_delete(client, account, tunnel_id):
    check(ACCOUNT, account, "account")
    check(TUNNEL, tunnel_id, "tunnel")
    base = "/accounts/%s/cfd_tunnel/%s" % (account, tunnel_id)
    # a tunnel that still has connections cannot be deleted; they are ended first (a missing tunnel answers 404, and is done)
    client.need("DELETE", base + "/connections", allow_missing=True)
    client.need("DELETE", base, allow_missing=True)
    return {"deleted": tunnel_id}


def record_find(client, zone, hostname):
    check(RECORD, zone, "zone")
    check(HOSTNAME, hostname, "hostname")
    found = result_list(client.need("GET", "/zones/%s/dns_records" % zone, query={"name": hostname}))
    return [{"id": r["id"], "type": str(r.get("type", "")), "content": str(r.get("content", ""))}
            for r in found if isinstance(r, dict) and RECORD.match(str(r.get("id", ""))) and r.get("name") == hostname]


def record_create(client, zone, hostname, tunnel_id):
    check(RECORD, zone, "zone")
    check(HOSTNAME, hostname, "hostname")
    check(TUNNEL, tunnel_id, "tunnel")
    answer = client.need("POST", "/zones/%s/dns_records" % zone, {
        "type": "CNAME", "name": hostname, "content": "%s.cfargotunnel.com" % tunnel_id, "proxied": True, "ttl": 1,
        "comment": "made by sirven for tunnel %s; sirven removes it with the tunnel" % tunnel_id})
    made = answer.get("result") if isinstance(answer.get("result"), dict) else {}
    if not RECORD.match(str(made.get("id", ""))):
        raise Failure("Cloudflare made the record but did not name it in a form this can use; look for %s in the dashboard" % hostname)
    return {"id": made["id"]}


def record_get(client, zone, record):
    check(RECORD, zone, "zone")
    check(RECORD, record, "record")
    answer = client.need("GET", "/zones/%s/dns_records/%s" % (zone, record), allow_missing=True)
    found = answer.get("result") if isinstance(answer, dict) else None
    if not isinstance(found, dict):
        raise Failure("no such record", 3)
    return {"id": record, "type": str(found.get("type", "")), "name": str(found.get("name", "")), "content": str(found.get("content", ""))}


def record_delete(client, zone, record):
    check(RECORD, zone, "zone")
    check(RECORD, record, "record")
    client.need("DELETE", "/zones/%s/dns_records/%s" % (zone, record), allow_missing=True)
    return {"deleted": record}


def marker_read(path):
    try:
        with open(path) as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise Failure("%s cannot be read as a record" % path)
    if not isinstance(data, dict):
        raise Failure("%s is not a record" % path)
    return data


def marker_set(path, pairs):
    data = marker_read(path)
    for pair in pairs:
        key, separator, value = pair.partition("=")
        if not separator or not FIELD.match(key) or re.search(r"[\x00-\x1f]", value):
            raise Failure("'%s' is not a field to record" % pair[:40], 2)
        data[key] = value
    temporary = "%s.new.%d" % (path, os.getpid())
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(data, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.rename(temporary, path)
    except BaseException:
        if os.path.lexists(temporary):
            os.unlink(temporary)
        raise
    return {"recorded": sorted(data)}


def marker_get(path, key):
    value = marker_read(path).get(key)
    if not isinstance(value, str) or not value or re.search(r"[\x00-\x1f]", value):
        raise Failure("not recorded", 3)
    return value


API_ACTIONS = {
    "verify": (verify, 1), "find-zone": (find_zone, 1), "tunnel-find": (tunnel_find, 2), "tunnel-create": (tunnel_create, 3),
    "tunnel-get": (tunnel_get, 2), "tunnel-delete": (tunnel_delete, 2), "record-find": (record_find, 2),
    "record-create": (record_create, 3), "record-get": (record_get, 2), "record-delete": (record_delete, 2),
}


def main(argv):
    if len(argv) < 2:
        raise Failure("usage: cloudflare_api.py ACTION ARGUMENT...", 2)
    action, arguments = argv[1], argv[2:]
    if action == "marker-set":
        if not arguments:
            raise Failure("marker-set needs a file", 2)
        return marker_set(arguments[0], arguments[1:])
    if action == "marker-get":
        if len(arguments) != 2:
            raise Failure("marker-get needs a file and a field", 2)
        value = marker_get(*arguments)
        sys.stdout.write(value + "\n")
        return None
    if action not in API_ACTIONS:
        raise Failure("unknown action '%s'" % action[:40], 2)
    function, count = API_ACTIONS[action]
    if len(arguments) != count:
        raise Failure("%s needs %d argument(s)" % (action, count), 2)
    token = sys.stdin.readline().strip()
    return function(Client(token), *arguments)


if __name__ == "__main__":
    try:
        printed = main(sys.argv)
    except Failure as failure:
        sys.stderr.write("error: %s\n" % failure)
        sys.exit(failure.status)
    except OSError as error:
        sys.stderr.write("error: %s\n" % error.strerror)
        sys.exit(1)
    if printed is not None:
        sys.stdout.write(json.dumps(printed) + "\n")
