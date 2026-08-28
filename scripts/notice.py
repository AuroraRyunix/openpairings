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

Environment:
    OPENPAIRINGS_URL     default https://pairings.zerotwo.cloud
    DEPLOY_NOTICE_TOKEN  required
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "https://pairings.zerotwo.cloud"


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
    parser.add_argument("--url", default=os.environ.get("OPENPAIRINGS_URL", DEFAULT_URL))
    args = parser.parse_args()

    token = os.environ.get("DEPLOY_NOTICE_TOKEN")
    if not token:
        sys.exit("DEPLOY_NOTICE_TOKEN is not set")

    if args.withdraw:
        post(args.url, "/internal/notice/withdraw", token, {})
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

    result = post(args.url, "/internal/notice", token, payload)
    print(f"Showing until {result['until']}:")
    print(f"  {result['message']}")
    print()
    print("Nothing was restarted or scheduled. Take it down with --withdraw.")


if __name__ == "__main__":
    main()
