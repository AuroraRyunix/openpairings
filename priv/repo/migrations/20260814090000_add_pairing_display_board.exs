defmodule PairingsEngine.Repo.Migrations.AddPairingDisplayBoard do
  use Ecto.Migration

  import Ecto.Query

  # Freezes what PairingDisplay used to compute live, every render, from
  # whatever a player's `fixed_board` happens to be RIGHT NOW. That was a
  # real, reported bug: giving a player a fixed (accessible/wheelchair)
  # table after their round was already paired silently renumbered every
  # board after theirs on an already-in-progress round - the 0.14.6 board-
  # renumbering class of bug, surviving in one narrower spot. A board's
  # displayed number and special/ordinary classification must be decided
  # once, at the moment the round is actually paired, and never move again
  # just because someone edited a player's fixed_board on an unrelated page
  # while people are already seated.
  #
  # `display_board` is the label to print (a plain "N" for an ordinary
  # board, the fixed_board value(s) for a special one - see
  # PairingsEngine.PairingDisplay); `display_special` is whether it counts
  # as special for row-ordering purposes. Both are set exactly once, by
  # PairingsEngine.Tournaments.freeze_round_display_boards!/1, at every
  # place a round's pairings are created (ordinary pairing, round-robin,
  # Keizer, and the three importers) - never touched again afterward, not
  # even by a later swap/vacate/fill edit on the same round.
  def change do
    alter table(:pairings) do
      add :display_board, :string
      add :display_special, :boolean, null: false, default: false
    end

    # Backfill every existing pairing using the exact algorithm
    # PairingDisplay used to run live, so this migration changes NOTHING
    # about what any existing round currently displays - it only freezes
    # today's already-correct computed values in place, stopping them from
    # ever drifting again. Deliberately self-contained (raw table queries,
    # no application schema/module) rather than calling
    # PairingsEngine.PairingDisplay directly, matching this repo's existing
    # backfill-migration precedent (see add_public_slug_to_tournaments.exs)
    # - a migration must keep producing the SAME result when replayed from
    # scratch years from now, even after that module has since changed.
    flush()
    backfill_display_boards()
  end

  defp backfill_display_boards do
    repo = repo()

    round_ids = repo.all(from(p in "pairings", distinct: true, select: p.round_id))

    Enum.each(round_ids, &backfill_round(repo, &1))
  end

  defp backfill_round(repo, round_id) do
    pairings =
      repo.all(
        from(p in "pairings",
          where: p.round_id == ^round_id,
          select: %{
            id: p.id,
            board: p.board,
            white_player_id: p.white_player_id,
            black_player_id: p.black_player_id
          }
        )
      )

    fixed_boards = load_fixed_boards(repo, pairings)

    special? = fn p ->
      Map.has_key?(fixed_boards, p.white_player_id) or
        Map.has_key?(fixed_boards, p.black_player_id)
    end

    {special, non_special} = Enum.split_with(pairings, special?)

    non_special
    |> Enum.sort_by(& &1.board)
    |> Enum.with_index(1)
    |> Enum.each(fn {p, i} -> write_label(repo, p.id, Integer.to_string(i), false) end)

    Enum.each(special, fn p ->
      label =
        [p.white_player_id, p.black_player_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.get(fixed_boards, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map_join("/", &to_string/1)

      write_label(repo, p.id, label, true)
    end)
  end

  defp load_fixed_boards(_repo, []), do: %{}

  defp load_fixed_boards(repo, pairings) do
    player_ids =
      pairings
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if player_ids == [] do
      %{}
    else
      repo.all(
        from(p in "players",
          where: p.id in ^player_ids and not is_nil(p.fixed_board),
          select: {p.id, p.fixed_board}
        )
      )
      |> Map.new()
    end
  end

  # `set:` here targets the raw "pairings" table name, not a schema, so
  # Ecto has no :boolean type info to encode `special?` through - it would
  # otherwise pass the literal Elixir `true`/`false` straight to the
  # driver, which SQLite stores as the literal TEXT "true"/"false" rather
  # than the integer 0/1 the app's Pairing schema expects when loading it
  # back. Confirmed in production: every backfilled row's display_special
  # came back as the string "false" (or "true"), and
  # `cannot load "false" as type :boolean` 500'd every page that touched a
  # pairing. Passing 0/1 directly sidesteps the missing type info entirely.
  defp write_label(repo, pairing_id, label, special?) do
    repo.update_all(
      from(p in "pairings", where: p.id == ^pairing_id),
      set: [display_board: label, display_special: if(special?, do: 1, else: 0)]
    )
  end
end
