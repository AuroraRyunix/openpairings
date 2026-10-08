defmodule PairingsEngineWeb.TrfImportOddResultsTest do
  # VCL4THP Q166: on import, any unexpected symbol in a result column is a
  # game with an unknown result. The engine still refuses such a file; the
  # import rewrites the symbol to `?` and makes the arbiter confirm every
  # rewrite on the review step. async: false - whole-tournament writes.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Repo, TrfImport}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  setup :register_and_log_in_user

  # Three rounds, four players, every game a draw: round 1 is 1-2 and 3-4,
  # round 2 is 1-3 and 2-4, round 3 is 1-4 and 2-3.
  defp base_file(name) do
    boards = [[{1, 2}, {3, 4}], [{1, 3}, {2, 4}], [{1, 4}, {2, 3}]]
    empty = %{1 => [], 2 => [], 3 => [], 4 => []}

    games =
      Enum.reduce(boards, empty, fn round, acc ->
        Enum.reduce(round, acc, fn {w, b}, acc ->
          acc
          |> Map.update!(w, &(&1 ++ [%{opponent_rank: b, colour: "w", result: "="}]))
          |> Map.update!(b, &(&1 ++ [%{opponent_rank: w, colour: "b", result: "="}]))
        end)
      end)

    names = ~w(Alpha Bravo Charlie Delta)

    Ainalrami.Trf.serialize(%{
      tournament: %{name: name, type: "swiss", number_of_rounds: 5},
      players:
        for {rank, rounds} <- Enum.sort(games) do
          %{rank: rank, name: "#{Enum.at(names, rank - 1)}, Player", points: 1.5, games: rounds}
        end
    })
  end

  # Writes `char` into the result column of `rank`'s `round`.
  defp patch(text, rank, round, char) do
    offset = 98 + (round - 1) * 10
    prefix = "001 " <> String.pad_leading(Integer.to_string(rank), 4)

    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.starts_with?(line, prefix) do
        binary_part(line, 0, offset) <>
          char <> binary_part(line, offset + 1, byte_size(line) - offset - 1)
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  # 2 plays "5" against 1's "=" in round 1; 1 and 3 both write a symbol
  # for round 2; 4 writes "x" in round 3 against 1's "=".
  defp odd_file(name) do
    name
    |> base_file()
    |> patch(2, 1, "5")
    |> patch(1, 2, "%")
    |> patch(3, 2, "x")
    |> patch(4, 3, "x")
  end

  defp submit_trf(conn, content) do
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> element("button", "Import TRF file") |> render_click()

    trf =
      file_input(lv, "form", :trf, [%{name: "odd.trf", content: content, type: "text/plain"}])

    render_upload(trf, "odd.trf")
    lv |> form("#trf-import-form", %{}) |> render_submit()
    lv
  end

  defp tournaments_named(name),
    do: Repo.aggregate(from(t in Tournament, where: t.name == ^name), :count)

  defp results_of(name) do
    Repo.all(
      from(p in Pairing,
        join: r in Round,
        on: r.id == p.round_id,
        join: t in Tournament,
        on: t.id == r.tournament_id,
        where: t.name == ^name,
        order_by: [r.number, p.board],
        select: {r.number, p.result}
      )
    )
  end

  test "the report lists every odd symbol with player, round and code" do
    assert {:ok, report} = TrfImport.review(odd_file("Odd Report"))

    odd = Enum.filter(report.adjustments, &(&1.code == :unrecognised_result))
    assert length(odd) == 4

    by = fn rank, round -> Enum.find(odd, &(&1.rank == rank and &1.round == round)) end

    assert %{player: "Bravo, Player", symbol: "5", partner_rank: 1, partner_code: "="} = by.(2, 1)
    assert %{player: "Alpha, Player", symbol: "%", partner_rank: nil} = by.(1, 2)
    assert %{player: "Charlie, Player", symbol: "x", partner_rank: nil} = by.(3, 2)
    assert %{player: "Delta, Player", symbol: "x", partner_rank: 1, partner_code: "="} = by.(4, 3)

    # A review changes nothing.
    assert tournaments_named("Odd Report") == 0
  end

  test "a file with only legal codes has no such adjustment" do
    assert {:ok, report} = TrfImport.review(base_file("Legal Only"))
    refute Enum.any?(report.adjustments, &(&1.code == :unrecognised_result))
  end

  test "a symbol next to no opponent is still refused" do
    text = base_file("Nobody") |> patch(1, 1, "5")
    # Blank out round 1's opponent of player 1: id columns 92-95.
    text =
      text
      |> String.split("\n")
      |> Enum.map(fn
        "001    1" <> _ = line ->
          <<head::binary-size(91), _::binary-size(4), tail::binary>> = line
          head <> "0000" <> tail

        line ->
          line
      end)
      |> Enum.join("\n")

    assert {:error, _} = TrfImport.review(text)
  end

  test "the review step lists each one; confirming imports them as postponed games", %{conn: conn} do
    lv = submit_trf(conn, odd_file("Odd Confirm"))

    assert has_element?(lv, "#trf-review")
    items = lv |> element("#trf-review-adjustments") |> render()

    assert items =~ "Bravo, Player"
    assert items =~ "round 1"
    assert items =~ "&quot;5&quot;"
    assert items =~ "Alpha, Player"
    assert items =~ "&quot;%&quot;"
    assert items =~ "Charlie, Player"
    assert items =~ "Delta, Player"
    assert items =~ "round 3"

    assert tournaments_named("Odd Confirm") == 0

    lv |> element("#trf-review-confirm") |> render_click()
    {_to, _flash} = assert_redirect(lv)

    results = results_of("Odd Confirm")
    assert Enum.count(results, fn {_, r} -> r == "*" end) == 3
    assert Enum.count(results) == 6
  end

  test "cancelling the review imports nothing", %{conn: conn} do
    lv = submit_trf(conn, odd_file("Odd Cancel"))
    assert has_element?(lv, "#trf-review")

    lv |> element("#trf-review-cancel") |> render_click()

    refute has_element?(lv, "#trf-review")
    assert tournaments_named("Odd Cancel") == 0
  end

  test "a legal file's review does not mention unrecognised results", %{conn: conn} do
    lv = submit_trf(conn, base_file("Odd Control"))
    html = render(lv)
    refute html =~ "which is not a result code"
  end
end
