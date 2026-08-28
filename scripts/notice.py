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

Settings come from the environment, or from the repo's .env when the
environment does not already have them:

    OPENPAIRINGS_URL     default https://pairings.zerotwo.cloud
    DEPLOY_NOTICE_TOKEN  required, and must match the value in the server's
                         systemd unit - an unset token there means the
                         endpoint refuses everything
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://pairings.zerotwo.cloud"
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


def post(base, path, token, payload):
    request = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        try:
            detail = json.loads(body).get("error", body)
        except json.JSONDecodeError:
            detail = body
        sys.exit(f"refused ({error.code}): {detail}")
    except urllib.error.URLError as error:
        sys.exit(f"could not reach {base}: {error.reason}")


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
    parser.add_argument("--withdraw", action="store_true", help="take the banner down")
    parser.add_argument("--url", default=None, help="override the server address")
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

    base = resolve_url(args.url)

    if loaded:
        print(f"Settings from {loaded}")

    if args.withdraw:
        post(base, "/internal/notice/withdraw", token, {})
        print("Banner withdrawn.")
        return

    if not args.message:
        parser.error("a message is required (or pass --withdraw)")

    if args.hours is None and not args.until:
        parser.error("pass --hours or --until, so the banner has an end")

    payload = {"message": args.message}
    if args.until:
        payload["until"] = args.until
    else:
        payload["hours"] = args.hours

    result = post(base, "/internal/notice", token, payload)
    print(f"Showing until {result['until']}:")
    print(f"  {result['message']}")
    print()
    print("Nothing was restarted or scheduled. Take it down with --withdraw.")


if __name__ == "__main__":
    main()
