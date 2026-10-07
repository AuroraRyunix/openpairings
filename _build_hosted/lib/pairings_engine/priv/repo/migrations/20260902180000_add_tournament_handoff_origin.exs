defmodule PairingsEngine.Repo.Migrations.AddTournamentHandoffOrigin do
  @moduledoc """
  Where a copy that ARRIVED by hand-off remembers where it came from.

  ## The two states are opposites, and one column cannot hold both

  `20260902160000_add_tournament_handoff.exs` added three columns that answer
  one question: has this copy been handed AWAY. `handed_off_at` is the lock,
  `handed_off_to` names the machine that now holds the tournament, and
  `handoff_token` is the secret that machine must present to give it back.

  This column answers the mirror question: did this copy ARRIVE from
  somewhere, and what is the key that unlocks the copy left behind. Both are
  about a hand-off and they look superficially like the same fact, which is
  exactly why they must not share storage.

  Reusing `handoff_token`/`handed_off_to` with a direction flag was the
  obvious cheaper option and it is wrong three separate ways:

    * A received copy is LIVE. `handed_off_at` must be nil on it or every
      write is refused (`PairingsEngine.Tournaments.ensure_writable/1`), and
      `handoff_token_matches?/2` deliberately refuses to compare a token
      while `handed_off_at` is nil. So the borrowed key would sit in a column
      whose own module treats it as meaningless.
    * `PairingsEngine.Tournaments.hand_off/2` OVERWRITES `handoff_token` with
      a freshly minted one. Handing a received copy onward to a third machine
      would therefore destroy the key that unlocks the original - silently,
      and at the exact moment the chain gets long enough for it to matter.
    * The two states can be true AT ONCE. A tournament can have come from A
      and be handed off to C right now. That is two destinations and two
      tokens; a single column plus a flag can hold one. A UI reading it would
      have to pick which of the two truths to print, and printing the wrong
      one ("this went to A") sends an arbiter to the wrong machine.

  So: a separate nullable `:map`, on the same pattern as
  `tournaments.openresults_claim` - a credential that arrived in a file, held
  where nothing else can trip over it. Written only by
  `PairingsEngine.Handoff`.

  ## Shape

      %{
        "instance"       => "the-club-pc",      # who sent it, as a name
        "address"        => "https://...",      # and where it lives, if it has one
        "label"          => "this laptop",      # what THEY called this machine
        "release_token"  => "<43 chars>",       # the key that unlocks their copy
        "handed_off_at"  => "2026-09-02T20:00:00Z",
        "received_at"    => "2026-09-02T20:05:00Z"
      }

  Free-form rather than columns because every field except the token is
  descriptive text for a person reading a screen, and because the two ends of
  a hand-off are not peers that agree on identifiers - the same reasoning
  that made `handed_off_to` free text.

  ## Not indexed

  The one query that reads it is "has this machine already received this
  hand-off", which walks the handful of rows that have a non-null value at
  all and compares the token in constant time. An index on a JSON blob would
  buy nothing and would put a per-row secret into a second on-disk structure.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :handoff_origin, :map
    end
  end
end
