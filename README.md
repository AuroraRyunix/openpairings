# OpenPairings

Web-based chess tournament manager: FIDE Swiss pairings (JaVaFo), FIDE-compliant
tiebreaks (C.07), result entry, live standings, printing, TRF16 export, SWAR
import — built with Elixir/Phoenix LiveView. Runs locally and deploys unchanged to a server, with user accounts and per-user
tournaments.

**The app lives in [`pairings_engine/`](pairings_engine/)** — see its README.

## Quick start

Requires Erlang/OTP 29 + Elixir 1.20 and Java 8+ (for JaVaFo).

```
cd pairings_engine
mix setup
mix phx.server
```

Then open http://localhost:4000 and register an account (in dev, the
confirmation e-mail appears at http://localhost:4000/dev/mailbox).

**JaVaFo:** the pairing engine JAR is not bundled (it is © Roberto Ricca).
Download it from https://www.rrweb.org/javafo/ and save it as
`pairings_engine/priv/javafo/javafo.jar`.

## Repository layout

- `pairings_engine/` — the Phoenix application (current)
- `server/`, `client/` — the original Node/React implementation (superseded by
  the Elixir rewrite; kept for reference)
