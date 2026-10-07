defmodule PairingsEngine.Repo.Migrations.AddGameIdentityToSentGames do
  @moduledoc """
  A stable identity for every game, and a database guard against sending
  one twice (the postponed-games audit of 2026-10-01, findings F1, F2, F4).

  ## `pairings.game_uid`

  A random identity a board keeps for life: it travels in every export,
  backup, snapshot and hand-off file and comes back with the board, so a
  restore that recreates the row under a new id still knows it is the same
  game. The sent-games record used to recognise a game by its round and its
  two players' keys (FIDE ID, or name) only - and a FIDE ID filled in, or a
  name corrected, between a snapshot and a restore made a sent game look
  unsent (sendable a second time) or an open one look unsent (its `?` mark
  lost, its late result never offered).

  Filled by the database, not by the code: a trigger gives every inserted
  board without one a fresh value, so no insert path (a pairing run, an
  import, a hand-off, a script) can forget it. A path that carries a board's
  identity (an import, a restore) writes it, and the trigger leaves it be.

  ## `trf_sent_games.game_uid`, `origin`, and the unique index

  Each record of a game sent now names the game it was. `origin` says where
  the record came from: `"sent"` - this installation sent it - or `"copy"`/
  `"import"`/`"handoff"`, a send another copy of the tournament made and
  this one learned about.

  The unique index - one `"sent"` record per game per kind of file - is the
  guard against two "Send…" requests racing each other: the second one's
  insert finds the first one's record and the send is refused, whatever its
  own reads said a moment before. Records from elsewhere are left out of it
  on purpose: if a game really did go out from two copies, both facts are
  kept.

  ## The records already there

  Each one is matched to the board it describes by round and players (the
  only identity it had). Nothing is deleted, ever:

    * a record that matches exactly one board takes that board's identity;
    * a record whose game is no longer in the tournament, or whose players
      two boards of its round share (two players with no FIDE ID and one
      name), keeps no identity and goes on being matched by players, as
      before - the record still blocks what it blocked;
    * a second `"sent"` record of a game already holding one (that game was
      sent twice before this guard existed) keeps no identity either, so the
      index can be built, and is logged here as a warning naming the
      tournament, round and kind. It stays in the record; the arbiter's
      page shows the game as sent, as it always did.
  """
  use Ecto.Migration

  import Ecto.Query
  require Logger

  def up do
    alter table(:pairings) do
      add :game_uid, :string
    end

    alter table(:trf_sent_games) do
      add :game_uid, :string
      add :origin, :string, null: false, default: "sent"
    end

    flush()

    execute("UPDATE pairings SET game_uid = lower(hex(randomblob(16))) WHERE game_uid IS NULL")

    execute("""
    CREATE TRIGGER pairings_game_uid_default AFTER INSERT ON pairings
    FOR EACH ROW WHEN NEW.game_uid IS NULL
    BEGIN
      UPDATE pairings SET game_uid = lower(hex(randomblob(16))) WHERE id = NEW.id;
    END
    """)

    flush()
    backfill_sent_games()

    create index(:pairings, [:game_uid])

    create unique_index(:trf_sent_games, [:tournament_id, :kind, :game_uid],
             name: :trf_sent_games_one_send_per_game,
             where: "game_uid IS NOT NULL AND origin = 'sent'"
           )
  end

  def down do
    drop index(:trf_sent_games, [:tournament_id, :kind, :game_uid],
           name: :trf_sent_games_one_send_per_game
         )

    drop index(:pairings, [:game_uid])
    execute("DROP TRIGGER IF EXISTS pairings_game_uid_default")

    alter table(:trf_sent_games) do
      remove :game_uid
      remove :origin
    end

    alter table(:pairings) do
      remove :game_uid
    end
  end

  defp backfill_sent_games do
    repo = repo()

    sent =
      repo.all(
        from(s in "trf_sent_games",
          order_by: [s.sent_at, s.id],
          select: %{
            id: s.id,
            tournament_id: s.tournament_id,
            round: s.round,
            white_key: s.white_key,
            black_key: s.black_key,
            kind: s.kind
          }
        )
      )

    tournament_ids = sent |> Enum.map(& &1.tournament_id) |> Enum.uniq()

    boards =
      Map.new(tournament_ids, fn tid -> {tid, boards_by_key(repo, tid)} end)

    Enum.reduce(sent, MapSet.new(), fn row, claimed ->
      case Map.get(boards[row.tournament_id], {row.round, row.white_key, row.black_key}, []) do
        [uid] ->
          if MapSet.member?(claimed, {row.tournament_id, row.kind, uid}) do
            Logger.warning(
              "trf_sent_games: tournament #{row.tournament_id}, round #{row.round}, " <>
                "#{row.kind}: this game was recorded as sent more than once before the " <>
                "one-send guard existed (record #{row.id}). Both records are kept; " <>
                "the later one is matched by players only."
            )

            claimed
          else
            repo.update_all(from(s in "trf_sent_games", where: s.id == ^row.id),
              set: [game_uid: uid]
            )

            MapSet.put(claimed, {row.tournament_id, row.kind, uid})
          end

        _none_or_ambiguous ->
          claimed
      end
    end)
  end

  # `{round, white key, black key} => [game_uid]` for one tournament's boards.
  # The key is the sent-games record's player key as it stood when this
  # migration was written (`PostponedGames.player_key/1`), copied here so a
  # later change to that function cannot change what this migration did.
  defp boards_by_key(repo, tournament_id) do
    players =
      repo.all(
        from(p in "players",
          where: p.tournament_id == ^tournament_id,
          select: {p.id, %{fide_id: p.fide_id, name: p.name}}
        )
      )
      |> Map.new()

    repo.all(
      from(p in "pairings",
        join: r in "rounds",
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id,
        select: {r.number, p.white_player_id, p.black_player_id, p.game_uid}
      )
    )
    |> Enum.group_by(
      fn {round, w, b, _uid} -> {round, key(players[w]), key(players[b])} end,
      fn {_round, _w, _b, uid} -> uid end
    )
  end

  defp key(nil), do: nil
  defp key(%{fide_id: id}) when is_integer(id) and id > 0, do: "fide:#{id}"

  defp key(%{name: name}),
    do: "name:" <> (name |> to_string() |> String.trim() |> String.downcase())
end
