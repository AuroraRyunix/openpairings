defmodule PairingsEngine.TeamMatchInference do
  @moduledoc """
  Rebuilds the matches of a team tournament imported from a TRF file.

  TRF16 records the teams (`013`, rosters in board order) and every
  individual game, but not which boards formed which match. This module
  works the matches out from the boards, round by round, and writes them
  only when the boards say it unambiguously. See `docs/team-tournaments.md`.

  ## Reading a round

    1. Every board with two players pairs two teams. A board with a player on
       no team, or two players of the same team, is not a team board: the
       round is ambiguous.
    2. The boards between the same two teams are one match. A team with
       boards against two different teams is ambiguous.
    3. A board with one player and no opponent (TRF's full point without a
       game, which is how a board one team could not fill is written) is a
       forfeit win in the match of that player's team. A team with such a
       board and no other board has no known opponent: ambiguous.
    4. Within a match, the boards are ordered by board order, and both teams'
       board orders must rise together board by board, as a line-up does.
       Forfeit boards go where their player's board order puts them; two
       forfeit boards of different teams competing for the same place are
       ambiguous.
    5. Colours: the team with White on board 1 is the match's first team, and
       it must have White on every odd board and Black on every even one -
       the way `PairingsEngine.TeamRounds` seats a match. Anything else is
       ambiguous.

  ## Teams with no board

  In a team round robin a round's single team without boards in an odd field
  is the Berger bye (a match with no opponent, which scores nothing). Other
  teams without boards simply have no match that round, and a note says so.

  In a team Swiss a team without boards either had the pairing-allocated bye
  or was not paired, and TRF16 does not say which. One such team that has
  not had a bye yet is read as the bye - what the pairing does whenever the
  field is odd - and the notice says it was assumed. One that already had a
  bye was not paired ([C2] allows one). Two or more are ambiguous.

  ## What an ambiguous round means

  Nothing is guessed. A team round robin keeps the round's boards as they
  were imported, with no matches: those games count for no team, the
  Pairings page marks them, and a notice names the round and the reason.

  A team Swiss rebuilds no match at all when any round is ambiguous. C.04.6
  pairs every round from the whole team history - opponents, colours, byes,
  floats - and a history with a hole in it cannot be continued as teams. The
  event is imported as paired player by player (`team_pairing_mode`
  "players"), which is what it was before this module existed, and the
  notice says why.

  ## Match and board numbers

  Teams are numbered in the file's `013` order, which is the order the
  export writes them in (their pairing numbers). Boards per match is the
  largest match the file shows. Match numbers follow the order the pairing
  itself writes: by lower team number in a round robin
  (`TeamRoundRobin`), C.04.2 Art. 3.6's order in a team Swiss
  (`TeamSwiss.order_pairs/2`, from the rebuilt history of earlier rounds).
  Board numbers run on through the round, `(match - 1) x boards + board`.
  """

  import Ecto.Query

  alias Ainalrami.TeamPairing.Colour
  alias PairingsEngine.{Repo, TeamRounds, TeamSwiss, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Pairing, Player, Round, Tournament}

  @doc """
  Rebuilds the matches of every round of `tournament` from its boards.
  Returns `{tournament, notes}`, `notes` being import notices
  (`%{kind: :note, text: text}`). A tournament that is not a team round robin
  or a team Swiss, or has no teams or no rounds, is returned unchanged.
  """
  def rebuild(%Tournament{} = t) do
    teams = Tournaments.list_teams(t.id)

    rounds =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^t.id,
          order_by: r.number,
          preload: [:pairings]
      )

    cond do
      teams == [] or rounds == [] -> {t, []}
      not system?(t) -> {t, []}
      true -> do_rebuild(t, teams, rounds)
    end
  end

  defp system?(t),
    do:
      Tournament.team_round_robin?(t) or
        (t.type == "team-swiss" and t.pairing_system == "swiss")

  defp swiss?(t), do: t.type == "team-swiss"

  defp do_rebuild(t, teams, rounds) do
    players =
      Repo.all(from p in Player, where: p.tournament_id == ^t.id)
      |> Map.new(&{&1.id, &1})

    ctx = %{
      players: players,
      team_names: Map.new(teams, &{&1.id, &1.name}),
      team_ids: Enum.map(teams, & &1.id)
    }

    {inferred, _had_bye} =
      Enum.map_reduce(rounds, MapSet.new(), fn round, had_bye ->
        case infer_round(round.pairings, ctx) do
          {:ok, result} ->
            case settle_empties(t, result, had_bye, ctx) do
              {:ok, result} ->
                had_bye = if result.bye, do: MapSet.put(had_bye, result.bye), else: had_bye
                {{round, {:ok, result}}, had_bye}

              {:error, reason} ->
                {{round, {:error, reason}}, had_bye}
            end

          {:error, reason} ->
            {{round, {:error, reason}}, had_bye}
        end
      end)

    boards =
      inferred
      |> Enum.flat_map(fn
        {_round, {:ok, result}} -> Enum.map(result.matches, &length(&1.boards))
        _ -> []
      end)
      |> Enum.max(fn -> 0 end)

    failed = for {round, {:error, reason}} <- inferred, do: {round.number, reason}

    cond do
      boards > Tournament.max_team_boards() ->
        {t,
         [
           note(
             "The file's teams and their board orders were imported, but no matches were rebuilt: " <>
               "a match would need #{boards} boards, more than the #{Tournament.max_team_boards()} " <>
               "this app allows. Its games were imported as individual games."
           )
         ]}

      swiss?(t) and failed != [] ->
        {t, swiss_failure_notes(failed)}

      Enum.all?(inferred, fn {_r, outcome} -> match?({:error, _}, outcome) end) ->
        {t, round_robin_failure_notes(failed, true)}

      true ->
        t = write(t, teams, inferred, max(boards, 1))
        {t, success_notes(t, inferred, failed)}
    end
  end

  ## ---------- one round ----------

  @doc false
  # `{:ok, %{matches: [%{team_a: id, team_b: id, boards: [{k, white_id,
  # black_id, result}]}], empties: [team_id]}}` or `{:error, text}`.
  def infer_round(pairings, ctx) do
    with {:ok, two_sided, one_sided} <- classify(pairings, ctx),
         {:ok, by_pair} <- group_pairs(two_sided, ctx),
         {:ok, by_pair} <- attach_forfeits(by_pair, one_sided, ctx),
         {:ok, matches} <- build_matches(by_pair, ctx) do
      used = matches |> Enum.flat_map(&[&1.team_a, &1.team_b]) |> MapSet.new()
      empties = Enum.reject(ctx.team_ids, &MapSet.member?(used, &1))
      {:ok, %{matches: matches, empties: empties, bye: nil, notes: []}}
    end
  end

  defp classify(pairings, ctx) do
    pairings
    |> Enum.sort_by(& &1.board)
    |> Enum.reduce_while({:ok, [], []}, fn p, {:ok, two, one} ->
      white = p.white_player_id && Map.get(ctx.players, p.white_player_id)
      black = p.black_player_id && Map.get(ctx.players, p.black_player_id)

      cond do
        white && black && (is_nil(white.team_id) or is_nil(black.team_id)) ->
          loner = if is_nil(white.team_id), do: white, else: black
          {:halt, {:error, "#{loner.name} plays a board but is on no team"}}

        white && black && white.team_id == black.team_id ->
          {:halt,
           {:error,
            "#{white.name} and #{black.name} play each other but are both on #{team(ctx, white.team_id)}"}}

        white && black ->
          {:cont, {:ok, [%{pairing: p, white: white, black: black} | two], one}}

        (white || black) && is_nil((white || black).team_id) ->
          {:halt, {:error, "#{(white || black).name} has a board but is on no team"}}

        white || black ->
          {:cont, {:ok, two, [white || black | one]}}

        true ->
          {:cont, {:ok, two, one}}
      end
    end)
    |> case do
      {:ok, two, one} -> {:ok, Enum.reverse(two), Enum.reverse(one)}
      error -> error
    end
  end

  defp group_pairs(two_sided, ctx) do
    by_pair = Enum.group_by(two_sided, &pair_key(&1.white.team_id, &1.black.team_id))

    by_pair
    |> Map.keys()
    |> Enum.flat_map(fn {x, y} -> [{x, {x, y}}, {y, {x, y}}] end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find(fn {_team, keys} -> length(keys) > 1 end)
    |> case do
      nil ->
        {:ok, Map.new(by_pair, fn {key, boards} -> {key, %{two: boards, forfeits: []}} end)}

      {team_id, keys} ->
        others =
          keys
          |> Enum.map(fn {x, y} -> if x == team_id, do: y, else: x end)
          |> Enum.map(&team(ctx, &1))
          |> Enum.sort()
          |> Enum.join(" and ")

        {:error, "#{team(ctx, team_id)} has boards against both #{others}"}
    end
  end

  defp attach_forfeits(by_pair, one_sided, ctx) do
    Enum.reduce_while(one_sided, {:ok, by_pair}, fn player, {:ok, acc} ->
      case Enum.find(Map.keys(acc), fn {x, y} -> player.team_id in [x, y] end) do
        nil ->
          {:halt,
           {:error,
            "#{player.name} (#{team(ctx, player.team_id)}) has a board with no opponent, and " <>
              "#{team(ctx, player.team_id)} has no board with an opponent to tell which team it met"}}

        key ->
          {:cont, {:ok, Map.update!(acc, key, &%{&1 | forfeits: &1.forfeits ++ [player]})}}
      end
    end)
  end

  defp build_matches(by_pair, ctx) do
    by_pair
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {key, boards}, {:ok, acc} ->
      case build_match(key, boards, ctx) do
        {:ok, match} -> {:cont, {:ok, [match | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, matches} -> {:ok, Enum.reverse(matches)}
      error -> error
    end
  end

  defp build_match({x, y}, %{two: two, forfeits: forfeits}, ctx) do
    oriented =
      two
      |> Enum.map(fn b ->
        if b.white.team_id == x,
          do: Map.merge(b, %{x: b.white, y: b.black}),
          else: Map.merge(b, %{x: b.black, y: b.white})
      end)
      |> Enum.sort_by(&order(&1.x))

    names = "#{team(ctx, x)} - #{team(ctx, y)}"

    with :ok <- rising?(oriented, names),
         {:ok, sequence} <- place_forfeits(oriented, forfeits, x, names),
         {:ok, team_a} <- first_team(sequence, x, y, names) do
      boards =
        sequence
        |> Enum.with_index(1)
        |> Enum.map(fn
          {%{pairing: p}, k} ->
            {k, p.white_player_id, p.black_player_id, p.result}

          {%{forfeit: player}, k} ->
            if player.team_id == team_a == TeamRounds.team_a_white?(k),
              do: {k, player.id, nil, "1-0FF"},
              else: {k, nil, player.id, "0-1FF"}
        end)

      {:ok, %{team_a: team_a, team_b: if(team_a == x, do: y, else: x), boards: boards}}
    end
  end

  # Board orders rise together: sorted by one team's, the other team's must
  # rise too.
  defp rising?(oriented, names) do
    oriented
    |> Enum.map(&order(&1.y))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a < b end)
    |> if(
      do: :ok,
      else: {:error, "in #{names}, the two teams' board orders do not line up board by board"}
    )
  end

  # Each forfeit board goes where its player's board order places it among
  # its own team's boards. Two forfeits of different teams in the same gap
  # have no order between them.
  defp place_forfeits(oriented, forfeits, x, names) do
    gaps =
      Enum.group_by(forfeits, fn player ->
        side = if player.team_id == x, do: :x, else: :y
        Enum.count(oriented, &(order(Map.fetch!(&1, side)) < order(player)))
      end)

    if Enum.any?(gaps, fn {_gap, ps} ->
         ps |> Enum.map(& &1.team_id) |> Enum.uniq() |> length() > 1
       end) do
      {:error,
       "in #{names}, boards forfeited by both teams cannot be put in board order between the boards played"}
    else
      sequence =
        Enum.flat_map(0..length(oriented)//1, fn gap ->
          placed =
            gaps
            |> Map.get(gap, [])
            |> Enum.sort_by(&order/1)
            |> Enum.map(&%{forfeit: &1})

          placed ++ if(gap < length(oriented), do: [Enum.at(oriented, gap)], else: [])
        end)

      {:ok, sequence}
    end
  end

  # The team with White on board 1 is team A, which then has White on every
  # odd board and Black on every even one.
  defp first_team(sequence, x, y, names) do
    played =
      sequence |> Enum.with_index(1) |> Enum.filter(fn {b, _k} -> Map.has_key?(b, :pairing) end)

    case played do
      [] ->
        {:error, "#{names} has no board with two players"}

      [{first, k} | _] ->
        x_white? = first.white.team_id == x
        team_a = if x_white? == TeamRounds.team_a_white?(k), do: x, else: y

        if Enum.all?(played, fn {b, k} ->
             b.white.team_id == team_a == TeamRounds.team_a_white?(k)
           end),
           do: {:ok, team_a},
           else: {:error, "in #{names}, the colours do not alternate down the boards"}
    end
  end

  defp order(%Player{board_order: nil}), do: 1_000_000
  defp order(%Player{board_order: n}), do: n

  defp pair_key(a, b), do: if(a < b, do: {a, b}, else: {b, a})

  defp team(ctx, id), do: Map.get(ctx.team_names, id, "a team")

  ## ---------- teams with no board ----------

  defp settle_empties(t, %{empties: empties} = result, had_bye, ctx) do
    names = empties |> Enum.map(&team(ctx, &1)) |> Enum.join(", ")

    cond do
      empties == [] ->
        {:ok, result}

      not swiss?(t) and length(empties) == 1 and rem(length(ctx.team_ids), 2) == 1 ->
        {:ok, %{result | bye: hd(empties)}}

      not swiss?(t) ->
        {:ok,
         %{
           result
           | notes: [
               "no match was rebuilt for #{names}, which #{have(empties)} no board in the file"
             ]
         }}

      length(empties) == 1 and MapSet.member?(had_bye, hd(empties)) ->
        {:ok,
         %{
           result
           | notes: ["#{names} has no boards and has already had the bye, so it was not paired"]
         }}

      length(empties) == 1 ->
        {:ok,
         %{
           result
           | bye: hd(empties),
             notes: ["#{names} has no boards; it was taken to have had the pairing-allocated bye"]
         }}

      true ->
        {:error,
         "#{names} have no boards, and the file does not say which of them had the pairing-allocated bye"}
    end
  end

  defp have([_]), do: "has"
  defp have(_), do: "have"

  ## ---------- writing ----------

  defp write(t, teams, inferred, boards) do
    teams
    |> Enum.with_index(1)
    |> Enum.each(fn {team, n} ->
      team |> Ecto.Changeset.change(pairing_number: n) |> Repo.update!()
    end)

    t = t |> Ecto.Changeset.change(team_boards: boards) |> Repo.update!()
    numbered = TeamRounds.numbered_teams(t.id)
    tpn = Map.new(numbered, &{&1.id, &1.pairing_number})

    for {round, {:ok, result}} <- inferred do
      ordered = order_matches(t, numbered, tpn, round.number, result.matches)
      Repo.delete_all(from p in Pairing, where: p.round_id == ^round.id)

      ordered
      |> Enum.with_index(1)
      |> Enum.each(fn {m, match_no} ->
        match =
          Repo.insert!(%Match{
            round_id: round.id,
            board: match_no,
            team_a_id: m.team_a,
            team_b_id: m.team_b
          })

        for {k, white, black, result} <- m.boards do
          Repo.insert!(%Pairing{
            round_id: round.id,
            match_id: match.id,
            board: (match_no - 1) * boards + k,
            white_player_id: white,
            black_player_id: black,
            result: result
          })
        end
      end)

      if result.bye do
        Repo.insert!(%Match{
          round_id: round.id,
          board: length(ordered) + 1,
          team_a_id: result.bye,
          team_b_id: nil
        })
      end

      Tournaments.freeze_round_display_boards!(round.id)
    end

    Repo.reload!(t)
  end

  # The order the pairing itself writes matches in, so a file exported from
  # this app comes back with the same match numbers.
  defp order_matches(t, numbered, tpn, number, matches) do
    if swiss?(t) do
      by_tpn =
        t
        |> TeamSwiss.engine_input(numbered, numbered, number)
        |> Map.fetch!(:teams)
        |> Map.new(&{&1.tpn, &1})

      matches
      |> Enum.map(fn m ->
        a = Map.fetch!(by_tpn, tpn[m.team_a])
        b = Map.fetch!(by_tpn, tpn[m.team_b])
        {first, _} = Colour.first_team(a, b, :match_points, true)
        %{white: a.tpn, black: b.tpn, first_team: first.tpn, match: m}
      end)
      |> TeamSwiss.order_pairs(by_tpn)
      |> Enum.map(& &1.match)
    else
      Enum.sort_by(matches, &min(tpn[&1.team_a], tpn[&1.team_b]))
    end
  end

  ## ---------- notices ----------

  defp note(text), do: %{kind: :note, text: text}

  defp success_notes(t, inferred, failed) do
    rebuilt = for {round, {:ok, _}} <- inferred, do: round.number

    head =
      if failed == [] do
        note(
          "The file's teams and their board orders were imported, and each round's matches were " <>
            "rebuilt from its boards (a TRF file does not record them). Boards per match: " <>
            "#{t.team_boards}."
        )
      else
        note(
          "The file's teams and their board orders were imported, and the matches of " <>
            "#{round_list(rebuilt)} were rebuilt from the boards (a TRF file does not record them). " <>
            "Boards per match: #{t.team_boards}."
        )
      end

    extra =
      for {round, {:ok, %{notes: notes}}} <- inferred, text <- notes do
        note("Round #{round.number}: #{text}.")
      end

    [head | extra] ++ round_robin_failure_notes(failed, false)
  end

  defp round_robin_failure_notes([], _none_rebuilt?), do: []

  defp round_robin_failure_notes(failed, none_rebuilt?) do
    lead =
      if none_rebuilt?,
        do: [
          note(
            "The file's teams and their board orders were imported, but no round's matches could be " <>
              "rebuilt from its boards."
          )
        ],
        else: []

    lead ++
      for {number, reason} <- failed do
        note(
          "Round #{number}: no matches were rebuilt - #{reason}. Its games were imported as " <>
            "individual games and count for no team; the Pairings page marks them."
        )
      end
  end

  defp swiss_failure_notes(failed) do
    [
      note(
        "The file's teams and their board orders were imported, but no matches were rebuilt: " <>
          "#{round_list(Enum.map(failed, &elem(&1, 0)))} could not be read as matches. A team Swiss " <>
          "is paired from the whole team history (C.04.6), so this tournament continues player by " <>
          "player, and its games were imported as individual games."
      )
      | for {number, reason} <- failed do
          note("Round #{number}: #{reason}.")
        end
    ]
  end

  defp round_list([n]), do: "round #{n}"

  defp round_list(numbers) do
    {init, [last]} = Enum.split(numbers, -1)
    "rounds #{Enum.join(init, ", ")} and #{last}"
  end
end
