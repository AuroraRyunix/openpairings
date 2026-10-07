defmodule PairingsEngine.Repo.Migrations.AddStandingsThrough do
  @moduledoc """
  Replaces `publish_starting_rank` (a single before-round-1 on/off flag) with
  `standings_through` - the per-tournament "public standings go up to round
  S" value the 2026-09-11 publish-model rewrite introduces. See
  `PairingsEngine.Tournaments.Tournament`'s field doc for the new field's
  full meaning and `PairingsEngine.Snapshot` for how it drives the payload.

  `nil` now means what `publish_starting_rank: false` plus "nothing
  published" used to mean - withhold the roster entirely. `0` means what
  `publish_starting_rank: true` meant - the roster travels, in start order,
  with no round's standings yet. `N > 0` is new: standings after round N are
  public, which used to have no dedicated control at all (only
  `Tournaments.standings_through_round/1`'s always-on computation).

  ## The data migration is the point

  Dropping the column without translating every existing tournament's flag
  would take an already-public roster dark the moment this ships, for any
  tournament that has `publish_starting_rank: true` and no round published
  yet - exactly the common case, since the flag defaulted to true. So every
  row is walked once, here, and given the `standings_through` its OWN public
  page already implies: the deepest published-and-complete round prefix
  (`contiguous`), falling back to `nil` only in the one case that used to
  mean "nothing to show at all" - nothing published AND the flag off.

  `legacy_standings_through/3` is the one piece of this rule that outlives
  the migration: `PairingsEngine.TournamentImport` needs the identical
  conversion for a backup file written before this field existed, which
  still carries `publish_starting_rank` and no `standings_through` key. It
  is intentionally a **pure** three-argument function (a prefix, a flag, a
  boolean) with no schema or query inside it, so calling it from here does
  not carry the drift risk `20260911110000_migrate_legacy_category_rules.exs`
  documents for calling application code from a migration - there is no
  live computation underneath it to drift FROM, only three already-known
  values and one conditional. Everything that gathers those three values
  (raw `tournaments`/`rounds`/`pairings` queries, deliberately not the
  `Tournament`/`Round`/`Pairing` schemas, for the same reason those two
  precedent migrations give) stays in this file.
  """
  use Ecto.Migration

  import Ecto.Query

  alias PairingsEngine.Tournaments.Tournament

  def up do
    alter table(:tournaments) do
      add :standings_through, :integer
    end

    # The new column must exist before the backfill queries/writes it.
    flush()

    backfill(repo())

    alter table(:tournaments) do
      remove :publish_starting_rank
    end
  end

  def down do
    alter table(:tournaments) do
      add :publish_starting_rank, :boolean, default: true, null: false
    end

    flush()

    # Lossy, like every down in this family (see
    # `20260829090000_drop_public_pages_enabled.exs`): there is no way back
    # to "which round" a withdrawn `standings_through` used to name, only to
    # whether the roster showed at all. `nil` (withheld) comes back false;
    # anything else - including every ordinary "public since round N" - comes
    # back true, which is the field's own pre-feature default and was the
    # true value for the overwhelming majority of tournaments.
    repo().update_all(
      from(t in "tournaments", where: is_nil(t.standings_through)),
      set: [publish_starting_rank: false]
    )

    repo().update_all(
      from(t in "tournaments", where: not is_nil(t.standings_through)),
      set: [publish_starting_rank: true]
    )

    alter table(:tournaments) do
      remove :standings_through
    end
  end

  defp backfill(repo) do
    now = DateTime.utc_now()

    tournaments =
      repo.all(
        from(t in "tournaments",
          select: %{
            id: t.id,
            publish_mode: type(t.publish_mode, :string),
            publish_starting_rank: type(t.publish_starting_rank, :boolean)
          }
        )
      )

    rounds_by_tournament =
      repo.all(
        from(r in "rounds",
          select: %{
            id: r.id,
            tournament_id: r.tournament_id,
            number: r.number,
            published_at: type(r.published_at, :utc_datetime)
          }
        )
      )
      |> Enum.group_by(& &1.tournament_id)

    incomplete_round_ids =
      repo.all(from(p in "pairings", where: p.result == "", distinct: true, select: p.round_id))
      |> MapSet.new()

    Enum.each(tournaments, fn t ->
      rounds = Map.get(rounds_by_tournament, t.id, [])
      published? = fn round -> round_published?(t.publish_mode, round.published_at, now) end

      ready =
        rounds
        |> Enum.filter(&(published?.(&1) and not MapSet.member?(incomplete_round_ids, &1.id)))
        |> MapSet.new(& &1.number)

      contiguous = contiguous_from(ready, 0)
      any_published? = Enum.any?(rounds, published?)

      standings_through =
        Tournament.legacy_standings_through(contiguous, any_published?, t.publish_starting_rank)

      repo.update_all(
        from(tt in "tournaments", where: tt.id == ^t.id),
        set: [standings_through: standings_through]
      )
    end)
  end

  # Same reading as `Tournaments.round_published?/2` (unaffected by this
  # migration - reproduced here rather than called, per this file's own
  # moduledoc on why the queries above stay raw).
  defp round_published?("immediate", _published_at, _now), do: true
  defp round_published?(_mode, nil, _now), do: false
  defp round_published?(_mode, published_at, now), do: DateTime.compare(published_at, now) != :gt

  defp contiguous_from(set, n) do
    if MapSet.member?(set, n + 1), do: contiguous_from(set, n + 1), else: n
  end
end
