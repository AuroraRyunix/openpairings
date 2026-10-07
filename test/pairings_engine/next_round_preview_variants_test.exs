defmodule PairingsEngine.NextRoundPreviewVariantsTest do
  @moduledoc """
  The preview's batch path (`Ainalrami.Pairing.pair_variants/3`, through
  `PairingsEngine.Pairing.preview_variants/2`) against the one-outcome-at-a-
  time path it replaced: for every outcome of 1..6 open games, on generated
  events with byes, absences, withdrawals, hard and soft forbidden pairs,
  club rules, bye exclusions, a fixed table, Baku acceleration, a late
  entrant and a field small enough to run out of legal rounds - the same
  boards, colours, labels, byes and refusals, and so the same preview.
  Faster is the only difference allowed.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{NextRoundPreview, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  @moduletag timeout: :infinity

  setup do
    NextRoundPreview.Memo.clear()
    :ok
  end

  test "a plain odd field, 1..6 open games" do
    t = plain_tournament(17)
    play(t, 2)
    assert_paths_agree(t, 1..6, :batch)
  end

  test "most options on, a late entrant waiting, 1..6 open games" do
    t = options_tournament()
    play(t, 3)
    insert_player(t, 24, %{start_round: 5})
    assert_paths_agree(t, 1..6, :batch)
  end

  test "a withdrawal, an absentee for the next round and a bigger field, 1..4 open games" do
    t = plain_tournament(41, %{rounds_count: 9})
    play(t, 3)
    [first | _] = players(t)
    set_player(first, absent_rounds: "5")
    set_player(Enum.at(players(t), 9), status: "withdrawn")
    assert_paths_agree(t, 1..4, :batch)
  end

  test "a field running out of legal rounds: refusals are the same refusals" do
    # Six players, five rounds: some outcomes of round 3 already leave
    # round 4 without a legal pairing. Both paths must refuse the same ones,
    # in the same words.
    t = plain_tournament(6, %{rounds_count: 5})
    play(t, 2)

    counts = assert_paths_agree(t, 1..3, :batch)
    assert Enum.any?(counts, fn {_k, _outcomes, failed} -> failed > 0 end)
  end

  test "bye preferences: the batch declines and the preview pairs one at a time" do
    t = plain_tournament(15)
    play(t, 2)
    set_player(Enum.at(players(t), 3), bye_preference: "avoid_soft")
    assert_paths_agree(t, 1..2, :fallback)
  end

  test "pairing by category: the batch declines" do
    t =
      Repo.insert!(%PairingsEngine.Tournaments.Tournament{
        name: "Categories",
        type: "swiss",
        rounds_count: 5,
        categories_enabled: true,
        pair_by_category: true,
        categories: ["A", "B"]
      })

    for i <- 1..14 do
      category = if rem(i, 2) == 0, do: "A", else: "B"
      insert_player(t, i, %{category: category, categories: [category]})
    end

    play(t, 1)
    assert_paths_agree(t, 1..2, :fallback)
  end

  # `rounds` rounds paired and finished, and the next one paired.
  defp play(t, rounds) do
    for _ <- 1..rounds do
      pair!(t)
      finish_latest_round(t)
    end

    pair!(t)
  end

  defp players(t),
    do:
      Repo.all(
        from p in PairingsEngine.Tournaments.Player,
          where: p.tournament_id == ^t.id,
          order_by: p.id
      )

  # For each k: the latest round with exactly k games open, every outcome
  # paired both ways - compared outcome by outcome, and as the classified
  # preview. `expect` is whether the batch takes the outcomes (`:batch`) or
  # declines them (`:fallback`). Returns `[{k, outcomes, failed}]`.
  defp assert_paths_agree(t, ks, expect) do
    for k <- ks do
      leave_only_open(t, k)
      {:ok, context} = Engine.preview_context(reload(t))
      games = NextRoundPreview.open_games(t.id, context.round_number)
      assert length(games) == k
      worlds = NextRoundPreview.worlds(k)

      batch =
        NextRoundPreview.pair_outcomes(context, games, worlds, fn _, l -> l end, path: :batch)

      single =
        NextRoundPreview.pair_outcomes(context, games, worlds, fn _, l -> l end, path: :single)

      assert length(batch) == Integer.pow(3, k)

      for {{b, s}, world} <- Enum.zip(Enum.zip(batch, single), worlds) do
        assert b == s, "k=#{k}, outcome #{inspect(world)}: the batch differs"
      end

      # Which path actually ran: the batch is not allowed to pass this test
      # by declining everything.
      fast = Engine.preview_base(context, NextRoundPreview.world_results(games, hd(worlds)))
      results = Enum.map(worlds, &NextRoundPreview.world_results(games, &1))

      case expect do
        :batch -> assert {:ok, _} = Engine.preview_variants(fast, results)
        :fallback -> assert Engine.preview_variants(fast, results) == :fallback
      end

      assert strip(NextRoundPreview.run(reload(t), memo: false, path: :batch)) ==
               strip(NextRoundPreview.run(reload(t), memo: false, path: :single))

      {k, length(batch), Enum.count(batch, &match?({:error, _}, &1))}
    end
  end

  defp strip({:ok, preview}), do: {:ok, Map.delete(preview, :elapsed_ms)}
  defp strip(other), do: other

  # The latest round with exactly `k` boards open, from the top board down.
  defp leave_only_open(t, k) do
    games =
      latest_round(t).pairings
      |> Enum.filter(& &1.black_player_id)
      |> Enum.sort_by(& &1.board)

    {open, rest} = Enum.split(games, k)

    for p <- open, p.result != "", do: {:ok, _} = Tournaments.update_pairing_result(p, "")

    for p <- rest,
        p.result == "",
        do: {:ok, _} = Tournaments.update_pairing_result(p, default_result(p.board))
  end
end
