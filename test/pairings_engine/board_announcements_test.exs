defmodule PairingsEngine.BoardAnnouncementsTest do
  @moduledoc """
  Boards of the next round announced from the preview: what is stored, when
  the announcement may no longer hold, "Check again", and the comparison
  with the real pairing - which is never changed to match.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{BoardAnnouncements, NextRoundPreview, Repo, Tournaments}
  alias PairingsEngine.BoardAnnouncements.AnnouncedBoard
  alias PairingsEngine.Pairing, as: Engine

  @scope %PairingsEngine.Accounts.Scope{user: %{id: 7, email: "arbiter@example.com"}}

  setup do
    NextRoundPreview.Memo.clear()
    :ok
  end

  # One round played, the second paired, two games of it left open.
  defp announced_tournament do
    t = plain_tournament(20)
    pair!(t)
    finish_latest_round(t)
    pair!(t)
    games = games(t)
    games |> Enum.drop(2) |> Enum.each(&set_result(&1, default_result(&1.board)))
    {:ok, preview} = NextRoundPreview.run(reload(t))
    assert preview.fixed != [], "the fixture must leave some board fixed"
    {:ok, announcement, added, []} = BoardAnnouncements.announce(t.id, preview, @scope)

    %{
      t: t,
      open: Enum.take(games, 2),
      decided: Enum.drop(games, 2),
      preview: preview,
      announcement: announcement,
      added: added
    }
  end

  defp games(t) do
    latest_round(t).pairings |> Enum.filter(& &1.black_player_id) |> Enum.sort_by(& &1.board)
  end

  defp set_result(pairing, result) do
    {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(pairing), result)
  end

  defp status(t), do: BoardAnnouncements.status(t.id, BoardAnnouncements.pending(t.id))

  describe "announcing" do
    test "stores each fixed board as announced, with time and author" do
      %{t: t, preview: preview, announcement: a, added: added} = announced_tournament()

      assert a.round == 3
      assert length(added) == length(preview.fixed)
      assert length(a.boards) == length(preview.fixed)

      for {row, board} <- Enum.zip(preview.fixed, a.boards) do
        assert {board.label, board.white_player_id, board.black_player_id} ==
                 {row.label, row.white, row.black}

        assert board.white_name == preview.players[row.white].name
        assert board.announced_by == "arbiter@example.com"
        assert board.announced_by_id == 7
        assert %DateTime{} = board.announced_at
      end

      assert BoardAnnouncements.pending(t.id).id == a.id
    end

    test "announcing again keeps what is there and adds nothing" do
      %{t: t, preview: preview, announcement: a} = announced_tournament()
      assert {:ok, again, [], []} = BoardAnnouncements.announce(t.id, preview, @scope)
      assert Enum.map(again.boards, & &1.id) == Enum.map(a.boards, & &1.id)
    end

    test "a board announced differently for the same player is replaced" do
      %{t: t, preview: preview, announcement: a} = announced_tournament()
      [first | _] = a.boards
      Repo.update!(Ecto.Changeset.change(first, label: "99"))

      assert {:ok, again, [added], [replaced]} =
               BoardAnnouncements.announce(t.id, preview, @scope)

      assert replaced.id == first.id
      assert added.label == first.label
      assert length(again.boards) == length(a.boards)
    end

    test "nothing fixed, nothing announced" do
      assert {:error, :nothing_fixed} =
               BoardAnnouncements.announce(1, %{fixed: [], next_round: 2}, @scope)
    end

    test "withdrawn" do
      %{t: t, announcement: a} = announced_tournament()
      assert {:ok, count} = BoardAnnouncements.withdraw(t.id, a.round)
      assert count == length(a.boards)
      assert BoardAnnouncements.pending(t.id) == nil
      assert Repo.aggregate(AnnouncedBoard, :count) == 0
      assert {:error, :none} = BoardAnnouncements.withdraw(t.id, a.round)
    end
  end

  describe "whether the announcement may still hold" do
    test "a result entered for a game the preview tried changes nothing" do
      %{t: t, open: [first, second]} = announced_tournament()
      assert status(t) == :holds

      set_result(first, "0-1")
      assert status(t) == :holds
      set_result(second, "1/2-1/2")
      assert status(t) == :holds

      # ...and taken back again
      set_result(second, "")
      assert status(t) == :holds
    end

    test "a decided board's result changed or cleared: may no longer hold" do
      %{t: t, decided: [d | _]} = announced_tournament()
      set_result(d, if(Repo.reload!(d).result == "1-0", do: "0-1", else: "1-0"))
      assert status(t) == :changed

      set_result(d, "")
      assert status(t) == :changed
    end

    test "a forfeit in an open game, a withdrawal, a setting, a forbidden pairing" do
      for change <- [:forfeit, :withdrawal, :setting, :forbidden] do
        %{t: t, open: [first | _]} = announced_tournament()

        case change do
          :forfeit ->
            set_result(first, "+--")

          :withdrawal ->
            player =
              Repo.get_by!(PairingsEngine.Tournaments.Player,
                tournament_id: t.id,
                name: "Player 020"
              )

            set_player(player, status: "withdrawn")

          :setting ->
            Repo.update_all(
              Ecto.Query.from(x in PairingsEngine.Tournaments.Tournament, where: x.id == ^t.id),
              set: [rounds_count: 9]
            )

          :forbidden ->
            [a, b | _] =
              Repo.all(
                Ecto.Query.from(p in PairingsEngine.Tournaments.Player,
                  where: p.tournament_id == ^t.id
                )
              )

            Repo.insert!(%PairingsEngine.Tournaments.ForbiddenPairing{
              tournament_id: t.id,
              player_a_id: a.id,
              player_b_id: b.id
            })
        end

        assert status(t) == :changed, "#{change} went unnoticed"
        Repo.delete_all(PairingsEngine.BoardAnnouncements.Announcement)
      end
    end
  end

  describe "check again" do
    test "marks the boards the preview no longer has as fixed, and answers the warning" do
      %{t: t, decided: [d | _], announcement: a} = announced_tournament()
      set_result(d, if(Repo.reload!(d).result == "1-0", do: "0-1", else: "1-0"))
      assert status(t) == :changed

      {:ok, preview} = NextRoundPreview.run(reload(t))
      [kept | dropped] = a.boards
      fixed = [%{label: kept.label, white: kept.white_player_id, black: kept.black_player_id}]

      assert {:ok, %{uncertain: uncertain, certain: 1}} =
               BoardAnnouncements.check(t.id, a.round, %{preview | fixed: fixed})

      assert Enum.map(uncertain, & &1.id) == Enum.map(dropped, & &1.id)
      assert status(t) == :holds

      flags = BoardAnnouncements.pending(t.id).boards |> Map.new(&{&1.id, &1.uncertain})
      assert flags[kept.id] == false
      assert Enum.all?(dropped, &flags[&1.id])

      # A real check with the real preview restores what it finds fixed.
      assert {:ok, %{}} = BoardAnnouncements.check(t.id, a.round, preview)
    end

    test "with every result in, the one outcome is the round as it will be paired" do
      %{t: t, open: open} = announced_tournament()
      Enum.each(open, &set_result(&1, "1-0"))

      assert {:ok, preview} = NextRoundPreview.run(reload(t), allow_complete: true)
      assert preview.outcomes == 1
      assert {:error, :no_open_games} = NextRoundPreview.run(reload(t))
    end
  end

  describe "the real pairing" do
    test "announced boards from the preview all hold, whatever the results" do
      %{t: t, open: open, announcement: a} = announced_tournament()
      Enum.each(open, &set_result(&1, "0-1"))
      round = pair!(t)

      assert %{changed: [], total: total, acknowledged?: false} =
               BoardAnnouncements.compare(t.id, round.number)

      assert total == length(a.boards)
    end

    test "a different board number, colours or opponent is reported, and the pairing is left alone" do
      %{t: t, open: open, announcement: a} = announced_tournament()
      Enum.each(open, &set_result(&1, "1-0"))
      [b1, b2 | _] = a.boards

      # What was announced, tampered with: another board number, and the
      # colours the other way round.
      Repo.update!(Ecto.Changeset.change(b1, label: "99"))

      Repo.update!(
        Ecto.Changeset.change(b2,
          white_player_id: b2.black_player_id,
          black_player_id: b2.white_player_id
        )
      )

      round = pair!(t)
      before = snapshot(t)
      comparison = BoardAnnouncements.compare(t.id, round.number)

      changes = Map.new(comparison.changed, &{&1.board.id, &1.changes})
      assert changes[b1.id] == [:board]
      assert changes[b2.id] == [:colours]
      assert map_size(changes) == 2

      actual = Enum.find(comparison.changed, &(&1.board.id == b1.id)).actual
      assert actual.label == b1.label
      assert snapshot(t) == before
    end

    test "an opponent that differs, and a player not paired" do
      %{t: t, open: open, announcement: a} = announced_tournament()
      Enum.each(open, &set_result(&1, "1-0"))
      [b1, b2 | _] = a.boards

      Repo.update!(Ecto.Changeset.change(b1, black_player_id: b2.black_player_id))
      Repo.update!(Ecto.Changeset.change(b2, white_player_id: -1))

      round = pair!(t)

      changes =
        BoardAnnouncements.compare(t.id, round.number).changed
        |> Map.new(&{&1.board.id, &1.changes})

      assert :opponent in changes[b1.id]
      assert changes[b2.id] == [:not_paired]
    end

    test "unpaired and paired again: compared again, the acknowledgement does not carry over" do
      %{t: t, open: open, announcement: a} = announced_tournament()
      Enum.each(open, &set_result(&1, "1-0"))
      Repo.update!(Ecto.Changeset.change(hd(a.boards), label: "99"))

      round = pair!(t)
      comparison = BoardAnnouncements.compare(t.id, round.number)
      {:ok, _} = BoardAnnouncements.acknowledge(comparison.announcement, comparison.round_id)
      assert BoardAnnouncements.compare(t.id, round.number).acknowledged?

      :ok = Engine.delete_round(t.id, round.number)
      assert BoardAnnouncements.compare(t.id, round.number) == nil
      assert BoardAnnouncements.pending(t.id).id == a.id

      again = pair!(t)
      comparison = BoardAnnouncements.compare(t.id, again.number)
      assert [_] = comparison.changed
      refute comparison.acknowledged?
    end
  end
end
