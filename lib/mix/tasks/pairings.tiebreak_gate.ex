defmodule Mix.Tasks.Pairings.TiebreakGate do
  @shortdoc "Compares OpenPairings' tie-breaks with Ainalrami's on every tournament"

  @moduledoc """
  The gate before OpenPairings hands its tie-breaks to Ainalrami: both
  implementations, on every individual tournament, every code OpenPairings
  has, player by player.

      mix pairings.tiebreak_gate                       # the database
      mix pairings.tiebreak_gate --all                 # every difference, not the first few
      mix pairings.tiebreak_gate --trf DIR [--limit N] # import TRF files first

  OpenPairings' values come from `PairingsEngine.Standings` with every code
  switched on; Ainalrami's from the same game records through
  `PairingsEngine.Standings.AinalramiBridge`. A difference is a bug in one
  of the two - which one is settled against C.07, not by majority.

  `--trf` imports each file through `PairingsEngine.TrfImport` - generated
  tournaments carry the forfeits, trailing byes and odd fields a database
  may not - and compares those. Point it at a copy: the imports stay.

  Only the database and PubSub are started, never the application: its
  publisher would otherwise re-send published tournaments to OpenResults
  from whatever database this runs against.

  Team and Keizer tournaments are skipped: their standings are
  `PairingsEngine.TeamStandings` and `PairingsEngine.Keizer`, not these.
  """

  use Mix.Task

  alias Ainalrami.Tiebreaks
  alias PairingsEngine.{Repo, Standings}
  alias PairingsEngine.Standings.AinalramiBridge
  alias PairingsEngine.Tournaments.Tournament

  import Ecto.Query

  @swiss_codes ~w(BH BHC1 BHC2 MBH SB WIN WON BPG PS KS ARO AROC1)
  # C.07 Article 8: no Buchholz in a round robin.
  @rr_codes ~w(SB WIN WON BPG PS KS ARO AROC1)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [all: :boolean, trf: :string, limit: :integer])

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Repo.start_link()
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PairingsEngine.PubSub)

    tournaments =
      case opts[:trf] do
        nil -> database_tournaments()
        dir -> imported_tournaments(dir, opts[:limit])
      end

    totals =
      Enum.reduce(tournaments, %{tournaments: 0, values: 0, diffs: %{}, forfeit_rule: 0}, fn t,
                                                                                             acc ->
        compare(t, acc, opts[:all] || false)
      end)

    Mix.shell().info(
      "\n#{totals.tournaments} tournaments, #{totals.values} values compared, " <>
        "#{Map.get(totals, :forfeit_rule, 0)} differ by OpenPairings' forfeit and cap rules, " <>
        "#{totals.diffs |> Map.values() |> Enum.sum()} differ otherwise"
    )

    for {code, n} <- Enum.sort(totals.diffs), n > 0 do
      Mix.shell().info("  #{code}: #{n}")
    end
  end

  defp database_tournaments do
    Repo.all(
      from t in Tournament,
        where: is_nil(t.deleted_at),
        where: t.type not in ["team-swiss", "team-roundrobin"],
        where: t.pairing_system != "keizer",
        order_by: t.id
    )
  end

  defp imported_tournaments(dir, limit) do
    dir
    |> String.replace("\\", "/")
    |> Path.join("*.trf")
    |> Path.wildcard()
    |> Enum.take(limit || 1_000_000)
    |> Stream.flat_map(fn file ->
      case PairingsEngine.TrfImport.import_text(File.read!(file)) do
        {:ok, t, _warnings} ->
          [%{t | name: Path.basename(file)}]

        other ->
          Mix.shell().info(
            "-- #{Path.basename(file)}: not imported (#{inspect(other) |> String.slice(0, 120)})"
          )

          []
      end
    end)
  end

  defp compare(t, acc, all?) do
    codes = if t.pairing_system == "round_robin", do: @rr_codes, else: @swiss_codes
    entries = Standings.standings(%{t | tiebreaks: codes})

    case entries do
      [] ->
        acc

      [first | _] ->
        rounds = first.completed_rounds
        event = AinalramiBridge.event(entries, t, rounds)
        {:ok, theirs} = Tiebreaks.compute(event, Enum.map(codes, &AinalramiBridge.c07_code/1))

        all_diffs =
          for code <- codes,
              entry <- entries,
              Map.has_key?(entry.tiebreaks, code),
              [{old, new}] <- [[{entry.tiebreaks[code], value(theirs, code, entry.player.id)}]],
              not same?(old, new),
              do: {code, entry.player.id, old, new}

        # The known differences, both OpenPairings' own:
        #   * it scores a forfeited round as if it had been played - the
        #     scheduled opponent's score, never a VUR - where C.07 2026 makes
        #     it an unplayed round against a capped dummy (16.2.2, 16.2.4,
        #     16.4.1). A bug.
        #   * part-way through an event it caps a bye's dummy at a draw times
        #     the ANNOUNCED rounds, where Ainalrami counts the rounds played
        #     (16.4.2; reading 11). A reading - final standings agree.
        # Recomputing Ainalrami's values under those two rules reproduces
        # OpenPairings; a difference that explains exactly is one of them,
        # and anything left over is something else.
        {forfeit_rule, diffs} =
          case all_diffs do
            [] ->
              {[], []}

            _ ->
              {:ok, as_played} =
                Tiebreaks.compute(
                  forfeits_as_games(%{event | cap_rounds: :announced}),
                  Enum.map(codes, &AinalramiBridge.c07_code/1)
                )

              Enum.split_with(all_diffs, fn {code, id, old, _new} ->
                same?(old, value(as_played, code, id))
              end)
          end

        unless diffs == [] do
          Mix.shell().info(
            "== #{t.id} #{t.name} (#{t.pairing_system}, #{length(entries)} players, #{rounds} rounds)"
          )

          diffs
          |> Enum.group_by(&elem(&1, 0))
          |> Enum.each(fn {code, list} ->
            shown = if all?, do: list, else: Enum.take(list, 3)

            sample =
              Enum.map_join(shown, ", ", fn {_c, id, old, new} ->
                "#{id}: openpairings #{inspect(old)} ainalrami #{inspect(new)}"
              end)

            Mix.shell().info(
              "   #{code} (#{AinalramiBridge.c07_code(code)}): #{length(list)} - #{sample}"
            )
          end)
        end

        # Direct encounter orders a tied group rather than giving a value, so
        # it is checked as an order: OpenPairings' standings under "the
        # score, then DE" may not put anybody above someone Ainalrami ranks
        # higher. Ties Ainalrami leaves may be in any order - OpenPairings
        # settles those by rating and name, which is display, not C.07.
        {:ok, de_ranked} = Tiebreaks.rank(event, ["DE"])
        de_rank = Map.new(de_ranked, &{&1.id, &1.rank})
        op_order = %{t | tiebreaks: ["DE"]} |> Standings.standings() |> Enum.map(& &1.player.id)

        de_wrong =
          op_order
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.filter(fn [a, b] -> de_rank[a] > de_rank[b] end)

        unless de_wrong == [] do
          Mix.shell().info(
            "== #{t.id} #{t.name}: DE order differs at #{length(de_wrong)} place(s), e.g. " <>
              inspect(Enum.take(de_wrong, 3))
          )
        end

        diffs = diffs ++ Enum.map(de_wrong, fn [a, _b] -> {"DE", a, nil, nil} end)

        counted =
          Enum.count(for code <- codes, e <- entries, Map.has_key?(e.tiebreaks, code), do: 1)

        %{
          acc
          | tournaments: acc.tournaments + 1,
            values: acc.values + counted,
            forfeit_rule: Map.get(acc, :forfeit_rule, 0) + length(forfeit_rule),
            diffs:
              Enum.reduce(diffs, acc.diffs, fn {code, _, _, _}, d ->
                Map.update(d, code, 1, &(&1 + 1))
              end)
        }
    end
  end

  defp forfeits_as_games(event) do
    participants =
      Map.new(event.participants, fn {id, p} ->
        rounds =
          Map.new(p.rounds, fn {r, round} ->
            {r,
             if(round.kind in [:forfeit_win, :forfeit_loss],
               do: %{round | kind: :played},
               else: round
             )}
          end)

        {id, %{p | rounds: rounds}}
      end)

    %{event | participants: participants}
  end

  defp value(theirs, code, id) do
    case theirs[AinalramiBridge.c07_code(code)] do
      :dropped -> :dropped
      map -> map[id]
    end
  end

  # OpenPairings writes 0.0 where Ainalrami has no value (no games to average
  # over); both rank it last.
  defp same?(old, :dropped), do: old in [nil, 0, 0.0]
  defp same?(old, nil), do: old in [nil, 0, 0.0]
  defp same?(old, new) when is_number(old) and is_number(new), do: abs(old - new) < 1.0e-6
  defp same?(old, new), do: old == new
end
