# OpenPairings

Web-based chess tournament manager: FIDE Swiss pairings (JaVaFo), FIDE-compliant
tiebreaks (C.07), result entry, live standings, printing, TRF16 export, SWAR
import — built with Elixir/Phoenix LiveView. Runs locally and deploys unchanged to a server, with user accounts and per-user
tournaments.

## Quick start

Requires Erlang/OTP 29 + Elixir 1.20 and Java 8+ (for JaVaFo).

```
mix setup
mix phx.server
```

Then open http://localhost:4000 and register an account (in dev, the
confirmation e-mail appears at http://localhost:4000/dev/mailbox).

**JaVaFo:** the pairing engine JAR is not bundled (it is © Roberto Ricca).
Download it from https://www.rrweb.org/javafo/ and save it as
`priv/javafo/javafo.jar`.

## Documentation

The full [feature list & roadmap](docs/features.md) is one page; per-feature
guides live in [`docs/`](docs/README.md).

## History

The repository originally contained a Node/React prototype (`server/` +
`client/`); it was superseded by the Elixir/Phoenix rewrite and removed —
it remains available in the git history.
