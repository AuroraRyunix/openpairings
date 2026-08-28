defmodule PairingsEngine.PairingRestoreColumnsTest do
  @moduledoc """
  Three columns on `PairingsEngine.Tournaments.Pairing` are deliberately
  kept OUT of `changeset/2`'s cast list, each because it has exactly one
  legitimate writer: `display_board` and `display_special` (frozen once per
  round by `Tournaments.freeze_round_display_boards!/1`) and `hidden` (set
  only by `Tournaments.set_pairing_hidden/3`).

  That protection has a consequence nobody has to think about until a
  backup is restored: the restore recreates every pairing from a payload
  through that same changeset, so an uncast column it does not carry
  EXPLICITLY is dropped in silence. Cast ignores a key it was not given -
  there is no error, no warning, and the row lands on the schema default.

  Two of the three went missing exactly there:

    * `hidden` was passed in the changeset's attrs, where cast dropped it,
      so a restore still un-hid every board an arbiter had deliberately
      withheld from the public page. The export half of that had already
      been fixed once (the payload has carried `hidden` since), which is
      what made the remaining half so easy to miss - the value was right
      there in the file, and the importer threw it away.
    * `display_board`/`display_special` were not exported at all, and the
      importer re-froze every round from each player's fixed table AS OF
      THE RESTORE. A round played, printed and handed out as 1..5 came back
      renumbered - the retroactive renumbering `PairingsEngine.PairingDisplay`'s
      moduledoc exists to forbid.

  So this file pins the class, not just the two instances: for each uncast
  column, a value set through its one real writer survives the round trip,
  and a payload old enough not to carry it still restores safely.
  """

  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.Accounts.Scope

  alias PairingsEngine.{
    PairingDisplay,
    Repo,
    Snapshots,
    TournamentExport,
    TournamentImport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  # Four players on two boards, plus a third board nobody is sitting at -
  # the shape `set_pairing_hidden/3` accepts (both seats empty) and the only
  # one that can legally be hidden.
  defp fixture(opts \\ []) do
    pin = Keyword.get(opts, :pin)

    t =
      Repo.insert!(%Tournament{
        name: "Restore Columns",
        type: "swiss",
        pairing_system: "swiss",
        rounds_count: 1,
        public_slug: "restore-columns-#{System.unique_integer([:positive])}"
      })

    players =
      for n <- 1..4 do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: "Player#{n}, X.",
          fide_rating: 2000 - n,
          pairing_number: n
        })
      end

    round =
      Repo.insert!(%Round{
        tournament_id: t.id,
        number: 1,
        status: "playing",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    players
    |> Enum.chunk_every(2)
    |> Enum.with_index(1)
    |> Enum.each(fn {[w, b], board} ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id,
        result: "1-0"
      })
    end)

    vacant = Repo.insert!(%Pairing{round_id: round.id, board: 3, result: ""})

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    if pin do
      {player_number, value} = pin

      {:ok, _} =
        players
        |> Enum.at(player_number - 1)
        |> Player.changeset(%{"fixed_board" => to_string(value)})
        |> Repo.update()
    end

    {Repo.reload!(t), Repo.reload!(round), Repo.reload!(vacant)}
  end

  defp pairings(round_id) do
    Repo.all(
      from p in Pairing,
        where: p.round_id == ^round_id,
        order_by: p.board,
        preload: [:white_player, :black_player]
    )
  end

  defp labels(round_id) do
    round_id |> pairings() |> PairingDisplay.with_display_boards() |> Enum.map(& &1.board)
  end

  # What is actually FROZEN, keyed by the real board and so independent of
  # the row order `with_display_boards/1` chooses - the label and the
  # classification are what has to survive a restore; where a document
  # decides to print the row is a separate, deliberately live concern.
  defp frozen(round_id) do
    round_id
    |> pairings()
    |> Enum.map(&{&1.board, &1.display_board, &1.display_special})
  end

  defp scope, do: Scope.for_user(user_fixture())

  # A real backup is JSON on disk, and a snapshot payload is a `:map` column
  # that goes through the same encoder - so round-trip the envelope rather
  # than handing the importer the in-memory structs, which would let a value
  # survive that JSON could not carry.
  defp reimport(tournament) do
    envelope = tournament |> TournamentExport.export_tournament() |> encode_decode()
    assert {:ok, [copy]} = TournamentImport.import(envelope, scope())
    copy
  end

  defp encode_decode(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  defp map_pairings(envelope, fun) do
    update_in(
      envelope,
      ["tournaments", Access.at(0), "rounds", Access.at(0), "pairings"],
      &Enum.map(&1, fun)
    )
  end

  describe "hidden" do
    test "a board hidden by the arbiter is still hidden after a snapshot restore" do
      {t, round, vacant} = fixture()
      scope = scope()

      assert {:ok, _} = Tournaments.set_pairing_hidden(round, vacant, true)
      assert {:ok, snapshot} = Snapshots.capture(Repo.reload!(t), "test.capture", scope)

      # Un-hide it, then restore the backup taken while it was hidden.
      assert {:ok, _} =
               Tournaments.set_pairing_hidden(round, Repo.reload!(vacant), false)

      assert {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id, scope)

      restored_round = Tournaments.get_round(restored.id, 1)

      assert [%{board: 3, hidden: true}] =
               restored_round.id |> pairings() |> Enum.filter(& &1.hidden)
    end

    test "and after a plain backup export/import" do
      {t, round, vacant} = fixture()

      assert {:ok, _} = Tournaments.set_pairing_hidden(round, vacant, true)

      copy = reimport(Repo.reload!(t))
      copy_round = Tournaments.get_round(copy.id, 1)

      assert copy_round.id |> pairings() |> Enum.map(& &1.hidden) == [false, false, true]
    end

    test "a payload written before hidden was exported restores with nothing hidden" do
      {t, _round, _vacant} = fixture()

      envelope =
        t
        |> TournamentExport.export_tournament()
        |> encode_decode()
        |> map_pairings(&Map.delete(&1, "hidden"))

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())

      # The safe direction: an old backup comes back with every board
      # visible rather than with boards mysteriously missing from the
      # public page.
      copy_round = Tournaments.get_round(copy.id, 1)
      refute copy_round.id |> pairings() |> Enum.any?(& &1.hidden)
    end
  end

  describe "display_board / display_special" do
    test "the frozen labels come back exactly as they were printed" do
      # The pin lands AFTER the round is frozen, so the live round keeps a
      # plain 1..3 - the numbering the sheets on the tables show. A restore
      # that recomputed instead would move player 1's board to the bottom
      # and relabel it "9", which is the whole failure this pins.
      {t, round, _vacant} = fixture(pin: {1, 9})

      assert frozen(round.id) == [{1, "1", false}, {2, "2", false}, {3, "3", false}]
      assert labels(round.id) == ["1", "2", "3"]

      copy = reimport(t)
      copy_round = Tournaments.get_round(copy.id, 1)

      assert frozen(copy_round.id) == frozen(round.id)
      assert labels(copy_round.id) == ["1", "2", "3"]
    end

    test "a special board stays special, with its own label" do
      # Pinned BEFORE the freeze, so the label really is the fixed table and
      # the row really is classified special - both halves have to travel,
      # not just the string: `with_display_boards/1` groups on
      # `display_special`, so a lost boolean re-sorts the printed sheet.
      {t, round, _vacant} = fixture()

      players = Tournaments.list_players(t.id)

      {:ok, _} =
        players
        |> Enum.find(&(&1.pairing_number == 1))
        |> Player.changeset(%{"fixed_board" => "1001"})
        |> Repo.update()

      :ok = Tournaments.freeze_round_display_boards!(round.id)
      assert frozen(round.id) == [{1, "1001", true}, {2, "1", false}, {3, "2", false}]

      copy = reimport(Repo.reload!(t))
      copy_round = Tournaments.get_round(copy.id, 1)

      assert frozen(copy_round.id) == frozen(round.id)

      assert [%{board: 1, display_board: "1001"}] =
               copy_round.id |> pairings() |> Enum.filter(& &1.display_special)
    end

    test "a payload written before the columns existed is re-frozen instead" do
      {t, round, _vacant} = fixture()

      envelope =
        t
        |> TournamentExport.export_tournament()
        |> encode_decode()
        |> map_pairings(&(&1 |> Map.delete("display_board") |> Map.delete("display_special")))

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())
      copy_round = Tournaments.get_round(copy.id, 1)

      # There is nothing to restore, so recomputing from the round-tripped
      # players is the best available reconstruction - and it must actually
      # run: leaving every label nil would print real board numbers instead.
      refute copy_round.id |> pairings() |> Enum.any?(&is_nil(&1.display_board))
      assert frozen(copy_round.id) == frozen(round.id)
    end

    test "a hand-edited payload cannot smuggle a non-string label into the column" do
      {t, _round, _vacant} = fixture()

      envelope =
        t
        |> TournamentExport.export_tournament()
        |> encode_decode()
        |> map_pairings(&Map.put(&1, "display_board", %{"not" => "a label"}))

      assert {:ok, [copy]} = TournamentImport.import(envelope, scope())
      copy_round = Tournaments.get_round(copy.id, 1)

      # Junk becomes nil, which PairingDisplay renders as the row's own real
      # board number - never as a map printed onto a pairing sheet.
      assert labels(copy_round.id) == ["1", "2", "3"]
    end
  end
end
