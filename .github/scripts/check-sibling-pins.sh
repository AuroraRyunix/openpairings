#!/usr/bin/env bash
# Pin drift: does this repo pin a sibling at a version older than the
# sibling's latest release?
#
# The chess programs depend on each other by git tag (mix.exs:
# `github: "teapot-chess/<Repo>", tag: "vX.Y.Z"`), and a pin only moves when
# somebody moves it. Nothing complains when the sibling ships a fix and this
# repo keeps building against the old one, which is how a bug fixed upstream
# stays alive downstream for weeks. This asks, and fails (red) when the answer
# is "behind".
#
# What it reads: every teapot-chess git-tag pin in mix.exs, and the tag
# mix.lock holds for the same repo (a lock that disagrees with mix.exs is a
# half-done bump). What it compares against: the sibling's latest GitHub
# release (`gh release view`), which is the thing people are told to use.
#
# Identical in every consumer repo on purpose: copy it, do not edit one copy.
# Needs `gh` and a token in GH_TOKEN (the workflow passes the job's own); the
# siblings are public, so no extra secret is involved. A private sibling would
# need one with read access, and this will say so when `gh` is refused.
#
# Exit 0: every pin is on the latest release (or ahead of it).
# Exit 1: at least one pin is behind, the lock disagrees, a release could not
#         be read, or no pin was found at all (a script that finds nothing is
#         broken, not satisfied).

set -euo pipefail

org="teapot-chess"
mix_file="${MIX_FILE:-mix.exs}"
lock_file="${LOCK_FILE:-mix.lock}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ ! -f "$mix_file" ]; then
  echo "::error::$mix_file not found; run this from the repository root."
  exit 1
fi

# Newlines folded to spaces so a dependency written over several lines is
# still one match.
pins=$(tr '\n' ' ' < "$mix_file" \
  | grep -oE "github: *\"$org/[A-Za-z0-9_.-]+\", *tag: *\"[^\"]+\"" || true)

if [ -z "$pins" ]; then
  echo "::error::No $org git-tag pins found in $mix_file. Either they moved or this script is stale."
  exit 1
fi

status=0
{
  echo "### Sibling pins"
  echo
  echo "| Sibling | Pinned | Latest release | |"
  echo "|---|---|---|---|"
} >> "$summary"

while IFS= read -r pin; do
  repo=$(sed -E "s|.*\"$org/([^\"]+)\".*|\1|" <<< "$pin")
  pinned=$(sed -E 's|.*tag: *"([^"]+)".*|\1|' <<< "$pin")

  if ! latest=$(gh release view --repo "$org/$repo" --json tagName --jq .tagName 2>&1); then
    echo "::error::Could not read the latest release of $org/$repo: $latest"
    echo "| $repo | $pinned | unreadable | red |" >> "$summary"
    status=1
    continue
  fi

  if [ "$pinned" = "$latest" ]; then
    echo "$repo: pinned $pinned, latest release $latest. Current."
    echo "| $repo | $pinned | $latest | current |" >> "$summary"
  elif [ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -n 1)" = "$latest" ]; then
    echo "::error::$repo is pinned at $pinned and the latest release is $latest. Bump the tag in $mix_file, run mix deps.update $(echo "$repo" | tr '[:upper:]' '[:lower:]'), and check the changelog."
    echo "| $repo | $pinned | $latest | **behind** |" >> "$summary"
    status=1
  else
    echo "::notice::$repo is pinned at $pinned, ahead of its latest release $latest (an unreleased tag, or a release was deleted)."
    echo "| $repo | $pinned | $latest | ahead |" >> "$summary"
  fi

  # The lock must name the same tag, or `mix deps.get --check-locked` is about
  # to disagree with mix.exs and the pin that counts is the lock's.
  if [ -f "$lock_file" ]; then
    locked=$(grep -iE "/$org/$repo(\.git)?\"" "$lock_file" \
      | grep -oE "tag: *\"[^\"]+\"" | head -n 1 | sed -E 's|tag: *"([^"]+)"|\1|' || true)
    if [ -n "$locked" ] && [ "$locked" != "$pinned" ]; then
      echo "::error::$lock_file holds $repo at $locked but $mix_file pins $pinned."
      status=1
    fi
  fi
done <<< "$pins"

exit "$status"
