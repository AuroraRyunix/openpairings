defmodule PairingsEngine.NextRoundPreviewMemoTest do
  @moduledoc """
  The next-round preview remembers every outcome it paired
  (`PairingsEngine.NextRoundPreview.Memo`). A preview built from remembered
  outcomes must be exactly the preview a fresh run gives - the same fixed,
  shifting, colours-open and open classes, the same boards - after a result
  is entered, changed or cleared; and anything else changing pairs again.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{NextRoundPreview, Repo, Tournaments}
  alias PairingsEngine.NextRoundPreview.Memo

  setup do
    Memo.clear()
    on_exit(&Memo.clear/0)
    :ok
  end

  # One round played, the second paired with `open` games left open.
  defp tournament(open) do
    t = plain_tournament(14)
    pair!(t)
    finish_latest_round(t)
    pair!(t)
    games = games(t)
    games |> Enum.drop(open) |> Enum.each(&set_result(&1, default_result(&1.board)))
    {t, Enum.take(games, open)}
  end

  defp games(t) do
    latest_round(t).pairings
    |> Enum.filter(& &1.black_player_id)
    |> Enum.sort_by(& &1.board)
  end

  defp set_result(pairing, result) do
    {:ok, _} = Tournaments.update_pairing_result(Repo.reload!(pairing), result)
  end

  @compared [:fixed, :shifting, :colours_open, :open, :bye, :outcomes, :failed, :failure]

  # Runs the preview through the memo and from scratch, and holds the two
  # to each other. Returns the memo's run.
  defp assert_same_as_fresh(t) do
    assert {:ok, remembered} = NextRoundPreview.run(reload(t))
    assert {:ok, fresh} = NextRoundPreview.run(reload(t), memo: false)
    assert fresh.reused == 0

    assert Map.take(remembered, @compared) == Map.take(fresh, @compared)
    assert remembered.games == fresh.games
    assert {remembered.round, remembered.next_round} == {fresh.round, fresh.next_round}
    remembered
  end

  test "entering a result pairs nothing: every outcome is remembered" do
    {t, [first, second, _third]} = tournament(3)

    assert {:ok, %{reused: 0, outcomes: 27}} = NextRoundPreview.run(reload(t))

    set_result(first, "1-0")
    preview = assert_same_as_fresh(t)
    assert {preview.outcomes, preview.reused} == {9, 9}

    set_result(second, "1/2-1/2")
    preview = assert_same_as_fresh(t)
    assert {preview.outcomes, preview.reused} == {3, 3}
  end

  test "changing a result of a game that was open pairs nothing either" do
    {t, [first | _]} = tournament(2)
    assert {:ok, _} = NextRoundPreview.run(reload(t))

    set_result(first, "1-0")
    assert %{reused: 3} = assert_same_as_fresh(t)

    set_result(first, "0-1")
    assert %{reused: 3} = assert_same_as_fresh(t)
  end

  test "clearing a result pairs only the outcomes in which it differs" do
    {t, open} = tournament(2)
    decided = Enum.at(games(t), 3)
    assert {:ok, %{reused: 0}} = NextRoundPreview.run(reload(t))

    # Clearing one of the games the preview was worked out with: all known.
    set_result(hd(open), "1-0")
    assert {:ok, %{reused: 3}} = NextRoundPreview.run(reload(t))
    set_result(hd(open), "")
    assert %{outcomes: 9, reused: 9} = assert_same_as_fresh(t)

    # Clearing a board that was decided all along: the outcomes in which it
    # keeps its result are known, the other two thirds are paired.
    set_result(decided, "")
    assert %{outcomes: 27, reused: 9} = assert_same_as_fresh(t)

    # ...and now remembered too.
    assert %{reused: 27} = assert_same_as_fresh(t)
  end

  test "an entered-then-cleared sequence ends where it started" do
    {t, [a, b, c]} = tournament(3)
    assert {:ok, start} = NextRoundPreview.run(reload(t))

    set_result(a, "0-1")
    set_result(b, "1-0")
    set_result(c, "1/2-1/2")
    assert {:error, :no_open_games} = NextRoundPreview.run(reload(t))

    for g <- [c, b, a], do: set_result(g, "")
    back = assert_same_as_fresh(t)
    assert back.reused == 27
    assert Map.take(back, @compared) == Map.take(start, @compared)
  end

  test "a decided board's result changed, a player withdrawn, a setting: paired again" do
    {t, _open} = tournament(2)
    decided = Enum.at(games(t), 4)
    assert {:ok, _} = NextRoundPreview.run(reload(t))

    flipped = if decided.result == "1-0", do: "0-1", else: "1-0"
    set_result(decided, flipped)
    assert %{reused: 0} = assert_same_as_fresh(t)

    player =
      Repo.get_by!(PairingsEngine.Tournaments.Player, tournament_id: t.id, name: "Player 014")

    set_player(player, status: "withdrawn")
    assert %{reused: 0} = assert_same_as_fresh(t)

    Repo.update_all(
      from(x in PairingsEngine.Tournaments.Tournament, where: x.id == ^t.id),
      set: [rounds_count: 8]
    )

    assert %{reused: 0} = assert_same_as_fresh(t)
  end

  test "a forfeit in an open game is not one of the outcomes tried: it is paired" do
    {t, [first, _second]} = tournament(2)
    assert {:ok, _} = NextRoundPreview.run(reload(t))

    set_result(first, "+--")
    assert %{outcomes: 3, reused: 0} = assert_same_as_fresh(t)
  end

  test "the base ignores the results of the round being played, and nothing else" do
    {t, [first, _]} = tournament(2)
    {base, results} = NextRoundPreview.base_state(t.id, 2)
    assert results[first.id] == ""

    set_result(first, "1-0")
    {base_after, results_after} = NextRoundPreview.base_state(t.id, 2)
    assert base_after == base
    assert results_after[first.id] == "1-0"

    player =
      Repo.get_by!(PairingsEngine.Tournaments.Player, tournament_id: t.id, name: "Player 003")

    set_player(player, fide_rating: 1234)
    assert elem(NextRoundPreview.base_state(t.id, 2), 0) != base
  end

  test "bounded: a few bases per tournament, the oldest dropped first" do
    {t, _open} = tournament(1)

    player =
      Repo.get_by!(PairingsEngine.Tournaments.Player, tournament_id: t.id, name: "Player 003")

    bases =
      for rating <- [2001, 2002, 2003, 2004] do
        set_player(player, fide_rating: rating)
        assert {:ok, %{base: base, reused: 0}} = NextRoundPreview.run(reload(t))
        base
      end

    assert Enum.map(bases, &Memo.size(t.id, &1)) == [0, 3, 3, 3]
  end
end
