defmodule PairingsEngineWeb.PairingsQuickResultTest do
  @moduledoc """
  The one-tap result buttons on the Pairings page: three per board, for an
  arbiter entering results on a phone while walking the hall.

  They send the same "result" event the board's select does, so what is
  proven here is the part that is theirs: they are on every board, they
  write, the result on file reads as pressed, a second tap on it writes
  nothing, and an archived tournament offers none of them. The phone layout
  they live in is CSS, read back the way `layout_overflow_test.exs` reads it.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  defp fixture(scope, result \\ "") do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Quick Result Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    pairing =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: result
      })

    :ok = Tournaments.freeze_round_display_boards!(round.id)

    {tournament, pairing}
  end

  defp pressed(lv, pairing) do
    for slot <- ~w(white draw black),
        has_element?(lv, "#result-quick-#{pairing.id}-#{slot}[aria-pressed=true]"),
        do: slot
  end

  test "every board carries the three one-tap results, as a named group", %{
    conn: conn,
    scope: scope
  } do
    {tournament, pairing} = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert has_element?(lv, "#result-quick-#{pairing.id}[role=group][aria-label]")
    assert has_element?(lv, "#result-quick-#{pairing.id}-white[phx-value-result='1-0']")
    assert has_element?(lv, "#result-quick-#{pairing.id}-draw[phx-value-result='1/2-1/2']")
    assert has_element?(lv, "#result-quick-#{pairing.id}-black[phx-value-result='0-1']")
    # The select is still there for everything else.
    assert has_element?(lv, "#result-select-#{pairing.id}")
    assert pressed(lv, pairing) == []
  end

  test "a tap writes the result, logs it, and the button reads as pressed", %{
    conn: conn,
    scope: scope
  } do
    {tournament, pairing} = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("#result-quick-#{pairing.id}-draw") |> render_click()

    assert Repo.get!(Pairing, pairing.id).result == "1/2-1/2"
    assert pressed(lv, pairing) == ["draw"]
    assert has_element?(lv, "#result-select-#{pairing.id} option[value='1/2-1/2'][selected]")

    [log] = Audit.list_for_tournament(tournament.id, action: "pairing.result_entered")
    assert log.details["to"] == "1/2-1/2"
  end

  test "another tap changes it, with no confirmation in between", %{conn: conn, scope: scope} do
    {tournament, pairing} = fixture(scope, "1-0")
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")
    assert pressed(lv, pairing) == ["white"]

    lv |> element("#result-quick-#{pairing.id}-black") |> render_click()

    assert Repo.get!(Pairing, pairing.id).result == "0-1"
    assert pressed(lv, pairing) == ["black"]
    [log] = Audit.list_for_tournament(tournament.id, action: "pairing.result_changed")
    assert log.details["from"] == "1-0"
  end

  test "tapping the result already on file writes nothing", %{conn: conn, scope: scope} do
    {tournament, pairing} = fixture(scope, "1-0")
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    lv |> element("#result-quick-#{pairing.id}-white") |> render_click()

    assert Repo.get!(Pairing, pairing.id).result == "1-0"
    assert pressed(lv, pairing) == ["white"]
    assert Audit.list_for_tournament(tournament.id, action: "pairing.result_changed") == []
  end

  test "an archived tournament's buttons are disabled", %{conn: conn, scope: scope} do
    {tournament, pairing} = fixture(scope)
    {:ok, _} = Tournaments.archive_tournament(tournament)
    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

    assert has_element?(lv, "#result-quick-#{pairing.id}-white[disabled]")
  end

  describe "the stylesheet" do
    @css File.read!("assets/css/app.css")

    test "the buttons are hidden on a desk and shown on a narrow or touch screen" do
      assert @css =~ ~r/^\.result-quick \{ display: none; \}/m

      assert @css =~
               ~r/@media \(max-width: 768px\), \(pointer: coarse\) \{\s*\.result-quick \{\s*display: flex;/

      [_, block] = Regex.run(~r/\.result-quick-btn \{([^}]*)\}/, @css)
      assert block =~ "min-height: 44px"
    end

    test "a board is a card on a phone held upright" do
      assert @css =~
               ~r/@media \(max-width: 640px\) \{.*\.pairings-board-table tbody tr:has\(> td\.pairing-result\) \{\s*display: grid;/s
    end

    test "fields are 16px on a touch screen, so iOS does not zoom" do
      [_, block] = Regex.run(~r/@media \(pointer: coarse\) \{(.*?)\n\}/s, @css)
      assert block =~ ~r/select:not\(\[multiple\]\),.*font-size: 16px;/s
    end
  end
end
