# Domain move checklist

Target names:

| Name | Serves | Today |
|---|---|---|
| `pairings.cloud` | OpenPairings (arbiter app), port 4001 on the VPS. The main name | `pairings.zerotwo.cloud` |
| `openpairings.cloud` | OpenPairings too: GET/HEAD 301 to the main name | new |
| `openresults.cloud` | OpenResults (public results), port 4004 | `openresults.zerotwo.cloud` |

`openpairings.cloud` is a second name for the arbiter app: it forwards to
`pairings.cloud` through `PHX_REDIRECT_HOSTS`, so logins and cookies live on one
host. OpenResults' short-link setting (`PHX_SHORT_HOST`) exists but is unused.
The old `*.zerotwo.cloud` names keep answering, both apps, for as long as they
stay in the tunnel; nothing in this plan removes them.

Nothing here is deployed by the code change. Everything below is switched on by
environment variables (empty = today's behaviour), in the order given.

## Settings (both apps read these in `config/runtime.exs`)

| Variable | App | Meaning |
|---|---|---|
| `PHX_HOST` | both | canonical host: every link, email, feed entry, `og:url`, QR code and printed URL is built from it |
| `PHX_ALLOWED_HOSTS` | both | comma list of extra hosts allowed to open the LiveView/hall websocket (`check_origin`). `PHX_HOST` is always allowed |
| `PHX_REDIRECT_HOSTS` | both | comma list of old hosts whose **GET/HEAD** get a 301 to `PHX_HOST`; also allowed origins. POST/PUT (publishing, forms) are not redirected on purpose |
| `PHX_MOVED_TO` | OpenPairings | the new main name. Every page opened on any other host shows a permanent banner saying where the app went, with a link. Not shown on the new host, nor in print |
| `PHX_SHORT_HOST` | OpenResults | one short-link host: `/` and `/t/...` 301 to `PHX_HOST`. Unused in this plan |
| `OPENRESULTS_PUBLIC_URL` | OpenPairings | the results site a **desktop copy** publishes to by default. Unset = compiled default `https://openresults.zerotwo.cloud` |

A value that is not a bare hostname stops the boot (typo protection).

Hosted OpenPairings builds its links to OpenResults from the address stored in
its publishing settings (`openresults_public_base`), which the deploy script
writes from `DEPLOY_OPENRESULTS_PHX_HOST`; it does not use `OPENRESULTS_PUBLIC_URL`.

## Order of steps

The deploy script carries the plan as defaults (`host_move_env` in
`deploy_openpairings.py`), so the `.env` only needs the two host switches. Any
default can be overridden in `.env`, an empty value switching it off.

| Unit variable | Default while `PHX_HOST` is old | Default once it is `pairings.cloud` |
|---|---|---|
| OpenPairings `PHX_ALLOWED_HOSTS` | `pairings.cloud` | `pairings.zerotwo.cloud` |
| OpenPairings `PHX_REDIRECT_HOSTS` | `openpairings.cloud` | `openpairings.cloud` |
| OpenPairings `PHX_MOVED_TO` | unset (no banner) | `pairings.cloud` |
| OpenResults `PHX_ALLOWED_HOSTS` | `openresults.cloud` | `openresults.zerotwo.cloud` |

### A. Cloudflare and Keycloak (done by hand, no deploy)

1. Zones for `pairings.cloud`, `openpairings.cloud`, `openresults.cloud` in the
   `zerotwo.cloud` account, nameservers moved, SSL Full (strict), Always Use HTTPS.
2. Tunnel public hostnames (they create the DNS records):
   `pairings.cloud` and `openpairings.cloud` -> `http://localhost:4001`,
   `openresults.cloud` -> `http://localhost:4004`. Keep the `zerotwo.cloud` ones.
3. Cloudflare Access: a new self-hosted application for `openresults.cloud/admin*`,
   same policy as the old one; note its AUD. Keep the old application. No Access
   on `/api/*`, `/t/*` or on the OpenPairings names (it has its own login).
4. Keycloak (`auth.zerotwo.cloud`, realm `zerotwo`), OpenPairings client: **add**
   `https://pairings.cloud/auth/keycloak/callback` to Valid Redirect URIs and
   `https://pairings.cloud` to Web Origins. Keep the old ones. The callback is
   built from `PHX_HOST`, so until step C every sign-in finishes on the old host.

### B. First deploy: both names answer, nothing visible changes

No `.env` change. Deploy both apps. The new names now open with working live
pages; `openpairings.cloud` forwards (to the old main name, until C). Links,
emails and QR codes still carry the old names.

### C. The switch

```
DEPLOY_PHX_HOST=pairings.cloud
DEPLOY_OPENRESULTS_PHX_HOST=openresults.cloud
OPENRESULTS_ADMIN_ACCESS_AUD=<AUD of the application from A3>
```

Deploy both. Links, emails, QR codes and printed URLs now use the new names (the
deploy also rewrites OpenPairings' stored results address). The old names stay
allowed, so pages opened there keep working, and OpenPairings shows the move
banner on them. People sign in once more on the new host (cookies are per host);
helper phones enrolled on the old host keep working there.

### D. Optional: forward the old names

To send page views on the old names to the new ones (uploads and forms are never
redirected, so old desktop copies keep publishing):

```
DEPLOY_PHX_REDIRECT_HOSTS=openpairings.cloud,pairings.zerotwo.cloud
DEPLOY_OPENRESULTS_PHX_REDIRECT_HOSTS=openresults.zerotwo.cloud
```

Skip this to keep the old names exactly as they are, banner aside.

### E. Desktop copies

Once `openresults.cloud` is live, change `@public_server` in
`lib/pairings_engine/publishing.ex` to `https://openresults.cloud` in the next
release. Installed copies keep publishing to the old host, which keeps
accepting writes: do not remove it from the tunnel while old releases are in use.

### F. Retire (optional, months later)

Remove the old Access application, the old Keycloak redirect URIs and the old
tunnel hostnames, in that order, only after logs show no traffic on them.

## Rolling back

Every step is an env change plus a deploy; reverse it.

- Redirects misbehave: set the `*_PHX_REDIRECT_HOSTS` values empty in `.env` and deploy (with a
  Cloudflare Redirect Rule instead, disable the rule: instant, no deploy).
- New host canonical but wrong: set `DEPLOY_PHX_HOST` / `DEPLOY_OPENRESULTS_PHX_HOST`
  back to the `zerotwo.cloud` names (the banner goes with it) and restore the old
  `OPENRESULTS_ADMIN_ACCESS_AUD`; deploy. The old hosts were never removed, so they
  answer straight away. `DEPLOY_ROLLBACK` restores the previous release if a deploy
  itself fails to come up.
- Websocket pages loop on "reconnecting": a host is missing from
  `PHX_ALLOWED_HOSTS`; add it and deploy.
- DNS: the `zerotwo.cloud` records are never touched by this plan, so there is
  nothing to roll back there.
