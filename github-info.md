# GitHub repository info

Generated 2026-07-25, from the live GitHub API + local git state after the
documentation/cleanup restructuring pass. Regenerate rather than hand-edit
if it goes stale.

## Repository

- **URL**: https://github.com/AuroraRyunix/openpairings
- **Owner/repo**: `AuroraRyunix/openpairings`
- **Visibility**: public
- **Description**: OpenPairings: Elixir/Phoenix chess tournament manager
- **Primary language**: Elixir
- **License**: none set
- **Created**: 2026-07-12
- **Last push**: 2026-07-25 (this session's commits)

## Remote (local clone)

- **Remote name**: `origin`
- **Remote URL**: `https://github.com/AuroraRyunix/openpairings.git`
- **Default branch**: `main`
- **Active branch**: `main`
- **Branches on GitHub**: `main` only — every feature branch created during
  development has been merged and deleted after each PR lands; there is no
  standing branch other than `main`.
- **Tags / releases**: none yet. `.github/workflows/binaries.yml` is wired
  to build and attach standalone binaries as release assets the first time
  a `v*` tag is pushed (see [`docs/binaries.md`](docs/binaries.md)) — that
  hasn't happened yet.

## Latest commit on `main`

```
3e5cacf Restructure project documentation, add deep AI-agent context
```

## Contributors

| Login | Contributions (commits) |
| --- | --- |
| AuroraRyunix | 59 |

## Pull requests

- 18 pull requests opened to date, 17 merged (the standard workflow for
  this repo: every feature/fix branch → PR → merge → branch deleted).
- 0 currently open pull requests, 0 open issues.

## CI

- `.github/workflows/elixir.yml` — Elixir compile/format/test checks on
  every push.
- `.github/workflows/binaries.yml` — builds the five Burrito standalone
  targets; uploads as workflow artifacts on every run, and as GitHub
  release assets on a `v*` tag push.

## Notes

- Repository size per the GitHub API: ~1.9 MB (source only — this excludes
  everything gitignored: `deps/`, `_build/`, local SQLite databases, the
  JaVaFo jar, and the real anonymized-personal-data `.swar` test fixture).
- The repository was previously located at a different local path on the
  maintainer's machine (`Desktop/pairingsengine`) and was moved to
  `Desktop/02cloud/VPS projects/openpairings` on 2026-07-25 — a purely
  local reorganization with no effect on the remote history above.
