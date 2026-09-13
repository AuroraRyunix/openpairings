# Self-hosted runner: SWAR and JaVaFo tests

`.github/workflows/artifact-tests.yml` runs the ~111 tests that CI otherwise
skips: 51 tagged `:swar_fixture` (need the real `.swar` fixture files, which
can never be committed - see `.gitignore` and `test/test_helper.exs`) and 61
tagged `:javafo` (need the third-party `javafo.jar`, which is not ours to
redistribute). Background: `docs/test-quality-2026-09-13.md`, section
"Proposal: a self-hosted runner that already holds the files".

Those tests need a machine that already legitimately holds those files -
today, the maintainer's own PC. This doc sets that machine up as a GitHub
Actions self-hosted runner.

## 1. Register the runner

This repository is **public**. GitHub self-hosted runners on a public repo
must be handled carefully - see "Security" below before registering one.

1. On GitHub: **Settings -> Actions -> Runners -> New self-hosted runner**.
2. Choose **Windows** (the workflow's `runs-on` includes the `windows`
   label) and the architecture that matches this PC.
3. Follow GitHub's own download and `config.cmd` steps, exactly as shown on
   that page. GitHub gives you a **one-time registration token** as part of
   that command.

   **Never paste that token anywhere else** - not into a chat, an issue, a
   commit, a script, or anyone who asks for it. It is credential material
   that can register a runner against this repository. It expires quickly
   and is only meant to be pasted once, directly from that GitHub settings
   page into your own terminal, by you.
4. When `config.cmd` asks for runner labels, add **`openpairings-artifacts`**
   (in addition to the `self-hosted` and `windows` labels GitHub adds
   automatically) - the workflow's `runs-on: [self-hosted, windows,
   openpairings-artifacts]` only matches a runner carrying all three.
5. Install it as a **service**, so it survives reboots and keeps listening
   for jobs without a logged-in session:

   ```
   .\svc.cmd install
   .\svc.cmd start
   ```

   Run the service as an ordinary user account, not an admin account (see
   "Security" below).

## 2. Prerequisites on this machine

- **Erlang/Elixir**: whatever `mix.exs` currently requires (`elixir: "~>
  1.17"` as of this writing - check `mix.exs` for the live requirement). The
  workflow's "Verify Elixir/Erlang toolchain" step checks this and fails
  clearly if the installed `elixir --version` doesn't satisfy it; it does
  **not** install or change your toolchain.
- **Java**, if the pairing tests call `java -jar javafo.jar` (they do - see
  `PairingsEngine.Pairing.javafo_jar/0` and its callers in
  `lib/pairings_engine/pairing.ex`). Any JRE recent enough to run JaVaFo
  works; install it the way you already install Java on this PC.

The workflow deliberately does **not** install or provision either of
these - it uses whatever is already on this machine's `PATH`, the same way
you'd run `mix test` here yourself.

## 3. Artifacts

Create one folder on this machine holding exactly these four files:

- `c-reeks.swar`
- `problemski.swar`
- `test3-321.swar`
- `javafo.jar`

(These are the same files `test/test_helper.exs` looks for locally, just
collected in one place instead of already sitting in `test/fixtures/` and
`priv/javafo/`.)

Then set the environment variable `OPENPAIRINGS_ARTIFACTS` to that folder's
path, **for the account the runner service runs as**. Two ways to do that:

- **A machine-level environment variable.** System Properties -> Advanced ->
  Environment Variables -> System variables -> New: name
  `OPENPAIRINGS_ARTIFACTS`, value the folder path. A Windows service reads
  machine-level (not just user-level) environment variables, so this is the
  simplest option for a service account.
- **The runner's own `.env` file**, in the runner's install folder (next to
  `config.cmd`). Add a line:

  ```
  OPENPAIRINGS_ARTIFACTS=C:\path\to\the\artifacts\folder
  ```

  The runner service reads this file on start, so restart the service
  (`.\svc.cmd stop` then `.\svc.cmd start`) after creating or editing it.

Either way, restart the runner service afterwards so it picks up the
variable. The workflow's "Place the artifacts" step fails with a clear,
named error (which file, which folder) if `OPENPAIRINGS_ARTIFACTS` isn't
set, doesn't exist, or is missing one of the four files - it never silently
skips them the way a normal `mix test` run does locally.

## 4. Security

- **Pull requests never run this workflow, on purpose.** A self-hosted
  runner executes whatever code the triggering event checks out - on this
  real PC. Anyone can open a pull request against a public repo, so if this
  workflow ran on `pull_request` (or `pull_request_target`, which is worse:
  it can still be told to check out a fork's head while running with
  privileges from the base branch), anyone on the internet could get
  arbitrary code execution on this machine by opening a PR. The workflow's
  `on:` block only has `push` (to `main`) and `workflow_dispatch` - never
  add `pull_request` to it.
- Separately, for the *rest* of CI (the ordinary hosted `elixir.yml` job,
  which already only runs on GitHub-hosted runners): set **Settings ->
  Actions -> General -> "Require approval for all outside collaborators"**
  (or stricter). This makes any workflow run triggered by an outside
  contributor's PR wait for a maintainer to approve it before it runs at
  all, which is good practice independent of this runner.
- This runner only ever executes two things: a push that has already landed
  on `main` (i.e. something a maintainer pushed or merged), and a manual
  `workflow_dispatch` run a maintainer starts by hand. It never executes
  code from a pull request, a fork, or an untrusted ref.
- Run the runner service as a **normal user account**, not an
  administrator. The workflow doesn't need admin rights for anything it
  does (copying files, running `mix test`), and a compromised or buggy
  workflow step should not have more privilege on this PC than it needs.

## 5. Using it

- Results appear on GitHub under the **Actions** tab, as a separate
  workflow named **"SWAR and JaVaFo tests"** - distinct from the "Elixir CI"
  workflow that runs on every push and PR.
- If this PC is off or the runner service isn't running, a triggering push
  just leaves the job **queued**. It is not silently skipped and it does
  not fail anything else: `elixir.yml` (the normal hosted CI, and the
  binaries/release workflows) is a completely separate workflow file and is
  unaffected either way. A queued job eventually times out (the job's
  `timeout-minutes: 30`) if the runner never comes online for it.
- To trigger manually: **Actions -> SWAR and JaVaFo tests -> Run workflow**
  (this is what `workflow_dispatch` enables), and pick the branch (normally
  `main`).

## 6. Removing it

On GitHub: **Settings -> Actions -> Runners**, select the runner, **Remove**,
and follow the `config.cmd remove` command it shows (run on this PC, with a
fresh removal token the same way registration used one - again, never paste
that token anywhere else). Then, on this PC: `.\svc.cmd stop` and
`.\svc.cmd uninstall` to remove the service, and delete the runner's install
folder. Deleting the `OPENPAIRINGS_ARTIFACTS` folder or environment variable
is optional and has no effect on GitHub's side once the runner itself is
deregistered.
