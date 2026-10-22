# Browser tests and the smoke check

Two things live here, and they must not be confused:

| | `mix test.e2e` | `e2e/smoke.mjs` |
| --- | --- | --- |
| Runs against | a server this run starts, on a throwaway test database | any running server, production included |
| Writes data | yes - accounts, tournaments, results, all rolled back | **never** |
| Runs in CI | yes, the "Browser tests" job | its own test does, against the test server |

## The browser tests (`test/e2e`)

[phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright):
PhoenixTest's `visit |> fill_in |> click_button |> assert_has` pipeline, but
the session is a real headless Chromium driven by Playwright. They run inside
ExUnit, so the SQL Sandbox, the fixtures and the Req stubs work exactly as in
every other test; a test can set the database up with the context functions
and assert on it afterwards.

What is covered, one file per flow:

| File | Flow |
| --- | --- |
| `sign_in_test.exs` | signing in with a password; a wrong one staying out |
| `tournament_flow_test.exs` | a new tournament, four players, round 1 paired, both results entered, the standings |
| `publish_test.exs` | publishing to OpenResults: the consent dialog, then the drain's three requests to a stub of the results site (`PublicServerStub`); declining sends nothing |
| `archive_group_test.exs` | "Archive group" and its confirm dialog, both answers |
| `unsaved_guard_test.exs` | leaving a Settings page with unsaved edits asks first, both answers; no edits, no question |
| `smoke_script_test.exs` | `e2e/smoke.mjs` itself, against the test server |

OpenPairings has no guided tour; Alnasl's has its own tests in that
repository.

### Running them

Once per checkout:

```sh
cd e2e
npm ci
npx playwright install chromium-headless-shell   # into Playwright's own cache, not the system
```

Then, on Linux or macOS:

```sh
mix test.e2e                      # all of them
mix test.e2e test/e2e/publish_test.exs
PW_TRACE=true mix test.e2e --failed   # a trace per test, in _build/e2e/traces
```

On **Windows** Erlang cannot start Playwright's driver (a `.js` file) itself,
so the browser runs in a Playwright server and the tests connect to it:

```powershell
cd e2e; npx playwright run-server --port 3333 --host 127.0.0.1   # leave it running
$env:PLAYWRIGHT_WS_ENDPOINT = "ws://127.0.0.1:3333/"; mix test.e2e
```

`mix test.e2e` builds the assets, sets `E2E=1`, and runs `mix test --only
e2e`. `test/test_helper.exs` sees `E2E=1` and restarts the endpoint with a
listener on port 4012 (`E2E_PORT` to change it) and starts Playwright. A plain
`mix test` and `mix precommit` exclude `:e2e`, start neither, and need no Node.

A trace opens with `npx playwright show-trace <file>`, or on
<https://trace.playwright.dev>. CI keeps the traces and screenshots of a
failed run as the `e2e-traces` artifact.

### Writing one

`use PairingsEngineWeb.E2ECase` (test/support/e2e_case.ex) - it tags the
module `:e2e` and brings `sign_in/1`. Things that bit while writing these:

- **Never `async: true`.** The sandbox is in shared mode so the LiveViews and
  controllers the browser wakes can use it; that only works alone.
- **`data-confirm` is not a browser dialog here.** app.js shows its own
  `<dialog class="pe-confirm">`; click its "OK" or "Cancel" like any button.
  `with_dialog/3` would wait for a `confirm()` that never comes.
- **A full-page form post returns before it lands.** `click_button` on the
  password login returns as soon as the click is made; wait for the next page
  (`sign_in/1` does) before visiting another.
- **No double quotes inside `text:`.** The driver does not escape them; split
  the assertion around the quoted part.
- **`body .phx-connected`** before the first interaction with a LiveView, or
  the click can arrive before the socket does.
- A request the app makes to another server goes through a `Req.Test` stub
  set to shared (`Req.Test.set_req_test_to_shared/1`): the request is made by
  a LiveView or a background process, not by the test.

## The smoke check (`e2e/smoke.mjs`)

For right after a deploy: does the server answer, do the public pages render,
are the stylesheet and script served, does a LiveView connect over its
websocket (the part a proxy breaks and `curl` cannot see).

```sh
cd e2e
npm ci && npx playwright install chromium-headless-shell   # once
node smoke.mjs https://pairings.cloud
```

One line per check, exit status 0 when all passed. It opens `/` (and expects
to be sent to the login page), `/users/log-in`, `/help`, `/changelog` and
`/tools`, and looks at them.

**It is read-only and must stay that way.** It never submits a form, never
signs in, never creates an account. A check that needs to write something is
a browser test, against the test database - not a smoke check against
somebody's tournaments.
