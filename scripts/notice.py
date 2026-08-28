#!/usr/bin/env python3
"""Put a plain announcement banner on every open page, or take it down.

    ./scripts/notice.py "Big server maintenance in 12 hours." --hours 12
    ./scripts/notice.py --withdraw

This is NOT the deploy warning. The deploy script's `--notice` puts up a
restart countdown: it escalates, it says things about unsaved work, it is
capped at two hours, and it dies with the release it was warning about. All
of that is right for a restart that is minutes away and wrong for "we are
pushing the new system tomorrow".

So this is a different thing on purpose. It says exactly what you type, for
as long as you say, it survives restarts, and nothing about it implies the
server is going anywhere. It restarts nothing and schedules nothing - the
banner is the entire effect.

Auth is the same DEPLOY_NOTICE_TOKEN, because it is the same privilege: both
put a banner on every screen. The endpoint fails closed when the variable is
unset on the server.

It goes over SSH and curls the app on localhost, exactly as the deploy script
does, which is why these routes live under `/internal` - they are meant to be
called on the box. The public address is behind Cloudflare, whose bot check
answers a plain script with its own 403 before the app ever sees the request.

Settings come from the environment, or from a .env - the current directory
first, then the repository's own:

    DEPLOY_NOTICE_TOKEN  required, and must match the value in the server's
                         systemd unit - an unset token there means the
                         endpoint refuses everything
    DEPLOY_SSH_HOST      ssh host or alias (default kbsb-vps)
    DEPLOY_APP_PORT      the app's internal HTTP port (default 4001)
"""

import argparse
import json
import os
import sys
import shlex
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://pairings.zerotwo.cloud"
DEFAULT_SSH_HOST = "kbsb-vps"

# Only for `--url`, the direct-HTTP escape hatch. urllib announces itself as
# "Python-urllib/3.13", which Cloudflare's bot check answers with a 403 and
# its own error code 1010 before the app sees anything - so a request that
# fails for a reason having nothing to do with the token or the address.
USER_AGENT = "openpairings-notice/1.0 (+https://github.com/AuroraRyunix/openpairings)"
DEFAULT_APP_PORT = "4001"
REPO_ENV = Path(__file__).resolve().parent.parent / ".env"


def env_candidates(explicit=None):
    """Where to look for a .env, in order. The first that exists wins.

    The current directory comes before the repository's own file because the
    deploy script keeps its .env beside itself - the one holding
    DEPLOY_NOTICE_TOKEN and DEPLOY_PHX_HOST - and that is the directory
    somebody running this by hand is standing in. The repo's .env is the
    fallback for running it out of a checkout.
    """
    if explicit:
        return [Path(explicit)]

    return [Path.cwd() / ".env", REPO_ENV]


def load_env_file(explicit=None):
    """Read KEY=VALUE lines from a .env, without overriding the real environment.

    A real environment variable always wins. That ordering matters: it is
    what lets a one-off `DEPLOY_NOTICE_TOKEN=... notice.py ...` still work
    on a machine whose .env holds a different value, rather than silently
    ignoring what was typed.

    Missing file is not an error - plenty of machines will pass the token in
    directly and never have one.
    """
    for path in env_candidates(explicit):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue

        load_lines(lines)
        return path

    return None


def load_lines(lines):
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()

        # Tolerate `export KEY=value`, and strip one layer of matching
        # quotes - both are ordinary in a hand-edited .env.
        if key.startswith("export "):
            key = key[len("export "):].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]

        os.environ.setdefault(key, value)


def resolve_url(explicit):
    """Where to send it.

    `DEPLOY_PHX_HOST` lives in the deploy script's own .env and is the public
    hostname of the very server this talks to, so reading it means the
    ordinary case needs no --url at all.
    """
    if explicit:
        return explicit

    if os.environ.get("OPENPAIRINGS_URL"):
        return os.environ["OPENPAIRINGS_URL"]

    host = os.environ.get("DEPLOY_PHX_HOST")
    if host:
        host = host.strip().rstrip("/")
        return host if host.startswith(("http://", "https://")) else f"https://{host}"

    return DEFAULT_URL


def post_over_ssh(host, app_port, path, token, payload):
    """POST to the app over SSH, from the box itself.

    This is how the deploy script talks to these routes and why they live
    under `/internal`: the endpoint is meant to be called on the machine that
    is running the app, not across the internet.

    Going the public way instead means going through Cloudflare, which
    answers a plain `Python-urllib` request with its own 403 and error code
    1010 - a bot check the request never gets past, so the token and the
    address are never even looked at. There is no reason to argue with that
    when SSH is right there and already keyed.

    The payload travels on stdin rather than in the command line, so a
    message containing quotes, apostrophes or `$` cannot be mangled by the
    remote shell on its way to curl.
    """
    url = f"http://localhost:{app_port}{path}"

    remote = (
        "curl -sS -w '\\n%{http_code}' -X POST "
        f"{shlex.quote(url)} "
        f"-H {shlex.quote('Authorization: Bearer ' + token)} "
        "-H 'Content-Type: application/json' "
        "--data-binary @-"
    )

    try:
        completed = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, remote],
            input=json.dumps(payload).encode("utf-8"),
            capture_output=True,
            timeout=45,
        )
    except FileNotFoundError:
        sys.exit("ssh was not found on PATH")
    except subprocess.TimeoutExpired:
        sys.exit(f"timed out talking to {host}")

    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        sys.exit(f"ssh to {host} failed: {detail or completed.returncode}")

    out = completed.stdout.decode("utf-8", "replace").strip()
    body, _, status = out.rpartition("\n")
    body = body.strip() or out

    if status.strip() != "200":
        try:
            detail = json.loads(body).get("error", body)
        except (json.JSONDecodeError, AttributeError):
            detail = body[:300]

        if status.strip() == "404":
            sys.exit(
                f"the running app has no {path} (404).\n"
                "That route ships with this script's own release - deploy it "
                "before the banner can be set."
            )

        sys.exit(f"refused ({status.strip() or 'no status'}): {detail}")

    try:
        return json.loads(body)
    except json.JSONDecodeError:
        sys.exit(f"unexpected reply: {body[:300]}")


def send(args, host, app_port, token, path, payload):
    """SSH by default; direct HTTP only when an address is given explicitly."""
    if args.url:
        return post(args.url, path, token, payload)

    return post_over_ssh(host, app_port, path, token, payload)


def post(base, path, token, payload):
    request = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")

        if cloudflare_block(error.code, body):
            sys.exit(
                f"Cloudflare refused this before it reached the server ({error.code}).\n"
                "That is its bot check, not the app: the token and the address were "
                "never looked at.\n"
                "Run it on the box itself instead, where the endpoint is meant to be "
                "called and Cloudflare is not in the path:\n"
                f"  curl -X POST http://localhost:<APP_PORT>{path} \\\n"
                "       -H \"Authorization: Bearer $DEPLOY_NOTICE_TOKEN\" \\\n"
                f"       -H 'Content-Type: application/json' \\\n"
                f"       -d '{json.dumps(payload)}'"
            )

        try:
            detail = json.loads(body).get("error", body)
        except json.JSONDecodeError:
            detail = body.strip()[:300]

        sys.exit(f"refused ({error.code}): {detail}")
    except urllib.error.URLError as error:
        sys.exit(f"could not reach {base}: {error.reason}")


def cloudflare_block(status, body):
    """Whether this 4xx came from Cloudflare rather than from the app.

    The app only ever answers these routes with JSON carrying an `error`
    key, so an HTML body or one of Cloudflare's own numeric codes is a
    reliable tell that the request was stopped in front of it.
    """
    if status not in (403, 503, 1020):
        return False

    lowered = body.lower()
    return any(
        marker in lowered
        for marker in ("error code: 10", "cloudflare", "cf-ray", "<!doctype html")
    )


def main():
    parser = argparse.ArgumentParser(
        description="Show or withdraw the site-wide announcement banner.",
        epilog='example: notice.py "Big server maintenance in 12 hours." --hours 12',
    )
    parser.add_argument("message", nargs="?", help="what the banner says (max 200 chars)")
    parser.add_argument(
        "--hours",
        type=float,
        help="how long to show it for, from now. Up to 336 (two weeks).",
    )
    parser.add_argument(
        "--until",
        help="an explicit ISO 8601 instant, for when the deadline is a wall-clock "
        "time people have already been told (e.g. 2026-08-29T06:00:00Z)",
    )
    parser.add_argument(
        "--urgent",
        action="store_true",
        help="show it red. For something people have to act on, like scheduled "
        "downtime - not for news.",
    )
    parser.add_argument("--withdraw", action="store_true", help="take the banner down")
    parser.add_argument(
        "--host",
        default=None,
        help="SSH host to reach the server through (default: DEPLOY_SSH_HOST, "
        "or kbsb-vps)",
    )
    parser.add_argument(
        "--app-port",
        default=None,
        help="the app's internal HTTP port on that host (default: DEPLOY_APP_PORT)",
    )
    parser.add_argument(
        "--url",
        default=None,
        help="talk to this address directly over HTTP instead of over SSH - for a "
        "local server, since the public address goes through Cloudflare",
    )
    parser.add_argument("--env-file", default=None, help="read settings from this file")
    args = parser.parse_args()

    loaded = load_env_file(args.env_file)

    token = os.environ.get("DEPLOY_NOTICE_TOKEN")
    if not token:
        looked = "\n".join(f"  {p}" for p in env_candidates(args.env_file))
        sys.exit(
            "DEPLOY_NOTICE_TOKEN is not set, and no .env holding it was found.\n"
            f"Looked in:\n{looked}\n"
            "Run this from the folder that holds that .env, pass --env-file, or set "
            "the variable inline.\n"
            "It has to match the DEPLOY_NOTICE_TOKEN in the server's systemd unit; "
            "if that one is unset, the endpoint refuses everything."
        )

    host = args.host or os.environ.get("DEPLOY_SSH_HOST") or DEFAULT_SSH_HOST
    app_port = args.app_port or os.environ.get("DEPLOY_APP_PORT") or DEFAULT_APP_PORT

    if loaded:
        print(f"Settings from {loaded}")

    if args.withdraw:
        send(args, host, app_port, token, "/internal/notice/withdraw", {})
        print("Banner withdrawn.")
        return

    if not args.message:
        parser.error("a message is required (or pass --withdraw)")

    if args.hours is None and not args.until:
        parser.error("pass --hours or --until, so the banner has an end")

    payload = {"message": args.message}
    if args.urgent:
        payload["level"] = "urgent"
    if args.until:
        payload["until"] = args.until
    else:
        payload["hours"] = args.hours

    result = send(args, host, app_port, token, "/internal/notice", payload)
    print(f"Showing until {result['until']} ({result.get('level', 'info')}):")
    print(f"  {result['message']}")
    print()
    print("Nothing was restarted or scheduled. Take it down with --withdraw.")


if __name__ == "__main__":
    main()
