defmodule PairingsEngine.Repo.Migrations.AddTournamentHandoff do
  @moduledoc """
  Moving a tournament between the hosted service and a local copy.

  ## Why a lock and not a sync

  A tournament is not a document. Two copies that both accepted writes
  cannot be merged afterwards: one machine recorded 1-0 on board 4 and the
  other recorded a draw, or both paired round 6 and produced different
  boards. There is no rule that picks a winner, because the disagreement is
  about what actually happened in a room. So the model is a hand-off, not a
  replication: the tournament is LIVE in exactly one place at a time, like a
  book checked out of a library, and the copy left behind goes read-only
  until the other one comes back.

  Three columns, one per question the lock has to answer.

  ## `handed_off_at`

  Whether this copy currently holds the lock. NULL - the state every
  existing tournament gets, so this migration cannot change the behaviour of
  anything already running - means "live here, writable". Set means "checked
  out; this copy is a read-only record until it is taken back".

  Deliberately a timestamp rather than a boolean, and deliberately a separate
  nullable column rather than a `status` value, for the same two reasons
  `archived_at` is (see `20260813160000_add_tournament_archived_at.exs`):
  `tournaments.status` is DERIVED and would be recomputed away, and the
  banner has to be able to say WHEN it left, not just that it did. "Handed
  off" with no date is the kind of message an arbiter cannot act on.

  ## `handed_off_to`

  A human label for where it went - "this laptop", a hostname, a server
  address. Free text on purpose: the two ends of a hand-off are not
  necessarily peers that know each other's identifiers, and the only
  consumer is a person reading a banner that has to answer "so where IS it?".
  An enum or a foreign key would be a guess at a topology this feature does
  not have.

  ## `handoff_token`

  A CSPRNG value minted at hand-off and required to take the tournament
  back. This is what stops a returning payload from being merely *asserted*:
  without it, anything that could reach this row could clear the lock and
  make a second live copy, which is precisely the state the whole design
  exists to prevent. Compared with `Plug.Crypto.secure_compare/2` at the
  door - see `PairingsEngine.Tournaments.take_back/2`.

  Not indexed and not unique. It is a per-row secret presented alongside the
  tournament it unlocks, never a lookup key, so an index would only widen
  what a database dump gives away for free.

  ## No index on `handed_off_at` either

  Unlike `archived_at`, which every listing path filters on, nothing lists
  by hand-off state: a handed-off tournament stays exactly where it was in
  the list, just read-only. The one hot read is
  `Tournaments.ensure_writable/1` by id, which is a primary-key lookup. An
  index here would be speculation.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :handed_off_at, :utc_datetime
      add :handed_off_to, :string
      add :handoff_token, :string
    end
  end
end
