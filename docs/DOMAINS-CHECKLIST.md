# Domain move checklist

Target names:

| Name | Serves | Today |
|---|---|---|
| `openpairings.cloud` | OpenPairings (arbiter app), port 4001 on the VPS | `pairings.zerotwo.cloud` |
| `openresults.cloud` | OpenResults (public results), port 4004 | `openresults.zerotwo.cloud` |
| `pairings.cloud` | OpenPairings too: GET/HEAD 301 to `openpairings.cloud` | new |

`pairings.cloud` is a second name for the arbiter app, not a results site: it
forwards to `openpairings.cloud` through `PHX_REDIRECT_HOSTS`, so logins and
cookies live on one host only. OpenResults' short-link setting
(`PHX_SHORT_HOST`) exists but is not used in this plan; leave it empty.

Nothing here is deployed by the code change. Everything below is switched on by
environment variables (empty = today's behaviour), in the order given.

## Settings (both apps read these in `config/runtime.exs`)

| Variable | App | Meaning |
|---|---|---|
| `PHX_HOST` | both | canonical host: every link, email, feed entry, `og:url`, QR code and printed URL is built from it |
| `PHX_ALLOWED_HOSTS` | both | comma list of extra hosts allowed to open the LiveView/hall websocket (`check_origin`). `PHX_HOST` is always allowed |
| `PHX_REDIRECT_HOSTS` | both | comma list of old hosts whose **GET/HEAD** get a 301 to `PHX_HOST`; also allowed origins. POST/PUT (publishing, forms) are not redirected on purpose |
| `PHX_SHORT_HOST` | OpenResults | one short-link host: `/` and `/t/...` 301 to `PHX_HOST`. Unused in this plan |
| `OPENRESULTS_PUBLIC_URL` | OpenPairings | the results site a **desktop copy** publishes to by default. Unset = compiled default `https://openresults.zerotwo.cloud` |

A value that is not a bare hostname stops the boot (typo protection).

Hosted OpenPairings builds its links to OpenResults from the address stored in
its publishing settings (`openresults_public_base`), which the deploy script
writes from `DEPLOY_OPENRESULTS_PHX_HOST`; it does not use `OPENRESULTS_PUBLIC_URL`.

## Order of steps

### A. Cloudflare / DNS (no app change yet)

1. Add `openpairings.cloud`, `openresults.cloud`, `pairings.cloud` as zones in the
   same Cloudflare account as `zerotwo.cloud` (so the existing team domain
   `auroraryunix.cloudflareaccess.com` and the tunnel are reusable). Change the
   registrar nameservers to Cloudflare's. SSL/TLS mode: Full (strict); enable
   "Always use HTTPS".
2. DNS records, proxied (orange cloud), pointing at the existing tunnel:
   - `openpairings.cloud` and `www.openpairings.cloud`: `CNAME <tunnel-id>.cfargotunnel.com`
   - `openresults.cloud` and `www.openresults.cloud`: same
   - `pairings.cloud` (apex) and `www.pairings.cloud`: same
3. Tunnel public hostnames (Zero Trust > Networks > Tunnels > the tunnel):
   - `openpairings.cloud` -> `http://localhost:4001`
   - `openresults.cloud` -> `http://localhost:4004`
   - `pairings.cloud` -> `http://localhost:4001` (OpenPairings)
   Keep the three existing `*.zerotwo.cloud` entries.
4. Cloudflare Access: OpenResults' admin panel is gated by an Access application
   whose audience tag is `OPENRESULTS_ADMIN_ACCESS_AUD`. Create a **new** self-hosted
   application for `openresults.cloud/admin*` (same policy as the old one) and note
   its AUD. The team domain is unchanged. Keep the old application until step F.
   Do not put Access on `/api/*` or `/t/*`.
   OpenPairings itself is not behind Access (it has its own login).
5. Keycloak (`auth.zerotwo.cloud`, realm `zerotwo`): on the OpenPairings client,
   **add** `https://openpairings.cloud/auth/keycloak/callback` to Valid Redirect
   URIs (and `https://openpairings.cloud` to Web Origins). Keep the old ones.
   The login must work on the new host before PHX_HOST is switched.

### B. First deploy: accept both hosts, change nothing visible

In the deploy `.env` (see the script change below, which carries these into the
systemd units):

```
DEPLOY_PHX_ALLOWED_HOSTS=openpairings.cloud
DEPLOY_OPENRESULTS_PHX_ALLOWED_HOSTS=openresults.cloud
DEPLOY_PHX_REDIRECT_HOSTS=pairings.cloud
```

Leave `DEPLOY_PHX_HOST` and `DEPLOY_OPENRESULTS_PHX_HOST` as they are. Deploy.
Now both names work on both apps (websockets included), `pairings.cloud`
forwards to `openpairings.cloud`, and the old names are unchanged. With PHX_HOST still old, the new
hosts' pages carry `zerotwo.cloud` in their absolute links; expected at this stage.
Note the redirect goes to PHX_HOST, so until step C `pairings.cloud` forwards to
the old OpenPairings host.

### C. Switch the canonical host

```
DEPLOY_PHX_HOST=openpairings.cloud
DEPLOY_OPENRESULTS_PHX_HOST=openresults.cloud
DEPLOY_PHX_ALLOWED_HOSTS=pairings.zerotwo.cloud
DEPLOY_PHX_REDIRECT_HOSTS=pairings.cloud
DEPLOY_OPENRESULTS_PHX_ALLOWED_HOSTS=openresults.zerotwo.cloud
OPENRESULTS_ADMIN_ACCESS_AUD=<AUD of the new Access application from A4>
```

Deploy. The deploy also rewrites OpenPairings' stored public results address
from `DEPLOY_OPENRESULTS_PHX_HOST`, so share links, QR codes and printed URLs
from OpenPairings now carry `openresults.cloud`. Old hosts still answer;
everything works on both. Expect: people sign in again on the new host (cookies
are per host); email links use the new host; phones enrolled as helpers on the
old host keep working there until the old host is retired.

### D. Soak, then turn on the redirects

After a few days with no problems:

```
DEPLOY_PHX_REDIRECT_HOSTS=pairings.cloud,pairings.zerotwo.cloud
DEPLOY_OPENRESULTS_PHX_REDIRECT_HOSTS=openresults.zerotwo.cloud
```

(REDIRECT implies allowed origin, so the ALLOWED entries for the same hosts can
go.) Deploy. GET/HEAD on the old hosts now 301 to the new ones. Desktop copies
that publish to `openresults.zerotwo.cloud` keep working because POST/PUT are
not redirected. Alternative needing no deploy: a Cloudflare Redirect Rule per
old host (dynamic, keep path and query, 301); then leave these two variables empty.

### E. Desktop copies

Once `openresults.cloud` is live, change `@public_server` in
`lib/pairings_engine/publishing.ex` to `https://openresults.cloud` in the next
release (desktop copies cannot be configured from outside). Copies already
installed keep publishing to the old host, which keeps accepting writes, so do
not remove it from the tunnel while old desktop releases are in use.

### F. Retire (months later, optional)

Remove the old Access application, the old Keycloak redirect URIs and the old
tunnel hostnames, in that order, only after logs show no traffic on them.

## Deploy script change (patch shown, NOT applied)

`deploy_openpairings.py` rewrites the systemd units on every deploy, so the new
variables must be threaded through its `optional_env` lists. Where hostnames are
set today: the deploy `.env` (`DEPLOY_PHX_HOST`, `DEPLOY_OPENRESULTS_PHX_HOST`),
written into the units at `Environment="PHX_HOST=..."` (about line 2559). The
script also carries a built-in default `openresults.zerotwo.cloud` at about lines
3314 and 3509; it only applies if the `.env` entry is removed, but change it when
convenient. The `.env` itself is not shown or edited here.

```diff
@@ -3460,6 +3460,16 @@
             "",
         ))
 
+        # Hostname moves (see openpairings/docs/DOMAINS-CHECKLIST.md). Both
+        # optional and empty by default, so nothing changes until set.
+        for _name in ("PHX_ALLOWED_HOSTS", "PHX_REDIRECT_HOSTS"):
+            optional_env.append((
+                _name,
+                os.environ.get("DEPLOY_" + _name) or os.environ.get(_name),
+                f"Including {_name} in the systemd unit.",
+                "",
+            ))
+
         apps["openpairings"] = {
             "key": "openpairings",
             "display_name": "OpenPairings (the arbiter's app)",
@@ -3696,6 +3706,25 @@
                 # the snapshot publish path, the admin dashboard). Until it
                 # lands the app simply ignores two unknown variables, so these
                 # lines are safe now. Nothing else of that feature belongs here.
+                # Hostname moves (see openpairings/docs/DOMAINS-CHECKLIST.md).
+                # All optional and empty by default. Read as
+                # DEPLOY_OPENRESULTS_PHX_*, so they cannot collide with the
+                # OpenPairings pair above.
+                (
+                    "PHX_ALLOWED_HOSTS", or_env("OPENRESULTS_PHX_ALLOWED_HOSTS"),
+                    "Including PHX_ALLOWED_HOSTS (extra hosts may open the hall display socket).",
+                    "",
+                ),
+                (
+                    "PHX_REDIRECT_HOSTS", or_env("OPENRESULTS_PHX_REDIRECT_HOSTS"),
+                    "Including PHX_REDIRECT_HOSTS (GET/HEAD on those hosts 301 to PHX_HOST).",
+                    "",
+                ),
+                (
+                    "PHX_SHORT_HOST", or_env("OPENRESULTS_PHX_SHORT_HOST"),
+                    "Including PHX_SHORT_HOST (short links forward to PHX_HOST).",
+                    "",
+                ),
                 (
                     "OPENRESULTS_INSTALLATION_MAX_VERSIONS", "100",
                     "Including OPENRESULTS_INSTALLATION_MAX_VERSIONS=100 (hosted storage bound).",
```

Add to `.env.example`:

```
DEPLOY_PHX_ALLOWED_HOSTS=
DEPLOY_PHX_REDIRECT_HOSTS=
DEPLOY_OPENRESULTS_PHX_ALLOWED_HOSTS=
DEPLOY_OPENRESULTS_PHX_REDIRECT_HOSTS=
DEPLOY_OPENRESULTS_PHX_SHORT_HOST=
```

## Rolling back

Every step is an env change plus a deploy; reverse it.

- Redirects misbehave: empty the `*_PHX_REDIRECT_HOSTS` values and deploy (with a
  Cloudflare Redirect Rule instead, disable the rule: instant, no deploy).
- New host canonical but wrong: set `DEPLOY_PHX_HOST` / `DEPLOY_OPENRESULTS_PHX_HOST`
  back to the `zerotwo.cloud` names and restore the old
  `OPENRESULTS_ADMIN_ACCESS_AUD`; deploy. The old hosts were never removed, so they
  answer straight away. `DEPLOY_ROLLBACK` restores the previous release if a deploy
  itself fails to come up.
- Websocket pages loop on "reconnecting": a host is missing from
  `PHX_ALLOWED_HOSTS`; add it and deploy.
- DNS: the `zerotwo.cloud` records are never touched by this plan, so there is
  nothing to roll back there.
