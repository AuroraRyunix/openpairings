defmodule PairingsEngineWeb.ExplainColourHistoryTest do
  # FIDE C.04.2 3.4 on the pairing-explanation page: only played games count
  # towards a colour history, and a forfeit is not a played game - for
  # either side, whichever way it went.
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, PairingRationale, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round, as: RoundSchema
  alias PairingsEngine.Tournaments.Pairing, as: PairingSchema

  setup :register_and_log_in_user

  defp pairings_of(round), do: round |> Repo.preload(:pairings, force: true) |> Map.get(:pairings)

  defp seat_of(pairings, player_id) do
    Enum.find_value(pairings, fn p ->
      cond do
        p.white_player_id == player_id -> {p, :w}
        p.black_player_id == player_id -> {p, :b}
        true -> nil
      end
    end)
  end

  defp side_of(rationale, player_id) do
    Enum.find_value(rationale.boards, fn b ->
      cond do
        b.white && b.white.player.id == player_id -> b.white
        b.black && b.black.player.id == player_id -> b.black
        true -> nil
      end
    end)
  end

  # Six players, three rounds, all paired by Ainalrami. Round 1 is played;
  # in round 2 one player who had White in round 1 sits at Black and the
  # game is forfeited. Their played history going into round 3 is "W", so
  # they are due Black; counting the forfeit's seat would have read "WB" and
  # called them due White.
  defp forfeit_tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Forfeit colours",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    for {name, rating} <- [
          {"Ann", 2100},
          {"Ben", 2000},
          {"Cas", 1900},
          {"Dirk", 1800},
          {"Eva", 1700},
          {"Fien", 1600}
        ] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, r1} = Pairing.pair_next_round(t)
    r1_pairings = pairings_of(r1)
    Enum.each(r1_pairings, &({:ok, _} = Tournaments.update_pairing_result(&1, "1-0")))

    {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
    r2_pairings = pairings_of(r2)

    # Someone White in round 1 and Black in round 2.
    x =
      Enum.find_value(r1_pairings, fn p ->
        case seat_of(r2_pairings, p.white_player_id) do
          {_, :b} -> p.white_player_id
          _ -> nil
        end
      end)

    assert x, "the engine should alternate somebody from White to Black"
    {forfeited, :b} = seat_of(r2_pairings, x)

    Enum.each(r2_pairings, fn p ->
      result = if p.id == forfeited.id, do: "0-1FF", else: "1-0"
      {:ok, _} = Tournaments.update_pairing_result(p, result)
    end)

    {:ok, r3} = Pairing.pair_next_round(Repo.reload!(t))

    %{tournament: Repo.reload!(t), x: x, forfeit_round: 2, r3: r3}
  end

  test "the due colour ignores a forfeit and agrees with the colour the engine gave", %{
    conn: conn,
    scope: scope
  } do
    %{tournament: t, x: x, r3: r3} = forfeit_tournament(scope)

    # The old reading counted the forfeit's seat: W then B, balanced, due
    # White. The rule (and the engine) see only the White: one up, due Black.
    assert PairingRationale.due_colour([:w, :b]) == :w
    assert PairingRationale.due_colour([:w]) == :b

    # The reconstruction alone, before the page lays the engine's record
    # over it - this is the part that used to be wrong.
    rationale = PairingRationale.for_round(t, 3)
    side = side_of(rationale, x)
    assert side.colour_due == :b
    assert side.colour_class == :strong

    # Uncontroversial boards - the two players are due different colours,
    # or one has no preference - are exactly where the engine grants both.
    # The reconstruction must call every one of them a match.
    for b <- rationale.boards, not b.is_bye do
      if b.white.colour_due != b.black.colour_due do
        assert b.white.colour_ok != false, "board #{b.board}: white flagged against due"
        assert b.black.colour_ok != false, "board #{b.board}: black flagged against due"
      end
    end

    {pairing, engine_colour} = seat_of(pairings_of(r3), x)

    opponent_id =
      if engine_colour == :w, do: pairing.black_player_id, else: pairing.white_player_id

    # Uncontroversial for X: the opponent is due White, or due Black on a
    # weaker claim than X's strong one - FIDE settles that in X's favour.
    opponent = side_of(rationale, opponent_id)

    assert opponent.colour_due != :b or class_rank(opponent.colour_class) < class_rank(:strong),
           "the scenario must leave this board uncontroversial"

    assert engine_colour == :b
    # ...and the forfeit-counting history would have called it wrong.
    refute PairingRationale.due_colour([:w, :b]) == engine_colour
    assert side.colour_ok

    # The page agrees. A difference of one decides it whatever the order,
    # so there is no skipped-round footnote to print.
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")
    assert has_element?(lv, "#pe-due-#{pairing.board}-b", "matches due colour (Black)")
    refute has_element?(lv, "#pe-due-reason-#{pairing.board}-b")
  end

  # Hand-built, so the order matters: A plays White, then Black, then
  # forfeits as White. Played: W B - balanced, so A alternates from the
  # Black and is due White. Counting the forfeit read W B W and said Black.
  test "a verdict that leans on a skipped round says which round and why", %{
    conn: conn,
    scope: scope
  } do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Hand", "type" => "swiss"})

    [a, b, c, d] =
      for name <- ~w(A B C D) do
        {:ok, p} = Tournaments.create_player(t.id, %{"name" => name})
        p
      end

    r1 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 1, status: "playing"})
    board(r1, 1, a, b, "1-0")
    board(r1, 2, c, d, "1-0")
    r2 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 2, status: "playing"})
    board(r2, 1, c, a, "0-1")
    board(r2, 2, b, d, "1-0")
    r3 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 3, status: "playing"})
    board(r3, 1, a, d, "1-0FF")
    board(r3, 2, b, c, "1-0")
    r4 = Repo.insert!(%RoundSchema{tournament_id: t.id, number: 4, status: "playing"})
    board(r4, 1, a, c, "")
    board(r4, 2, b, d, "")

    t = Repo.reload!(t)
    side = side_of(PairingRationale.for_round(t, 4), a.id)
    assert side.colour_due == :w
    assert side.colour_class == :mild
    assert %{basis: :alternate, skipped: [%{round: 3, mark: :forfeit}]} = side.colour_reason

    # D lost that forfeit as Black: not a game for D either.
    d_side = side_of(PairingRationale.for_round(t, 4), d.id)
    assert d_side.colour_due == PairingRationale.due_colour([:b, :b])

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/4/explain")

    assert has_element?(
             lv,
             "#pe-due-reason-1-w",
             "due White: last played game was Black (round 3 was a forfeit and does not count)"
           )

    assert side.colour_ok
  end

  defp class_rank(:absolute), do: 3
  defp class_rank(:strong), do: 2
  defp class_rank(:mild), do: 1
  defp class_rank(_), do: 0

  defp board(round, board, white, black, result) do
    Repo.insert!(%PairingSchema{
      round_id: round.id,
      board: board,
      white_player_id: white.id,
      black_player_id: black.id,
      result: result
    })
  end

  test "the engine account's seat strip shows the forfeit as not played, then how it counts", %{
    conn: conn,
    scope: scope
  } do
    %{tournament: t, x: x} = forfeit_tournament(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/3/explain")

    # A floater sits in two brackets' rows; either strip will do.
    [seat_id | _] =
      lv
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([id^="pe-seat-"][id$="-#{x}"]))
      |> LazyHTML.attribute("id")

    assert has_element?(lv, "##{seat_id}-r1.is-w")
    assert has_element?(lv, "##{seat_id}-r2.is-forfeit")
    refute has_element?(lv, "##{seat_id}-r2.is-b")
    assert has_element?(lv, "##{seat_id}-r2[title='Round 2: forfeit, not played']")

    # W then a forfeit: the forfeit is the last round, so 3.4 moves it in
    # front of the White - "counts as" u W.
    assert has_element?(lv, "##{seat_id}-counts")
    assert has_element?(lv, "##{seat_id}-counts .pe-seat-chip.is-unplayed + .pe-seat-chip.is-w")
  end
end
