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

  # ---- version 5: the whole alternative ---------------------------------

  # A tie as an answer worked out since version 5 stores it: the old keys,
  # and the round the alternative stands for. Two boards change here - the
  # candidate takes the floater's board, the floater the candidate's.
  defp whole_tie(candidate, ctx, step) do
    partner = partner_of(ctx, candidate)

    Map.put(tie(candidate, ctx), "alternative", %{
      "pairs" => [[candidate, ctx.opponent], [ctx.floater, partner]],
      "played" => [[ctx.floater, ctx.opponent], [candidate, partner]],
      "unchanged" => 1,
      "brackets" => [
        %{"group" => ctx.group, "pairs" => [[ctx.floater, partner]], "floats" => [candidate]}
      ],
      "bye" => nil,
      "step" => step
    })
  end

  defp partner_of(ctx, player) do
    ctx.round.explanation["sections"]
    |> Enum.flat_map(& &1["brackets"])
    |> Enum.flat_map(& &1["pairs"])
    |> Enum.find_value(fn
      [^player, other] -> other
      [other, ^player] -> other
      _ -> nil
    end)
  end

  defp store_answer(ctx, candidates) do
    question = RoundExplanation.float_question_key(0, ctx.index, ctx.floater)

    :stored =
      ExplanationJobs.store_alternative(ctx.round.id, ctx.round.explanation["job"], question, %{
        "floater" => ctx.floater,
        "candidates" => candidates
      })

    question
  end

  test "a version-5 answer shows both rounds whole: every changed board, and how many are not",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    assert ctx.round.explanation["version"] == 5
    # The tie is placed one bracket up, where the record alone cannot say
    # what the step was - so the words are the engine's.
    store_answer(ctx, [
      put_in(whole_tie(a, ctx, "transposition"), ["at", "group"], ctx.group + 1.0)
    ])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    item = "#equal-alt-0-#{ctx.index}-#{a}"
    assert has_element?(lv, "li#{item}.is-whole")

    names = Map.new(Tournaments.list_players(ctx.t.id), &{&1.id, &1.name})
    played = lv |> element("ul#{item}-played") |> render()
    proposed = lv |> element("ul#{item}-proposed") |> render()

    # Two boards on each side, the same four players, differently paired.
    for id <- [ctx.floater, ctx.opponent, a, partner_of(ctx, a)] do
      assert played =~ names[id]
      assert proposed =~ names[id]
    end

    assert length(Regex.scan(~r/<li/, played)) == 3
    assert length(Regex.scan(~r/<li/, proposed)) == 3

    # Who goes down, on both sides, since that is what changed.
    assert played =~ "Goes down from the"
    assert proposed =~ "Goes down from the"

    assert lv |> element("#{item}-unchanged") |> render() =~ "One other board is the same in both"

    # Nothing is left to guess, so nothing says "not recorded".
    refute render(lv) =~ "was not recorded"

    # The engine's own word for the step, in plain ones.
    assert lv |> element("#{item}-why") |> render() =~ "later arrangement of the bottom half"

    # The account is current: no offer to explain it again.
    refute has_element?(lv, "#recompute")
  end

  test "an alternative too large to list keeps the one board and says how many changed",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others

    store_answer(ctx, [
      Map.put(tie(a, ctx), "alternative", %{"skipped" => "too_many_boards", "count" => 57})
    ])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    item = "#equal-alt-0-#{ctx.index}-#{a}"
    assert has_element?(lv, "li#{item}")
    refute has_element?(lv, "li#{item}.is-whole")
    assert lv |> element("#{item}-too-many") |> render() =~ "57"
  end

  test "an alternative naming a player deleted since falls back to the one board",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others

    store_answer(ctx, [
      update_in(whole_tie(a, ctx, nil), ["alternative", "pairs"], &[[a, -1] | tl(&1)])
    ])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    item = "#equal-alt-0-#{ctx.index}-#{a}"
    assert has_element?(lv, "li#{item}")
    refute has_element?(lv, "li#{item}.is-whole")
  end

  test "an old account still renders the old way, and offers to be explained again",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    store_version_3(ctx, [tie(a, ctx)])

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")

    item = "#equal-alt-0-#{ctx.index}-#{a}"
    assert has_element?(lv, "li#{item}")
    refute has_element?(lv, "li#{item}.is-whole")
    assert lv |> element("ul#{item}-proposed") |> render() =~ "was not recorded"

    # The existing offer, with the words for this kind of old.
    assert has_element?(lv, "#recompute #recompute-whole")
    assert has_element?(lv, ~s(#recompute button[phx-click="reexplain"]))
  end

  test "explaining an old on-demand account again gives its opened answers their boards",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others

    # As a round paired last week has it: version 4, one question opened,
    # its answer without the alternative's boards.
    old = Map.put(ctx.round.explanation, "version", 4)
    round = ctx.round |> Ecto.Changeset.change(explanation: old) |> Repo.update!()
    question = store_answer(ctx, [tie(a, ctx)])

    boards =
      Repo.preload(round, :pairings).pairings
      |> Enum.map(&{&1.white_player_id, &1.black_player_id})

    assert Pairing.reexplain_status(ctx.t, round) == :stale

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")
    assert has_element?(lv, "#recompute-whole")

    lv |> element(~s(#recompute button[phx-click="reexplain"])) |> render_click()
    path = ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain"
    assert_redirect(lv, path, 30_000)
    {:ok, lv, _html} = live(conn, path)

    again = Tournaments.get_round(ctx.t.id, ctx.round.number)
    assert again.explanation["version"] == 5
    # The same account - brackets, pairs, fingerprint - not a rebuilt one.
    assert Map.delete(again.explanation, "version") == Map.delete(old, "version")
    assert Pairing.reexplain_status(ctx.t, again) == :current

    # The answer was worked out again by the engine: every candidate that
    # found a round now has it.
    %{^question => answer} = Pairing.stored_alternatives(again)

    for c <- answer["candidates"], c["outcome"] not in ["impossible", "ineligible"] do
      assert %{"pairs" => pairs, "played" => played, "unchanged" => n} = c["alternative"]
      assert length(pairs) == length(played)
      assert n + length(pairs) == length(boards)
    end

    assert Enum.any?(answer["candidates"], &is_map(&1["alternative"]))

    # And no board moved.
    assert Repo.preload(again, :pairings).pairings
           |> Enum.map(&{&1.white_player_id, &1.black_player_id}) == boards

    refute has_element?(lv, "#recompute")
  end

  # Only a tie is ever drawn with its boards. An old account without one
  # would gain nothing from being explained again, so nobody is asked to.
  test "an old account with no tie in it is current, and offers nothing",
       %{conn: conn, scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others

    # Version 4, nothing opened yet; then one answer, and no tie in it.
    old = Map.put(ctx.round.explanation, "version", 4)
    round = ctx.round |> Ecto.Changeset.change(explanation: old) |> Repo.update!()
    assert Pairing.reexplain_status(ctx.t, round) == :current

    store_answer(ctx, [Map.put(tie(a, ctx), "outcome", "worse")])
    assert Pairing.reexplain_status(ctx.t, round) == :current
    assert {:skip, :current} = Pairing.reexplain_round(ctx.t, round.number)

    {:ok, lv, _html} = live(conn, ~p"/t/#{ctx.t.id}/pairings/#{ctx.round.number}/explain")
    refute has_element?(lv, "#recompute")

    # Version 3, the answers inline: the same.
    round = store_version_3(ctx, [Map.put(tie(a, ctx), "outcome", "impossible")])
    assert Pairing.reexplain_status(ctx.t, round) == :current

    # A tie, and it is stale again.
    round = store_version_3(ctx, [tie(a, ctx)])
    assert Pairing.reexplain_status(ctx.t, round) == :stale
  end

  test "a hand-edited old account stays as it is", %{scope: scope} do
    ctx = floated_round(scope)
    [a, _b] = ctx.others
    old = Map.put(ctx.round.explanation, "version", 4)
    round = ctx.round |> Ecto.Changeset.change(explanation: old) |> Repo.update!()
    question = store_answer(ctx, [tie(a, ctx)])

    [p1, p2 | _] = Repo.preload(round, :pairings).pairings |> Enum.filter(& &1.black_player_id)
    p1 |> Ecto.Changeset.change(black_player_id: p2.black_player_id) |> Repo.update!()
    p2 |> Ecto.Changeset.change(black_player_id: p1.black_player_id) |> Repo.update!()

    round = Tournaments.get_round(ctx.t.id, ctx.round.number)
    assert Pairing.reexplain_status(ctx.t, round) == :hand_edited
    assert {:skip, :hand_edited} = Pairing.reexplain_round(ctx.t, round.number)

    kept = Tournaments.get_round(ctx.t.id, ctx.round.number)
    assert kept.explanation == old
    assert %{^question => %{"candidates" => [c]}} = Pairing.stored_alternatives(kept)
    refute Map.has_key?(c, "alternative")
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
