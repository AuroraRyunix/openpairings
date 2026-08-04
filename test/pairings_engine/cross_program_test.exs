defmodule PairingsEngine.CrossProgramTest do
  @moduledoc """
  Cross-program-agreement check — the second half of the fuzz-testing
  harness `docs/fide-endorsement.md` proposes. Runs OpenPairings' own,
  real `PairingsEngine.Pairing.pair_next_round/1` (JaVaFo-backed) against
  `bbpPairings` (Bierema Boyz Programming, Apache-2.0, vendored in
  `priv/bbppairings/` — see `PairingsEngine.Test.BbpPairings`), a
  standalone, independently-written second Dutch-system implementation, on
  byte-identical TRF16 input, round by round, over many random synthetic
  tournaments — diffing the actual pairing (who plays whom), not asking
  either engine whether its own output is "legal".

  This is deliberately a different check from the plain checker verdict a
  `-c` mode would give (see the doc's "why a plain checker isn't the right
  tool" section): a checker only confirms a pairing follows from whatever
  TRF it was handed, and can't catch OpenPairings feeding either engine
  *wrong* input that still happens to produce a locally-legal pairing —
  exactly the bug class both real TRF-input bugs found in this project
  belonged to. Agreement between two independent implementations given
  identical input is a much stronger signal.

  Runs `PAIRING_FUZZ_COUNT` synthetic tournaments (default 8 — enough to
  matter in ordinary CI/dev runs without being slow; set a much higher
  count for a deliberate "throw a pile of random tournaments at it" pass,
  e.g. `PAIRING_FUZZ_COUNT=500 mix test --only javafo --only bbppairings
  test/pairings_engine/cross_program_test.exs`), each with a random 4-24
  player roster and 2-3 rounds, results entered between rounds so
  standings genuinely change and later rounds pair from real score groups,
  not just round 1's rating order.
  """

  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Trf, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngine.Test.BbpPairings

  @moduletag :javafo
  @moduletag :bbppairings

  # Same telemetry-capture pattern pairing_test.exs uses (see its own
  # top-level `setup` doc) — `Pairing`'s scratch TRF file is deleted the
  # instant its JaVaFo run finishes, so this is the only way to get the
  # exact text back out to also hand to bbpPairings.
  setup do
    handler_id =
      "cross-program-trf-capture-#{inspect(self())}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put(:trf_events, [meta | Process.get(:trf_events, [])])
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Each tournament shells out to two separate external binaries per round —
  # deliberately slow at any real PAIRING_FUZZ_COUNT, unlike the rest of the
  # suite. :infinity rather than a bigger fixed number since there's no good
  # one-size-fits-all bound between the default quick run and a deliberate
  # "throw 500 tournaments at it" pass.
  @tag timeout: :infinity
  test "OpenPairings (JaVaFo) and bbpPairings agree on who plays whom, every round, across many random tournaments" do
    count = System.get_env("PAIRING_FUZZ_COUNT", "8") |> String.to_integer()

    disagreements =
      for seed <- 1..count do
        :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
        run_one_tournament(seed)
      end
      |> List.flatten()

    assert disagreements == [], """
    #{length(disagreements)} disagreement(s) out of #{count} synthetic tournament(s) — \
    a legal-but-different pairing choice, not necessarily a bug in either engine (see
    this test module's doc). Each needs its own look to tell which, if either, is right:

    #{Enum.map_join(disagreements, "\n\n", &format_disagreement/1)}
    """
  end

  # Returns this tournament's list of disagreements (possibly []) instead of
  # asserting inline — a fuzz run's whole point is surfacing every
  # disagreement in one pass, not stopping at the first. Pairing still
  # proceeds normally round to round regardless of a disagreement (only
  # OpenPairings' own real pairing ever feeds the next round; bbpPairings is
  # asked about the same input purely for comparison, never fed back in).
  defp run_one_tournament(seed) do
    player_count = Enum.random(4..24)
    round_count = Enum.random(2..3)

    tournament =
      Repo.insert!(%Tournament{name: "Fuzz #{seed}", type: "swiss", rounds_count: round_count})

    for n <- 1..player_count do
      {:ok, _player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "P#{n}, Fuzz#{seed}",
          "fide_rating" => Enum.random(1000..2400)
        })
    end

    for round_number <- 1..round_count do
      assert {:ok, round} = Pairing.pair_next_round(tournament)
      assert round.number == round_number

      # `create_player/2` doesn't assign `pairing_number` itself — only
      # `pair_next_round/1`'s own `ensure_pairing_numbers/2` does, on its
      # first-ever call — so this can only be read back correctly after that
      # call has happened, never from the freshly-created player structs.
      name_to_pairing_number =
        tournament.id |> Tournaments.list_players() |> Map.new(&{&1.name, &1.pairing_number})

      trf = trf_for(tournament.id, round_number)

      assert trf,
             "no TRF captured for tournament #{tournament.id} seed #{seed} round #{round_number}"

      openpairings_pairs = round_pairs_by_rank(round)
      assert {:ok, bbp_pairs} = BbpPairings.pair(trf)

      bbp_translated = translate_bbp_pairs(bbp_pairs, trf, name_to_pairing_number)

      round = Repo.preload(round, :pairings)

      for pairing <- round.pairings do
        if pairing.result in [nil, ""] do
          Tournaments.update_pairing_result(pairing, Enum.random(["1-0", "0-1", "1/2-1/2"]))
        end
      end

      if normalize(bbp_translated) != normalize(openpairings_pairs) do
        %{
          seed: seed,
          tournament_id: tournament.id,
          round: round_number,
          roster_size: player_count,
          openpairings: Enum.sort(openpairings_pairs),
          bbppairings: Enum.sort(bbp_translated),
          trf: trf
        }
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp format_disagreement(d) do
    """
    seed #{d.seed}, tournament #{d.tournament_id}, round #{d.round}, #{d.roster_size} players:
      OpenPairings (pairing_number): #{inspect(d.openpairings)}
      bbpPairings (pairing_number):  #{inspect(d.bbppairings)}
      TRF sent to both:
    #{d.trf}
    """
  end

  # bbpPairings' output pairs are TRF *starting ranks* (the same local
  # numbering the captured TRF itself assigned this run — see
  # PairingsEngine.Pairing.javafo_input/4's rank_by_player_id, which is
  # NOT the same as pairing_number from round 2 onward, since pairing
  # re-sorts into current-standings order first). Translate via the TRF's
  # own player rows (rank -> name) and the roster's own name -> pairing_number
  # map, rather than assuming the two numberings coincide.
  defp translate_bbp_pairs(bbp_pairs, trf, name_to_pairing_number) do
    rank_to_pairing_number =
      trf
      |> Trf.parse()
      |> Map.fetch!(:players)
      |> Map.new(fn p -> {p.rank, Map.fetch!(name_to_pairing_number, p.name)} end)

    Enum.map(bbp_pairs, fn {w, b} ->
      {Map.get(rank_to_pairing_number, w), Map.get(rank_to_pairing_number, b)}
    end)
  end

  defp round_pairs_by_rank(round) do
    round
    |> Repo.preload(pairings: [:white_player, :black_player])
    |> Map.fetch!(:pairings)
    |> Enum.map(fn p ->
      white = p.white_player && p.white_player.pairing_number
      black = p.black_player && p.black_player.pairing_number
      {white, black}
    end)
  end

  # Board order/colour is presentation, not the thing under test here — only
  # WHO is paired with WHOM matters, so sort each pair's own two members and
  # then the whole set, discarding color/board-order noise from both sides.
  defp normalize(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort([a, b]) end)
    |> Enum.sort()
  end

  defp trf_for(tournament_id, round_number) do
    Process.get(:trf_events, [])
    |> Enum.find(fn meta ->
      meta.tournament_id == tournament_id and meta.round == round_number
    end)
    |> case do
      nil -> nil
      meta -> meta.trf
    end
  end
end
