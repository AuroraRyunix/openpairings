# Mobile no-account result entry

Lets an arbiter hand out results-only access to one tournament without
creating accounts for helpers: generate a QR code / 6-digit-ish code from the
**Live** page, a helper scans or types it on their own phone, and that phone
can enter results for the current round until the arbiter revokes it or it
expires. Nothing else on the phone is reachable — no players, settings,
pairing, or other tournaments.

Everything below lives in `PairingsEngine.Mobile` (the domain module) and the
`/m` route scope (`PairingsEngineWeb.MobileEnrollController` /
`MobileEnrollHTML` for enrollment, `PairingsEngineWeb.MobileResultsLive` for
the results screen, `PairingsEngineWeb.MobileAuth` for the session).

## Enrolling a phone

From a tournament's **Live** page (`/t/:id/live`, the same page an arbiter
projects — see the [architecture doc](architecture.md) for `LiveRoundLive`'s
dual role), the **"📱 Enrol a phone to enter results"** card has a **Generate
a code** button. Each click creates one `PairingsEngine.Mobile.Enrollment`:

- `token` — an 18-byte CSPRNG value, URL-safe base64, embedded in a QR code
  pointing at `/m/e/:token`. Scanning it enrolls immediately, no typing.
- `code` — an 8-digit CSPRNG number (`PairingsEngine.Mobile.gen_unique_code/1`),
  for a helper who can't scan (or is handed the code verbally/on paper).
  Eight digits, not six: `code` is looked up across **every** tournament's
  active enrollments at once (`get_active_by_code/1` has no tournament
  scope), so with several tournaments running concurrently a shorter code
  would make guessing another tournament's session too easy. Rejection
  sampling keeps the space uniform (no `rem/2` bias).
- `expires_at` — 24 hours from creation (`@default_ttl_hours` in
  `PairingsEngine.Mobile`). A phone that stays enrolled across a whole
  tournament day re-enrolls automatically the next morning; there's no
  "remember me forever" option by design — a stale, forgotten enrollment
  from a past tournament should not still work months later.

The card lists every currently active enrollment (code + expiry) with a
**Revoke** button — instant: `Mobile.get_active/1` re-checks
`revoked_at`/`expires_at` on *every* mobile request, not just at enroll time,
so a revoked phone is locked out on its very next tap, not merely unable to
start a new session.

## The phone-side flow

1. `GET /m` — the code-entry page (`MobileEnrollHTML.new/1`), or `GET
   /m/e/:token` straight from the QR. Both, on success, store the
   enrollment's id in the session (`PairingsEngineWeb.MobileAuth`,
   `:mobile_enrollment_id`) and redirect to `/m/results`.
2. Typed-code submission is per-IP rate-limited
   (`PairingsEngine.RateLimit`, key `:mobile_enroll`) against brute-forcing
   the 8-digit code.
3. `/m/results` (`PairingsEngineWeb.MobileResultsLive`) — every board of the
   current round as a card: white vs. black, each player's rating and their
   score *entering* the round (same figure a printed pairing sheet would
   show — computed via `Standings.standings(tournament, through_round: n - 1)`,
   not a live mid-round number), and three big result buttons (`1-0` /
   `½-½` / `0-1`) plus a clear (⟲) button once a result is set. If more than
   one round has been paired, a round switcher lets the helper flip back to
   check/fix an earlier round.
4. `GET /m/leave` clears the session cookie's enrollment id — "log out" for
   a shared/kiosk phone.

`MobileAuth.on_mount(:require_enrollment, ...)` guards `/m/results`: no
active enrollment in the session → redirect to `/m`. The tournament shown is
always the one the enrollment was scoped to at creation; there is no way to
navigate to a different tournament from a mobile session.

## Protections against real-world phone use

These were added after real production incidents during live tournament use
(see git history around the "confirm before blank overwrites a result" and
"session persists across app-kill" commits) — each maps to something that
actually happened to an arbiter mid-event, not a hypothetical:

- **Session survives the phone backgrounding/killing the tab.** The session
  cookie (`PairingsEngineWeb.Endpoint`) carries a 30-day `max_age`. Without
  it, the cookie was browser-session-only, and mobile browsers routinely drop
  those when a backgrounded tab's process is reclaimed — an arbiter's helper
  would be bounced back to the enrollment-code screen mid-round for no
  visible reason. This is shared with the main (authenticated) login cookie;
  fixing it fixed both problems at once.
- **A blank submission never silently overwrites a real result.** LiveView
  reconnect can occasionally resend a `phx-change`/`phx-click` payload; a
  blank one arriving after a real result was already entered used to erase
  it with no confirmation. `PairingsEngineWeb.PairingsLive` (the desktop
  equivalent) now requires an explicit "Yes, clear it" confirmation before a
  blank result is written over an existing one, and logs both the attempt
  and the confirmed clear to the tournament's audit trail
  (`pairing.result_clear_attempted` / `pairing.result_cleared`). The mobile
  screen's clear button is explicit (⟲, a deliberate tap) rather than an
  implicit blank state, so it isn't exposed to the same reconnect-resend
  failure mode.
- **Lock toggle** (🔓/🔒, top right of `/m/results`, off by default) — for
  physically handing the phone to someone else or setting it down: while
  locked, the result buttons are disabled and `handle_event("set_result",
  ...)` short-circuits server-side regardless of what the client sends, so
  it's real enforcement, not just a disabled-looking button. Per-session
  (resets to unlocked on reload), not a security boundary — the enrollment
  itself is what scopes access.
- **Theme toggle** (System/Light/Dark) is available on `/m` and `/m/results`
  — reuses the same `Layouts.theme_switch/1` component and `data-theme`
  mechanism the rest of the app uses (see below), so a helper can switch to
  dark to cut phone glare in a tournament hall without needing an account or
  a settings page.

## Theme is per-device, not per-tournament

The light/dark/system theme choice is stored client-side
(`localStorage["phx:theme"]`) and applied via a `data-theme` attribute set
on `<html>` by an inline script in `root.html.heex`, before first paint —
this already covers every page including `/m/...`, since the root layout is
shared app-wide. There is no server-side "tournament theme" to sync across
every enrolled phone: each phone remembers its own choice, which is also the
more useful behaviour in practice (one helper's eyes, one phone's brightness
preference) — see [`docs/mobile.md`](mobile.md) for the responsive-CSS side
of the mobile experience (a different concern: viewport/breakpoint handling,
not this account-free flow).

## Security model, summarized

- No account is created or required; nothing is stored in the browser beyond
  the session cookie holding an opaque enrollment id.
- Scope is exactly one tournament, results only — no player data edits, no
  settings, no pairing, no other tournaments, enforced both by what
  `/m/results` renders and by the server-side pairing lookup only matching
  rows in the enrollment's own tournament (`MobileResultsLive.handle_event/3`
  filters `round.pairings` by id, which is scoped to `socket.assigns.round`,
  itself loaded from `socket.assigns.tournament`).
- Every write re-validates the enrollment is still active, so revocation and
  expiry are effective immediately, not just on the next page load.
- The 8-digit code is CSPRNG-generated and rate-limited against guessing;
  the QR token is a why-bother-guessing 18-byte random value.
