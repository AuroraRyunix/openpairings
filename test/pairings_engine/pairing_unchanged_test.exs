defmodule PairingsEngine.PairingUnchangedTest do
  @moduledoc """
  The next-round preview shares the Swiss pipeline with the real "pair next
  round" (`PairingsEngine.Pairing.plan_round/4` and friends). Moving the
  pipeline apart into "work out the round" and "save it" must not change a
  single thing the real pairing writes.

  `test/fixtures/next_round_preview/golden.exs` was produced by these very
  scenarios on the code BEFORE that refactor (0.70.0, commit 9b09d89). Each
  test replays its scenario and compares everything the pairing wrote -
  pairing numbers, boards, frozen board labels, results of byes, bye rows,
  recorded virtual points and the round's account - with ids replaced by
  names. Run with `WRITE_PAIRING_GOLDEN=1` only to regenerate it from a
  version known to be right.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  @golden_path Path.expand("../fixtures/next_round_preview/golden.exs", __DIR__)

  test "a single-pool Swiss with most options on pairs exactly as before" do
    check(:options, options_scenario())
  end

  test "a per-category Swiss pairs exactly as before" do
    check(:categories, category_scenario())
  end

  defp options_scenario do
    t = options_tournament()

    pair!(t)
    finish_latest_round(t)
    pair!(t)
    finish_latest_round(t)

    # A withdrawal and a late entrant who has no pairing number yet.
    [withdrawn] =
      Repo.all(
        from p in PairingsEngine.Tournaments.Player,
          where: p.tournament_id == ^t.id and p.name == "Player 022"
      )

    set_player(withdrawn, status: "withdrawn")
    insert_player(t, 24, %{start_round: 3})

    pair!(t)
    finish_latest_round(t)
    pair!(t)
    finish_latest_round(t, fn board -> default_result(board + 1) end)
    pair!(t)

    snapshot(t)
  end

  defp category_scenario do
    t =
      Repo.insert!(%Tournament{
        name: "Categories",
        type: "swiss",
        rounds_count: 5,
        categories_enabled: true,
        pair_by_category: true,
        categories: ["A", "B", "C"]
      })

    for i <- 1..15 do
      category = if i == 15, do: "C", else: if(rem(i, 2) == 0, do: "A", else: "B")
      insert_player(t, i, %{category: category, categories: [category]})
    end

    pair!(t)
    finish_latest_round(t)
    pair!(t)
    finish_latest_round(t)
    pair!(t)

    snapshot(t)
  end

  defp check(key, snapshot) do
    if System.get_env("WRITE_PAIRING_GOLDEN") == "1" do
      golden = if File.exists?(@golden_path), do: read_golden(), else: %{}
      File.mkdir_p!(Path.dirname(@golden_path))

      File.write!(
        @golden_path,
        inspect(Map.put(golden, key, snapshot), limit: :infinity, printable_limit: :infinity)
      )
    else
      assert Map.fetch!(read_golden(), key) == snapshot
    end
  end

  defp read_golden do
    {golden, _binding} = Code.eval_file(@golden_path)
    golden
  end
end
