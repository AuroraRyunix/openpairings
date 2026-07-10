defmodule PairingsEngine.Pairing do
  @moduledoc """
  Round lifecycle: builds the TRF input for JaVaFo, runs the engine, and
  creates the round with its pairings.

  JaVaFo (© Roberto Ricca, the FIDE-endorsed Dutch-system engine) is invoked
  as `java -jar javafo.jar input.trf -p output.txt`; the output lists one
  "white black" pair of TRF starting ranks per line, 0 meaning the
  pairing-allocated bye.
  """

  import Ecto.Query
  alias PairingsEngine.{Repo, Trf, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}

  def javafo_jar do
    Path.join(:code.priv_dir(:pairings_engine), "javafo/javafo.jar")
  end

  @doc "Pairs the next round. Returns {:ok, round} or {:error, reason}."
  def pair_next_round(%Tournament{} = tournament) do
    players = active_players(tournament.id)
    paired = paired_rounds_count(tournament.id)
    next_number = paired + 1

    cond do
      next_number > tournament.rounds_count ->
        {:error, "All #{tournament.rounds_count} rounds have already been paired"}

      length(players) < 2 ->
        {:error, "At least two active players are needed"}

      not round_complete?(tournament.id, paired) ->
        {:error, "Round #{paired} still has missing results"}

      true ->
        tournament
        |> ensure_pairing_numbers(players)
        |> do_pair(next_number)
    end
  end

  @doc "Deletes a paired round (only the latest one, to keep history sane)."
  def delete_round(tournament_id, number) do
    if number == paired_rounds_count(tournament_id) do
      Repo.delete_all(
        from r in Round, where: r.tournament_id == ^tournament_id and r.number == ^number
      )

      :ok
    else
      {:error, "Only the latest round can be unpaired"}
    end
  end

  def paired_rounds_count(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  def round_complete?(_tournament_id, 0), do: true

  def round_complete?(tournament_id, number) do
    not Repo.exists?(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and r.number == ^number and p.result == ""
    )
  end

  ## ---------- pairing numbers ----------

  # Assigned once (highest rating first, FIDE C.04.2.B), then frozen.
  defp ensure_pairing_numbers(tournament, players) do
    if Enum.any?(players, &is_nil(&1.pairing_number)) do
      max_existing =
        players |> Enum.map(&(&1.pairing_number || 0)) |> Enum.max(fn -> 0 end)

      players
      |> Enum.filter(&is_nil(&1.pairing_number))
      |> Enum.sort_by(&{-Player.rating(&1), &1.name})
      |> Enum.with_index(max_existing + 1)
      |> Enum.each(fn {player, number} ->
        {:ok, _} = Tournaments.update_player(player, %{pairing_number: number})
      end)
    end

    tournament
  end

  ## ---------- the pairing run ----------

  defp do_pair(tournament, next_number) do
    players = active_players(tournament.id)
    trf = javafo_input(tournament, players)

    dir = Path.join(System.tmp_dir!(), "pairingsengine")
    File.mkdir_p!(dir)
    input = Path.join(dir, "t#{tournament.id}_r#{next_number}.trf")
    output = Path.join(dir, "t#{tournament.id}_r#{next_number}_pairs.txt")
    File.write!(input, trf)

    case System.cmd("java", ["-jar", javafo_jar(), input, "-p", output],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        output
        |> File.read!()
        |> parse_pairs()
        |> create_round(tournament, players, next_number)

      {out, code} ->
        {:error, "JaVaFo failed (exit #{code}): #{String.slice(out, 0, 300)}"}
    end
  end

  # JaVaFo pairing output: first line = number of pairs, then "white black"
  # per line as TRF starting ranks; 0 = pairing-allocated bye.
  defp parse_pairs(text) do
    [_count | lines] =
      text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == ""))

    Enum.map(lines, fn line ->
      [w, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {w, b}
    end)
  end

  defp create_round(pairs, tournament, players, next_number) do
    by_number = Map.new(players, &{&1.pairing_number, &1})

    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing"
        })

      pairs
      |> Enum.with_index(1)
      |> Enum.each(fn {{w, b}, board} ->
        white = Map.fetch!(by_number, w)
        black = if b == 0, do: nil, else: Map.fetch!(by_number, b)

        Repo.insert!(%Pairing{
          round_id: round.id,
          board: board,
          white_player_id: white.id,
          black_player_id: black && black.id,
          result: if(b == 0, do: "bye", else: "")
        })
      end)

      round
    end)
  end

  ## ---------- JaVaFo TRF input ----------

  @doc "Builds the TRF text JaVaFo takes as input (TRF16 + XXR extension)."
  def javafo_input(tournament, players \\ nil) do
    players = players || active_players(tournament.id)
    by_id = Map.new(players, &{&1.id, &1})
    games = games_per_player(tournament, by_id)

    trf_players =
      players
      |> Enum.sort_by(& &1.pairing_number)
      |> Enum.map(fn p ->
        player_games = Map.get(games, p.id, [])

        %{
          rank: p.pairing_number,
          sex: p.sex,
          title: p.title,
          name: p.name,
          fide_rating: Player.rating(p),
          federation: p.federation,
          fide_number: p.fide_id,
          birth_date: p.birth_year && "#{p.birth_year}/00/00",
          points: player_points(player_games, tournament),
          games: Enum.map(player_games, &Map.take(&1, [:opponent_rank, :colour, :result]))
        }
      end)

    trf =
      Trf.serialize(%{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          federation: tournament.federation,
          type: tournament.type,
          chief_arbiter: tournament.chief_arbiter
        },
        players: trf_players
      })

    # XXR: total number of rounds — required by JaVaFo to plan the pairing.
    trf <> "XXR #{tournament.rounds_count}\r\n"
  end

  defp active_players(tournament_id) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^tournament_id and p.status == "active"
    )
  end

  # Games in TRF terms for every paired round: opponent pairing number,
  # colour, TRF result code. Rounds without a record become Z (zero-point bye).
  defp games_per_player(tournament, by_id) do
    rounds =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament.id,
          order_by: r.number,
          preload: [pairings: []]
      )

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament.id,
          select: %{player_id: b.player_id, round: b.round, type: b.type}
      )

    bye_map = Map.new(byes, &{{&1.player_id, &1.round}, &1.type})

    for {player_id, _player} <- by_id, into: %{} do
      games =
        Enum.map(rounds, fn round ->
          pairing =
            Enum.find(round.pairings, fn pr ->
              pr.white_player_id == player_id or pr.black_player_id == player_id
            end)

          cond do
            pairing != nil ->
              trf_game(pairing, player_id, by_id)

            bye_type = bye_map[{player_id, round.number}] ->
              %{opponent_rank: nil, colour: nil, result: bye_code(bye_type), points_kind: bye_type}

            true ->
              %{opponent_rank: nil, colour: nil, result: "Z", points_kind: "zero"}
          end
        end)

      {player_id, games}
    end
  end

  defp trf_game(pairing, player_id, by_id) do
    white? = pairing.white_player_id == player_id

    opponent_id = if white?, do: pairing.black_player_id, else: pairing.white_player_id
    opponent = opponent_id && Map.get(by_id, opponent_id)

    result =
      case {pairing.result, white?} do
        {"bye", _} -> "U"
        {"1-0", true} -> "1"
        {"1-0", false} -> "0"
        {"0-1", true} -> "0"
        {"0-1", false} -> "1"
        {"1/2-1/2", _} -> "="
        {"+--", true} -> "+"
        {"+--", false} -> "-"
        {"--+", true} -> "-"
        {"--+", false} -> "+"
        {"0-0", _} -> "-"
        {"", _} -> nil
        _ -> nil
      end

    %{
      opponent_rank: opponent && opponent.pairing_number,
      colour:
        cond do
          pairing.result == "bye" or opponent == nil -> nil
          white? -> "w"
          true -> "b"
        end,
      result: result,
      points_kind: "game"
    }
  end

  defp bye_code("requested-half"), do: "H"
  defp bye_code("requested-zero"), do: "Z"
  defp bye_code("absent"), do: "Z"
  defp bye_code("pairing-allocated"), do: "U"
  defp bye_code(_), do: "Z"

  defp player_points(games, t) do
    games
    |> Enum.map(fn g ->
      case g.result do
        "1" -> t.points_win
        "+" -> t.points_win
        "=" -> t.points_draw
        "H" -> t.points_draw
        "F" -> t.points_win
        "U" -> t.bye_value
        _ -> t.points_loss
      end
    end)
    |> Enum.sum()
  end
end
