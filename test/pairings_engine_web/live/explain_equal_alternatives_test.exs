defmodule PairingsEngineWeb.ExplainEqualAlternativesTest do
  # The pairing-explanation page on an alternative that is exactly as good
  # as the played round: ONE item per alternative, both versions side by
  # side, a short line with a link on the candidate's own row, and the
  # regulation's article for whoever wants it. Drawn from the stored record
  # as it is, so a round explained before any of this existed reads the same.
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{ExplanationJobs, Pairing, Repo, RoundExplanation, Tournaments}

  setup :register_and_log_in_user

  # Six players, round one all won by White: round two's top bracket holds
  # three, so one of them floats. Returns the round with what a test needs
  # to write answers into its record: the bracket's index, the floater, the
  # two who stayed and whom the floater met.
  defp floated_round(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Equal alternatives",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    for n <- 1..6 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2000 - n * 50})
    end

    {:ok, r1} = Pairing.pair_next_round(t)

    for p <- Repo.preload(r1, :pairings).pairings do
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    {:ok, r2} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
    round = Tournaments.get_round(t.id, r2.number)

    [%{"brackets" => brackets}] = round.explanation["sections"]
    index = Enum.find_index(brackets, &(&1["floats"] != []))
    bracket = Enum.at(brackets, index)
    [floater] = bracket["floats"]

    opponent =
      brackets
      |> Enum.flat_map(& &1["pairs"])
      |> Enum.find_value(fn
        [^floater, other] -> other
        [other, ^floater] -> other
        _ -> nil
      end)

    %{
      t: t,
      round: round,
      index: index,
      floater: floater,
      others: (bracket["mdps"] ++ bracket["residents"]) -- [floater],
      opponent: opponent,
      group: bracket["group"]
    }
  end

  defp tie(player, ctx, lex \\ "actual") do
    %{
      "player" => player,
      "outcome" => "tie",
      "reason" => nil,
      "at" => %{"group" => ctx.group, "label" => nil, "lex" => lex},
      "fate" => %{"opponent" => ctx.opponent, "score" => 0.0},
      "stayed" => true
    }
  end

  # The record as a round explained before 2026-09-28 has it: version 3,
  # the answers inside the bracket, no questions to open.
  defp store_version_3(ctx, candidates) do
    record =
      ctx.round.explanation
      |> Map.put("version", 3)
      |> Map.drop(["alternatives", "job"])
      |> update_in(["sections", Access.at(0), "brackets", Access.at(ctx.index)], fn bracket ->
        Map.put(bracket, "float_alternatives", [
          %{"floater" => ctx.floater, "candidates" => candidates}
        ])
      end)

    ctx.round |> Ecto.Changeset.change(explanation: record) |> Repo.update!()
  end

  test "an old stored account groups its ties: one item per alternative, a short line per row",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, b] = ctx.others

    store_version_3(ctx, [tie(a, ctx), Map.put(tie(b, ctx), "outcome", "impossible")])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    block = "#equal-alt-0-#{ctx.index}"
    item = "#{block}-#{a}"

    # One tie, one item - a real list item in a labelled section.
    assert has_element?(lv, "section#{block}[aria-labelledby=equal-alt-0-#{ctx.index}-title]")
    assert has_element?(lv, "#{block}-list > li#{item}")
    refute has_element?(lv, "#{block}-#{b}")
    refute has_element?(lv, "#{block}-more")

    # Both versions side by side, each a labelled list.
    assert has_element?(
             lv,
             "ul#{item}-played[aria-labelledby=equal-alt-0-#{ctx.index}-#{a}-played-label] li"
           )

    assert has_element?(lv, "ul#{item}-proposed li")
    assert has_element?(lv, "#{item}-why")

    # The candidate's own row: the short form, and the way to the item.
    row = "#why-float-0-#{ctx.index}-#{ctx.floater}-c-#{a}"
    assert has_element?(lv, "li#{row}.is-tie")
    assert has_element?(lv, ~s(a#{row}-compare[href="#{item}"]))
    refute has_element?(lv, "#why-float-0-#{ctx.index}-#{ctx.floater}-c-#{b}-compare")

    # Plain words on the row, not the regulation's term.
    row_text = lv |> element(row) |> render()
    assert row_text =~ "equally good by every rule"
    assert row_text =~ "pairing numbers decided"
    refute render(lv) =~ "transposition order"
  end

  test "the expert sentence names the article", %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    store_version_3(ctx, [tie(a, ctx)])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    expert = lv |> element("details#equal-alt-0-#{ctx.index}-expert") |> render()
    assert expert =~ "C.04.3 Article 3.8.1"
    assert expert =~ "Article 4.2"
    assert expert =~ "Article 4.3"

    # ...and rides along on the row's link, for whoever hovers.
    assert has_element?(
             lv,
             ~s(#why-float-0-#{ctx.index}-#{ctx.floater}-c-#{a}-compare[title*="Article 3.8.1"])
           )
  end

  test "a tie the fixed order would have decided the other way says so, loudly",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    store_version_3(ctx, [tie(a, ctx, "alternative")])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    assert has_element?(lv, "#equal-alt-0-#{ctx.index}-#{a}-why.is-better")
  end

  test "past three, the rest wait behind 'and N more'", %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    everyone = ctx.t.id |> Tournaments.list_players() |> Enum.map(& &1.id)
    candidates = everyone -- [ctx.floater]
    assert length(candidates) == 5

    store_version_3(ctx, Enum.map(candidates, &tie(&1, ctx)))

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    block = "#equal-alt-0-#{ctx.index}"
    [first, _, _, fourth, fifth] = candidates

    assert has_element?(lv, "#{block}-list > li#{block}-#{first}")
    refute has_element?(lv, "#{block}-list > li#{block}-#{fourth}")
    assert has_element?(lv, "details#{block}-more #{block}-more-list > li#{block}-#{fourth}")
    assert has_element?(lv, "details#{block}-more #{block}-more-list > li#{block}-#{fifth}")
  end

  test "an answer worked out on demand groups the same way", %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    assert RoundExplanation.on_demand?(ctx.round.explanation)

    question = RoundExplanation.float_question_key(0, ctx.index, ctx.floater)

    ExplanationJobs.store_alternative(ctx.round.id, ctx.round.explanation["job"], question, %{
      "floater" => ctx.floater,
      "candidates" => [tie(a, ctx)]
    })

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    item = "#equal-alt-0-#{ctx.index}-#{a}"
    assert has_element?(lv, "li#{item}")

    dom = "#alt-float-0-#{ctx.index}-#{ctx.floater}"
    lv |> element("#{dom}-toggle") |> render_click()
    assert has_element?(lv, ~s(#{dom}-answer-c-#{a}-compare[href="#{item}"]))
  end

  test "a round with no ties has no such block", %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    store_version_3(ctx, [Map.put(tie(a, ctx), "outcome", "impossible")])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    refute has_element?(lv, "#equal-alt-0-#{ctx.index}")
    assert has_element?(lv, "#why-float-0-#{ctx.index}-#{ctx.floater}")
  end
end
