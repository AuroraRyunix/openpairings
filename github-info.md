# GitHub repository info

What is true about this repository on GitHub that you cannot see from a
checkout: the licence, the branch policy, what CI does, and why the commit
history shows two names.

**This file used to carry live counters** - commit count, HEAD, tracked
files, "tags: still none" - under an instruction to regenerate rather than
hand-edit. Nothing regenerated it, twice: it sat at 2026-07-25 for a month
claiming 59 commits, was rewritten on 2026-08-25, and by 2026-09-08 was
claiming no licence and no tags when the repository had an Elastic licence
and thirty-two of them. A counter in a checked-in file is stale the next
time anyone commits, and no instruction fixes that. So the counters are
gone. Every one of them was a `git` command away:

```
git rev-list --count main        # commits
git ls-files | wc -l             # tracked files
git tag | wc -l                  # tags
gh repo view --json pushedAt,diskUsage,licenseInfo
```

Last checked against live GitHub and local git: **2026-09-08**.

## Repository

- **URL**: https://github.com/AuroraRyunix/openpairings
- **Owner/repo**: `AuroraRyunix/openpairings`
- **Visibility**: public
- **Description**: OpenPairings: Elixir/Phoenix chess tournament manager
- **Primary language**: Elixir
- **Licence**: **Elastic License 2.0** - source-available, not open source.
  The GitHub API reports `licenseInfo.key: "other"` and the sidebar says
  "Other"; that is correct and expected, because GitHub's licence detector
  only names the licences on its own list. See [`LICENSE`](LICENSE) and the
  reasoning in [`README.md`](README.md).
- **Created**: 2026-07-12. The first commit predates that by two days - the
  project was local before it was pushed.

## Branches, tags and releases

- **`main` is the only branch.** Every feature branch has been merged and
  deleted after landing; there is no standing branch beside it.
- **Tagged releases from `v0.18.0` onward**, one per release, cut whenever
  a batch of work is finished rather than on a schedule.
- Pushing a `v*` tag makes `.github/workflows/binaries.yml` build the five
  Burrito standalone targets and attach them to the release. See
  [`docs/binaries.md`](docs/binaries.md).

## Contributors

Two identities, one maintainer. `Iudex Aurora` is an older local git
`user.name` from before the machine was reconfigured; `AuroraRyunix` is
everything since. Not a second person, and worth knowing before anyone
reads the history as collaborative.

## Pull requests and issues

The working pattern changed partway through, and both halves are visible in
the history: early work went feature branch to pull request to merge, later
work commits directly to `main` behind a green suite. Roughly two dozen
pull requests exist from the first period, most merged; there are normally
no open ones and no open issues.

## CI

- `.github/workflows/elixir.yml` - `mix deps.get --check-locked`, compile
  with warnings as errors, a format check, and the full test suite, on
  every push and pull request to `main`.
- `.github/workflows/binaries.yml` - cross-builds the five Burrito targets
  (macOS x86_64 and aarch64, Linux x86_64 and aarch64, Windows x86_64),
  **starts each built binary and curls it** rather than only compiling it,
  uploads them as workflow artifacts on every run, and attaches them as
  release assets on a `v*` tag.
- `.github/dependabot.yml` - weekly, GitHub Actions only. Both workflows
  pin every third-party action to a commit SHA with the version tag as a
  trailing comment; Dependabot moves the SHA and the comment together.

## Notes

- The repository is a few megabytes larger on disk locally than on GitHub -
  both exclude everything gitignored: `deps/`, `_build/`, the local SQLite
  databases, the JaVaFo jar, and the anonymised-personal-data `.swar`
  fixtures.
- The sibling pairing engine lives in its own repository,
  <https://github.com/AuroraRyunix/Ainalrami>, and is consumed here as a
  tagged git dependency rather than vendored - so the version of the engine
  this app pairs with is a line in `mix.exs`, not a copy of its source.
