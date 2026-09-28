defmodule PairingsEngine.Repo.Migrations.AutomaticPublishingLadder do
  @moduledoc """
  The automation ladder on Settings -> OpenResults (2026-09-28): `publish_mode`
  changes from "when does a round's pairing sheet go public" (immediate,
  manual, timed, scheduled) to "how far up the per-round ladder does the
  automation move each round" (manual, pairings, results, standings) - see
  `PairingsEngine.Tournaments.Tournament`'s `@publish_modes` and the
  "Automatic publishing" section of `PairingsEngine.Tournaments`.

  Adds `rounds.publish_cap` (the level a round was taken down to by hand,
  which the automation then stops at), and converts every tournament and
  every account's stored tournament defaults.

  ## The conversion, and why nothing public changes

  `Tournament.legacy_publish_mode/2` is the mapping, shared with the import
  of an older backup: manual -> by hand, timed -> pairings (its delay kept),
  immediate -> standings, scheduled -> by hand; one step lower where the
  retired "Standings" page switch was off, and by hand where the retired
  "Round pairings" switch was off. Those two switches stay stored and keep
  their pages hidden until the arbiter shows them again, so no page appears.

  "immediate" is the one mode whose public state was never stored: every
  paired round, its results and the standings through every finished round
  were public whatever the rows said. Its rounds are therefore written as
  what spectators were seeing - `published_at` set on every round that has
  none, the results switch on - and where the new automation stops short of
  standings, `standings_through` is raised to the finished prefix it was
  showing. A tournament converted to the standings step needs no more: that
  step computes the same prefix.

  The before-round-1 entry list is unaffected. Its switch moved from the
  Standings page to Settings -> OpenResults and reads the same stored value
  (`standings_through` set or not), so a tournament that had published it
  has it on, and the rest have it off - which is also the new default.

  Down drops the column and maps the modes back as far as they go (pairings
  -> timed, results/standings -> immediate); the rounds written for
  immediate tournaments stay written, which is what they showed anyway.
  """
  use Ecto.Migration

  import Ecto.Query

  alias PairingsEngine.Tournaments.Tournament

  def up do
    alter table(:rounds) do
      add :publish_cap, :integer
    end

    flush()

    backfill(repo())
  end

  def down do
    for {new, old} <- [
          {"pairings", "timed"},
          {"results", "immediate"},
          {"standings", "immediate"}
        ] do
      repo().update_all(from(t in "tournaments", where: t.publish_mode == ^new),
        set: [publish_mode: old]
      )
    end

    alter table(:rounds) do
      remove :publish_cap
    end
  end

  # Public so a test can run the data half against rows it built, without
  # rolling the schema back and forth under the SQL sandbox.
  @doc false
  def backfill(repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tournaments =
      repo.all(
        from(t in "tournaments",
          select: %{
            id: t.id,
            publish_mode: type(t.publish_mode, :string),
            public_display: type(t.public_display, :map),
            standings_through: type(t.standings_through, :integer)
          }
        )
      )

    for t <- tournaments, Tournament.legacy_publish_mode?(t.publish_mode) do
      mode = Tournament.legacy_publish_mode(t.publish_mode, t.public_display)

      if t.publish_mode == "immediate" do
        materialise_immediate(repo, t, mode, now)
      end

      repo.update_all(from(tt in "tournaments", where: tt.id == ^t.id),
        set: [publish_mode: mode]
      )
    end

    convert_account_defaults(repo)
  end

  defp materialise_immediate(repo, t, mode, now) do
    repo.update_all(
      from(r in "rounds",
        where: r.tournament_id == ^t.id and is_nil(r.published_at),
        update: [set: [published_at: type(^now, :utc_datetime)]]
      ),
      []
    )

    # `type/2`, because a schemaless query has no field type to dump a bare
    # `true` through, and SQLite then stores the TEXT "true" - which the
    # `Round` schema refuses to load (the note in
    # `20260913150000_add_rounds_results_public.exs`).
    repo.update_all(
      from(r in "rounds",
        where: r.tournament_id == ^t.id,
        update: [set: [results_public: type(^true, :boolean)]]
      ),
      []
    )

    if Tournament.auto_publish_level(mode) < 3 do
      finished = finished_prefix(repo, t.id)

      if finished > 0 and finished > (t.standings_through || 0) do
        repo.update_all(from(tt in "tournaments", where: tt.id == ^t.id),
          set: [standings_through: finished]
        )
      end
    end
  end

  # The deepest N with rounds 1..N all finished - every round is public by
  # now, so this is what immediate mode's standings went through. Same
  # reading as `PairingsEngine.Pairing.round_complete?/2`, over raw queries
  # for the reason `20260911130000_add_standings_through.exs` gives.
  defp finished_prefix(repo, tournament_id) do
    numbers =
      repo.all(from(r in "rounds", where: r.tournament_id == ^tournament_id, select: r.number))

    open =
      repo.all(
        from(p in "pairings",
          join: r in "rounds",
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and p.result == "",
          distinct: true,
          select: r.number
        )
      )

    finished = MapSet.difference(MapSet.new(numbers), MapSet.new(open))
    contiguous_from(finished, 0)
  end

  defp contiguous_from(set, n) do
    if MapSet.member?(set, n + 1), do: contiguous_from(set, n + 1), else: n
  end

  # `users.tournament_defaults` carries a `publish_mode` too, handed to every
  # new tournament's changeset - an old value there would make "New
  # tournament" fail validation.
  defp convert_account_defaults(repo) do
    users =
      repo.all(
        from(u in "users",
          where: not is_nil(u.tournament_defaults),
          select: %{id: u.id, defaults: type(u.tournament_defaults, :map)}
        )
      )

    for %{defaults: %{"publish_mode" => old} = defaults} = user <- users,
        Tournament.legacy_publish_mode?(old) do
      defaults = Map.put(defaults, "publish_mode", Tournament.legacy_publish_mode(old, nil))

      repo.update_all(
        from(u in "users",
          where: u.id == ^user.id,
          update: [set: [tournament_defaults: type(^defaults, :map)]]
        ),
        []
      )
    end

    :ok
  end
end
