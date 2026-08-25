# GitHub repository info

Generated 2026-08-25 from the live GitHub API plus local git state.
**Regenerate rather than hand-edit** - the previous version sat at
2026-07-25 for a month still claiming 59 commits, and nothing flagged it.
(The "no tags" it also claimed happens to still be true.)

## Repository

- **URL**: https://github.com/AuroraRyunix/openpairings
- **Owner/repo**: `AuroraRyunix/openpairings`
- **Visibility**: public
- **Description**: OpenPairings: Elixir/Phoenix chess tournament manager
- **Primary language**: Elixir
- **License**: none set
- **Created**: 2026-07-12
- **Last push**: 2026-08-25

## Local git state

- **Commits on `main`**: 359
- **HEAD**: `0c78206 Record a game that was played but is not rated`
- **Tracked files**: 375
- **First commit**: 2026-07-10 (predates the GitHub repo - the project was
  local for two days before being pushed)
- **Remote branches**: `main` only. Every feature branch has been merged
  and deleted after its PR landed; there is no standing branch other than
  `main`.
- **Tags / releases**: still none. `.github/workflows/binaries.yml` is
  wired to build and attach the five Burrito standalone targets as release
  assets the first time a `v*` tag is pushed (see
  [`binaries.md`](binaries.md)). That has not happened yet.

## Contributors

| Login | Commits |
| --- | --- |
| AuroraRyunix | 300 |
| Iudex Aurora | 59 |

Two identities, one maintainer - the second is an older local git
`user.name` from before the machine was reconfigured, not a second person.

## Pull requests and issues

- 18 pull requests opened to date: **17 merged, 1 closed unmerged**.
- 0 open pull requests, 0 open issues.

The working pattern changed partway through: early work went through
feature branch to PR to merge, later work commits directly to `main` after
a green suite. Both are visible in the history.

## CI

- `.github/workflows/elixir.yml` - compile, format check and the full test
  suite on every push.
- `.github/workflows/binaries.yml` - cross-builds the five Burrito targets
  (macOS x86_64 + aarch64, Linux x86_64 + aarch64, Windows x86_64); uploads
  them as workflow artifacts on every run, and as release assets on a `v*`
  tag push.

## Notes

- Repository size per the GitHub API is ~5.5 MB; the local `.git` is 6.3 MB.
  Both exclude everything gitignored: `deps/`, `_build/`, the local SQLite
  databases, the JaVaFo jar, and the real anonymised-personal-data `.swar`
  fixtures.
- The sibling pairing engine lives in its own repository,
  <https://github.com/AuroraRyunix/Ainalrami>, and is consumed here as a
  tagged Hex-style git dependency rather than vendored.
