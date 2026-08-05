defmodule PairingsEngine.TrfPropertyTest do
  @moduledoc """
  Property-based tests on `PairingsEngine.Trf.serialize/1` — the first half
  of the fuzz-testing harness `docs/fide-endorsement.md` proposes.

  These generate random-but-legal rosters and round histories (contiguous
  starting ranks, mutually consistent result codes — the shape any real
  pairing run, JaVaFo-fed or not, actually produces) and check
  `serialize/1`'s output against ground truth computed independently of
  `serialize/1` itself — reading `parse/1`'s output back and comparing
  against the input, not re-deriving column positions the way `Trf`'s own
  private `place/4`/`read/2` do. This is exactly the class of test that
  would have caught both real TRF-input bugs found earlier this project
  (wrong physical row order, a board-numbering sentinel copied into a real
  field): a data-transformation-correctness check, independent of whether
  any external pairing engine's output looks legal.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PairingsEngine.Trf
  alias PairingsEngine.Trf.ValidationError

  # ---------------------------------------------------------------------
  # generators
  # ---------------------------------------------------------------------

  # Printable, non-control characters only — control characters are their
  # own narrow test below (serialize/1 is documented to flatten them to
  # spaces, which would make a naive round-trip comparison fail for reasons
  # unrelated to the property being tested here).
  defp name_gen do
    gen all(
          last <- string(:alphanumeric, min_length: 1, max_length: 12),
          first <- string(:alphanumeric, min_length: 1, max_length: 12)
        ) do
      "#{last}, #{first}"
    end
  end

  defp federation_gen, do: string(?A..?Z, length: 3)

  defp title_gen, do: member_of(["", "GM", "IM", "FM", "CM", "WGM", "WIM", "WFM", "WCM"])

  defp sex_gen, do: member_of(["m", "w", ""])

  # Bounded so the formatted "%.1f" text always fits the TRF spec's 4-column
  # points field (widest legal value here, "99.5", is exactly 4 characters).
  defp points_gen, do: map(integer(0..199), &(&1 / 2))

  defp rating_gen, do: integer(0..2900)

  defp fide_number_gen, do: one_of([constant(nil), integer(1..9_999_999)])

  # One player, games always attached separately once the round history for
  # the whole roster is known — see roster_and_rounds_gen/1.
  defp bare_player_gen(rank) do
    gen all(
          name <- name_gen(),
          federation <- federation_gen(),
          title <- title_gen(),
          sex <- sex_gen(),
          rating <- rating_gen(),
          fide_number <- fide_number_gen(),
          points <- points_gen()
        ) do
      %{
        rank: rank,
        name: name,
        federation: federation,
        title: title,
        sex: sex,
        fide_rating: rating,
        fide_number: fide_number,
        points: points,
        games: []
      }
    end
  end

  # {code, opponent's code} — every legally paired combination `Trf`'s own
  # (private) @legal_result_pairs recognizes. Hand-maintained in step with
  # that table, not derived from it — `illegal_pair_gen/0` below is exactly
  # the test that catches the two drifting apart (it did, the first time
  # @legal_result_pairs grew "=" </> "0" for VCL.13's asymmetric result and
  # this list wasn't updated yet).
  @legal_pairs [
    {"1", "0"},
    {"0", "1"},
    {"0", "0"},
    {"=", "="},
    {"=", "0"},
    {"0", "="},
    {"+", "-"},
    {"-", "+"},
    {"-", "-"}
  ]

  defp legal_pair_gen, do: member_of(@legal_pairs)

  defp bye_code_gen, do: member_of(["H", "F", "U", "Z"])

  # A roster of 2..12 players with contiguous starting ranks 1..N, plus
  # 0..3 rounds of a genuinely legal history: each round randomly pairs up
  # the roster (Fisher-Yates via Enum.shuffle/1 — fine here since this only
  # needs *a* random pairing per generated case, not shrink-friendly
  # structure), an odd player out gets a random bye code, and every playing
  # pair's two result codes are drawn together from @legal_pairs so they can
  # never disagree — precisely the invariant validate_games!/1 enforces.
  defp roster_and_rounds_gen do
    gen all(
          n <- integer(2..12),
          players <- Enum.map(1..n, &bare_player_gen/1) |> fixed_list(),
          round_count <- integer(0..3),
          round_pair_choices <-
            list_of(list_of(legal_pair_gen(), length: div(n, 2) + 1), length: round_count),
          bye_choices <- list_of(bye_code_gen(), length: round_count)
        ) do
      ranks = Enum.map(players, & &1.rank)

      rounds =
        Enum.zip([round_pair_choices, bye_choices])
        |> Enum.map(fn {pair_codes, bye_code} ->
          build_round(Enum.shuffle(ranks), pair_codes, bye_code)
        end)

      players_with_games =
        Enum.map(players, fn p ->
          games = Enum.map(rounds, &Map.get(&1, p.rank, %{opponent_rank: nil, result: nil}))
          %{p | games: games}
        end)

      players_with_games
    end
  end

  # One round's games, keyed by rank: consecutive pairs from `ranks` each get
  # a legal {code, opponent_code} pair (colour alternated arbitrarily — not
  # under test here, only result-code legality is), a leftover unpaired rank
  # gets `bye_code`.
  defp build_round(ranks, pair_codes, bye_code) do
    {pairs, leftover} =
      case rem(length(ranks), 2) do
        1 -> {Enum.chunk_every(Enum.drop(ranks, 1), 2), Enum.at(ranks, 0)}
        0 -> {Enum.chunk_every(ranks, 2), nil}
      end

    games =
      pairs
      |> Enum.zip(pair_codes)
      |> Enum.flat_map(fn {[a, b], {code_a, code_b}} ->
        [
          {a, %{opponent_rank: b, colour: "w", result: code_a}},
          {b, %{opponent_rank: a, colour: "b", result: code_b}}
        ]
      end)
      |> Map.new()

    if leftover,
      do: Map.put(games, leftover, %{opponent_rank: nil, result: bye_code}),
      else: games
  end

  defp tournament_gen do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 40),
          city <- string(:alphanumeric, min_length: 1, max_length: 20),
          federation <- federation_gen()
        ) do
      %{name: name, city: city, federation: federation, type: "swiss"}
    end
  end

  # ---------------------------------------------------------------------
  # properties
  # ---------------------------------------------------------------------

  property "a legally-paired random roster+history never raises, and round-trips through parse/1" do
    check all(
            tournament <- tournament_gen(),
            players <- roster_and_rounds_gen(),
            max_runs: 100
          ) do
      trf = Trf.serialize(%{tournament: tournament, players: players})
      parsed = Trf.parse(trf)

      assert length(parsed.players) == length(players)
      assert parsed.tournament.name == tournament.name
      assert parsed.tournament.federation == tournament.federation

      by_rank = Map.new(parsed.players, &{&1.rank, &1})

      for expected <- players do
        actual = Map.fetch!(by_rank, expected.rank)

        assert actual.name == expected.name
        assert actual.federation == expected.federation
        assert actual.title == expected.title
        assert actual.fide_rating == expected.fide_rating
        assert actual.points == expected.points

        assert actual.fide_number == expected.fide_number ||
                 (is_nil(expected.fide_number) and actual.fide_number == nil)

        assert length(actual.games) == length(expected.games)

        for {actual_game, expected_game} <- Enum.zip(actual.games, expected.games) do
          assert actual_game.opponent_rank == expected_game.opponent_rank
          assert actual_game.result == expected_game.result
        end
      end
    end
  end

  # Column 81-84, 1-indexed inclusive — Trf's own @player_cols.points. Reads
  # the raw formatted text directly (not via parse/1, which would just prove
  # Float.parse/1 tolerates whatever came out) — this checks the actual
  # fixed-width format every points_gen/0 value produces.
  defp points_col(line), do: line |> String.slice(80, 4) |> String.trim()

  property "every player's points field is always formatted with exactly one decimal" do
    check all(points <- points_gen(), max_runs: 50) do
      players = [%{rank: 1, name: "Solo, Player", points: points, games: []}]
      trf = Trf.serialize(%{tournament: %{name: "T", type: "swiss"}, players: players})
      player_line = trf |> String.split(~r/\r?\n/) |> Enum.find(&String.starts_with?(&1, "001"))

      assert points_col(player_line) =~ ~r/^\d+\.\d$/
      assert String.to_float(points_col(player_line)) == points
    end
  end

  property "an illegal result combination always raises Trf.ValidationError, never silently serializes" do
    check all(
            {code_a, code_b} <- illegal_pair_gen(),
            max_runs: 30
          ) do
      players = [
        %{rank: 1, name: "Alpha, One", points: 0.0, games: [%{opponent_rank: 2, result: code_a}]},
        %{rank: 2, name: "Bravo, Two", points: 0.0, games: [%{opponent_rank: 1, result: code_b}]}
      ]

      assert_raise ValidationError, fn ->
        Trf.serialize(%{tournament: %{name: "T", type: "swiss"}, players: players})
      end
    end
  end

  # Every playing-code combination NOT in @legal_pairs (own note: this is
  # deliberately the complement of the fixture above, built from the same
  # public `Trf.result_codes/0` rather than a second hand-copied list, so it
  # can't silently drift out of sync with what the module actually accepts).
  defp illegal_pair_gen do
    playing_codes =
      Trf.result_codes()
      |> Map.take([:win, :draw, :loss, :forfeit_win, :forfeit_loss])
      |> Map.values()

    all_pairs = for a <- playing_codes, b <- playing_codes, do: {a, b}
    illegal_pairs = Enum.reject(all_pairs, &(&1 in @legal_pairs))

    member_of(illegal_pairs)
  end

  property "control characters in a name never survive into the TRF output, and never break row structure" do
    check all(
            weird <- string([?\t, ?\n, ?\r, ?a, ?B, ?\v], min_length: 1, max_length: 20),
            max_runs: 30
          ) do
      players = [%{rank: 1, name: "Alpha, #{weird}", points: 0.0, games: []}]
      trf = Trf.serialize(%{tournament: %{name: "T", type: "swiss"}, players: players})

      lines = trf |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))
      player_lines = Enum.filter(lines, &String.starts_with?(&1, "001"))

      # Exactly one "001" row, however weird the input — a stray \n/\r inside
      # the name never split it into extra rows, and no control character
      # (verified via the same regex serialize/1 itself strips against)
      # survives into the output at all.
      assert length(player_lines) == 1
      refute Enum.any?(lines, &(&1 =~ ~r/[\x00-\x09\x0B-\x1F\x7F]/))
    end
  end
end
