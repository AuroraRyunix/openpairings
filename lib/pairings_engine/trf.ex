defmodule PairingsEngine.Trf.ValidationError do
  @moduledoc """
  Raised by `PairingsEngine.Trf` when a player's round-by-round game data
  contains an illegal FIDE result: an unrecognized result code, or a result
  that is inconsistent with the opponent's own recorded result for the same
  round (e.g. both sides claim a win, or both sides are marked forfeit-win).
  """
  defexception [:message]
end

defmodule PairingsEngine.Trf do
  @moduledoc """
  FIDE TRF16 (Tournament Report File) serializer and parser, per the official
  specification: https://www.fide.com/FIDE/handbook/C04Annex2_TRF16.pdf

  All column positions are 1-indexed and inclusive, exactly as printed in the
  spec. Used for JaVaFo input, FIDE rating export, and TRF import.

  Both `serialize/1` and `parse/1` validate every player's per-round result
  codes before returning, raising `PairingsEngine.Trf.ValidationError` on an
  unrecognized code or an illegal combination between two opponents (see
  `validate_games!/1`). Validation only cross-checks a pairing when both
  sides are present in the given player set and mutually reference each
  other for that round — a lone/dangling reference is not itself an error.
  """

  alias PairingsEngine.Trf.ValidationError

  @player_cols %{
    code: {1, 3},
    starting_rank: {5, 8},
    sex: {10, 10},
    title: {11, 13},
    name: {15, 47},
    fide_rating: {49, 52},
    federation: {54, 56},
    fide_number: {58, 68},
    birth_date: {70, 79},
    points: {81, 84},
    rank: {86, 89}
  }

  @team_cols %{code: {1, 3}, name: {5, 36}}

  @header_codes %{
    name: "012",
    city: "022",
    federation: "032",
    start_date: "042",
    end_date: "052",
    number_of_players: "062",
    number_of_rated_players: "072",
    number_of_teams: "082",
    type: "092",
    chief_arbiter: "102",
    deputy_arbiter: "112",
    time_control: "122",
    # Not in the official TRF16 spec, but real-world precedent from
    # Swiss-Manager (which already emits both) and formalized in FIDE's
    # TRF25/26 draft extension — see docs/import-export.md. Both are
    # optional/additive: an unrecognized header code is already silently
    # ignored by `parse_header_line/3`, so including them never breaks a
    # TRF16-only reader.
    number_of_rounds: "142",
    round_dates: "132",
    generator: "182"
  }

  @type_labels %{
    "swiss" => "Individual: Swiss System",
    "roundrobin" => "Individual: Round Robin System",
    "team-swiss" => "Team: Swiss System",
    "team-roundrobin" => "Team: Round Robin System"
  }

  @result_codes %{
    win: "1",
    draw: "=",
    loss: "0",
    forfeit_win: "+",
    forfeit_loss: "-",
    half_point_bye: "H",
    full_point_bye: "F",
    pairing_allocated_bye: "U",
    zero_point_bye: "Z"
  }

  def result_codes, do: @result_codes

  # TRF16 result codes for an actually-contested game (win/draw/loss/forfeit)
  # vs. an unpaired round (byes of every kind). A forfeit is legally
  # "unplayed" per FIDE Art. 16, but it still occupies a pairing slot (an
  # opponent), unlike a bye — so the two groups get different validation.
  @playing_codes ~w(1 = 0 + -)
  @bye_codes ~w(H F U Z)

  # Legal opponent-result for each of this player's playing codes. A win
  # ("1") only pairs with a loss ("0"); a played "0-0" (both players lose,
  # e.g. both defaulted after making moves) is two losses, so "0" also
  # legally pairs with "0". A double forfeit is "-"/"-"; a single forfeit is
  # "+"/"-". Anything else (both win, both forfeit-win, a win against a
  # draw, etc.) is impossible and rejected.
  @legal_result_pairs %{
    "1" => ["0"],
    "0" => ["1", "0"],
    "=" => ["="],
    "+" => ["-"],
    "-" => ["+", "-"]
  }

  # Round blocks repeat every 10 columns starting at column 92 (round 1):
  # opponent id at base..base+3, colour at base+5, result at base+7.
  defp round_cols(round) do
    base = 92 + (round - 1) * 10
    %{id: {base, base + 3}, colour: {base + 5, base + 5}, result: {base + 7, base + 7}}
  end

  # The "132" round-dates line uses the same cadence with 8-char YY/MM/DD slots.
  defp round_date_cols(round) do
    base = 92 + (round - 1) * 10
    {base, base + 7}
  end

  # Team player slots repeat every 5 columns starting at column 37.
  defp team_player_cols(slot) do
    base = 37 + (slot - 1) * 5
    {base, base + 3}
  end

  ## ---------- Serializing ----------

  @doc """
  Serializes to TRF16 text.

      serialize(%{
        tournament: %{name: ..., city: ..., type: "swiss", ...},
        players: [%{rank: 1, name: ..., points: 2.5,
                    games: [%{opponent_rank: 2, colour: "w", result: "1"}]}],
        teams: [%{name: ..., player_ranks: [1, 2]}]
      })

  `opts[:column_legend]`: when true, inserts the ruler/field-code lines
  Swiss-Manager prepends to its own TRF exports (a `DDD SSSS sTTT NNN...`
  legend plus two column-position rulers) right before the player rows —
  purely a human-readability courtesy for whoever opens the raw file, no
  header code of its own, and safely ignored by any TRF16 reader (including
  `parse/1`, since these lines don't start with a recognized 3-digit code).
  Off by default — deliberately never used for the JaVaFo-input path (see
  `PairingsEngine.Pairing.javafo_input/4`), which has no use for it and
  should stay byte-for-byte what it's always been for a fragile consumer.
  """
  def serialize(data, opts \\ [])

  def serialize(%{tournament: t, players: players} = data, opts) do
    validate_games!(players)
    teams = Map.get(data, :teams, [])
    max_round = Enum.reduce(players, 0, &max(&2, length(&1[:games] || [])))

    header_lines(t, players, teams)
    |> Kernel.++(legend_lines(opts[:column_legend], max_round))
    |> Kernel.++(Enum.map(players, &player_line/1))
    |> Kernel.++(Enum.map(teams, &team_line/1))
    |> Enum.map_join("", &(&1 <> "\r\n"))
  end

  defp legend_lines(true, max_round) when max_round > 0 do
    legend = legend_line(max_round)
    width = String.length(legend)
    ["", ruler_line(width, :tens), ruler_line(width, :units), legend]
  end

  defp legend_lines(_, _), do: []

  defp legend_line(max_round) do
    []
    |> place(@player_cols.code, "DDD")
    |> place(@player_cols.starting_rank, "SSSS")
    |> place(@player_cols.sex, "s")
    |> place(@player_cols.title, "TTT")
    |> place(@player_cols.name, String.duplicate("N", 33))
    |> place(@player_cols.fide_rating, "RRRR")
    |> place(@player_cols.federation, "FFF")
    |> place(@player_cols.fide_number, String.duplicate("I", 11))
    |> place(@player_cols.birth_date, "BBBB/BB/BB")
    |> place(@player_cols.points, "PPPP")
    |> place(@player_cols.rank, "RRRR")
    |> legend_games(max_round)
    |> render()
  end

  defp legend_games(acc, max_round) do
    Enum.reduce(1..max_round, acc, fn round, acc ->
      cols = round_cols(round)
      digit = round |> Integer.to_string() |> String.last()

      acc
      |> place(cols.id, String.duplicate(digit, 4))
      |> place(cols.colour, digit)
      |> place(cols.result, digit)
    end)
  end

  # `:tens` marks every 10th column with its running count (e.g. "1" ending
  # at column 10, "18" ending at column 180); `:units` repeats "1234567890"
  # across the full width — together, a standard fixed-width column ruler.
  defp ruler_line(width, :tens) do
    Enum.reduce(10..width//10, List.duplicate(" ", width), fn col, acc ->
      label = col |> div(10) |> Integer.to_string()
      start = col - String.length(label)

      label
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {ch, i}, acc2 -> List.replace_at(acc2, start + i, ch) end)
    end)
    |> Enum.join()
  end

  defp ruler_line(width, :units) do
    1..width |> Enum.map_join("", &Integer.to_string(rem(&1, 10)))
  end

  defp header_lines(t, players, teams) do
    [
      header(:name, t[:name]),
      header(:city, t[:city]),
      header(:federation, t[:federation]),
      header(:start_date, slash_date(t[:start_date])),
      header(:end_date, slash_date(t[:end_date])),
      header(:number_of_players, length(players)),
      t[:number_of_rated_players] && header(:number_of_rated_players, t[:number_of_rated_players]),
      # Always emitted (082), even 0 for an individual tournament — matches
      # SWAR, which emits "082 0" rather than omitting the line.
      header(:number_of_teams, length(teams)),
      header(:type, t[:type] && Map.get(@type_labels, t[:type], t[:type])),
      header(:chief_arbiter, t[:chief_arbiter])
    ]
    |> Kernel.++(Enum.map(t[:deputy_arbiters] || [], &header(:deputy_arbiter, &1)))
    |> Kernel.++([
      header(:time_control, t[:time_control]),
      header(:number_of_rounds, t[:number_of_rounds]),
      round_dates_line(t[:round_dates]),
      header(:generator, t[:generator])
    ])
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp header(_field, value) when value in [nil, ""], do: nil
  defp header(field, value), do: String.trim_trailing("#{@header_codes[field]} #{value}")

  defp round_dates_line(nil), do: nil
  defp round_dates_line([]), do: nil

  defp round_dates_line(dates) do
    # Only emit the line at all if at least one round actually has a date —
    # a list of all-nil/blank entries (e.g. a round-subset export where none
    # of the selected rounds have a date set) means "no round dates", same
    # as an empty list.
    if Enum.all?(dates, &(&1 in [nil, ""])) do
      nil
    else
      dates
      |> Enum.with_index(1)
      |> Enum.reduce(place([], {1, 3}, "132"), fn {date, i}, acc ->
        place(acc, round_date_cols(i), short_slash_date(date))
      end)
      |> render()
    end
  end

  defp player_line(p) do
    games = p[:games] || []

    []
    |> place(@player_cols.code, "001")
    |> place(@player_cols.starting_rank, p[:rank], align: :right)
    |> place(@player_cols.sex, trf_sex(p[:sex]))
    |> place(@player_cols.title, p[:title])
    |> place(@player_cols.name, p[:name])
    |> place(@player_cols.fide_rating, blank_if_falsy(p[:fide_rating]), align: :right)
    |> place(@player_cols.federation, p[:federation])
    |> place(@player_cols.fide_number, blank_if_falsy(p[:fide_number]), align: :right)
    |> place(@player_cols.birth_date, slash_date(p[:birth_date]))
    |> place(@player_cols.points, format_points(p[:points]), align: :right)
    |> place(@player_cols.rank, p[:rank], align: :right)
    |> place_games(games)
    |> render()
  end

  defp place_games(acc, games) do
    games
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {g, i}, acc ->
      cols = round_cols(i)

      acc
      |> place(cols.id, g[:opponent_rank] || "0000", align: :right)
      |> place(cols.colour, g[:colour] || "-")
      |> place(cols.result, g[:result] || "")
    end)
  end

  defp team_line(t) do
    (t[:player_ranks] || [])
    |> Enum.with_index(1)
    |> Enum.reduce(
      [] |> place(@team_cols.code, "013") |> place(@team_cols.name, t[:name]),
      fn {rank, slot}, acc -> place(acc, team_player_cols(slot), rank, align: :right) end
    )
    |> render()
  end

  # Placements are collected as {start_col, text} and rendered in one pass.
  defp place(placements, {start_col, end_col}, value, opts \\ []) do
    width = end_col - start_col + 1

    text =
      (value || "")
      |> to_string()
      |> strip_controls()
      |> String.slice(0, width)
      |> then(fn s ->
        if opts[:align] == :right,
          do: String.pad_leading(s, width),
          else: String.pad_trailing(s, width)
      end)

    [{start_col, text} | placements]
  end

  # TRF is line- and column-oriented: a newline, carriage return or tab inside
  # a field (a player name has no format check beyond length) would split or
  # shift the fixed-width row. When that row is written to the JaVaFo input
  # file, a crafted name could break the parse or inject a line — so control
  # characters are flattened to spaces before the value is placed. Applies to
  # the pairing input, the category input and the TRF export alike, since all
  # three go through serialize/1.
  defp strip_controls(text), do: String.replace(text, ~r/[\x00-\x1F\x7F]/, " ")

  defp render(placements) do
    placements
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], 1}, fn {start, text}, {io, pos} ->
      {[io, String.duplicate(" ", max(start - pos, 0)), text], start + String.length(text)}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp trf_sex(s) when s in ["w", "W", "f", "F"], do: "w"
  defp trf_sex(s) when s in [nil, ""], do: ""
  defp trf_sex(_), do: "m"

  defp blank_if_falsy(v) when v in [nil, 0, ""], do: ""
  defp blank_if_falsy(v), do: v

  defp format_points(nil), do: "0.0"
  defp format_points(points), do: :erlang.float_to_binary(points / 1, decimals: 1)

  # yyyy-mm-dd -> yyyy/mm/dd
  defp slash_date(nil), do: nil
  defp slash_date(""), do: nil
  defp slash_date(date), do: String.replace(date, "-", "/")

  # yyyy-mm-dd -> yy/mm/dd (required for the "132" round-dates line)
  defp short_slash_date(date) do
    case String.split(date || "", "-") do
      [y, m, d] -> "#{String.slice(y, -2, 2)}/#{m}/#{d}"
      _ -> ""
    end
  end

  ## ---------- Result validation ----------

  # Validates every player's per-round result code, raising ValidationError
  # naming the player and round on the first illegal one found. Games with
  # no result yet (nil/"") are skipped. A code is checked two ways:
  #   1. It must be a recognized TRF16 result code at all.
  #   2. If it's a "playing" code (win/draw/loss/forfeit) and the opponent
  #      for that round is resolvable in `players` *and* mutually references
  #      this player back, the two codes must be a legal pair (see
  #      `@legal_result_pairs`). An unresolvable/dangling opponent reference
  #      is not itself flagged — the caller may be validating a partial
  #      roster (e.g. a single player's card).
  defp validate_games!(players) do
    by_rank = Map.new(players, &{&1[:rank], &1})

    for player <- players,
        {game, round} <- Enum.with_index(player[:games] || [], 1) do
      validate_game!(player, round, game, by_rank)
    end

    :ok
  end

  defp validate_game!(_player, _round, %{result: result}, _by_rank) when result in [nil, ""],
    do: :ok

  defp validate_game!(player, round, %{result: result} = game, by_rank) do
    cond do
      result not in (@playing_codes ++ @bye_codes) ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: unrecognized TRF result code #{inspect(result)}"

      result in @playing_codes and is_nil(game[:opponent_rank]) ->
        raise ValidationError,
          message:
            "#{player_label(player)}, round #{round}: opponent 0000 cannot carry played-game result " <>
              "#{inspect(result)} — opponentless games must use a bye code (F/H/Z/U)"

      result in @playing_codes ->
        validate_playing_pair!(player, round, game, by_rank, result)

      true ->
        :ok
    end
  end

  defp validate_playing_pair!(player, round, game, by_rank, result) do
    with opp_rank when not is_nil(opp_rank) <- game[:opponent_rank],
         opponent when not is_nil(opponent) <- Map.get(by_rank, opp_rank),
         opp_game when not is_nil(opp_game) <- Enum.at(opponent[:games] || [], round - 1),
         true <- opp_game[:opponent_rank] == player[:rank],
         opp_result when opp_result not in [nil, ""] <- opp_game[:result] do
      unless opp_result in Map.get(@legal_result_pairs, result, []) do
        raise ValidationError,
          message:
            "#{player_label(player)} vs #{player_label(opponent)}, round #{round}: " <>
              "illegal result combination '#{result}' / '#{opp_result}'"
      end
    else
      _ -> :ok
    end
  end

  defp player_label(p), do: to_string(p[:name] || p[:rank])

  ## ---------- Parsing ----------

  @doc "Inverse of serialize/1: returns %{tournament: ..., players: ..., teams: ...}."
  def parse(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    result =
      Enum.reduce(lines, %{tournament: %{deputy_arbiters: []}, players: [], teams: []}, fn line,
                                                                                           acc ->
        case String.slice(line, 0, 3) do
          "001" -> update_in(acc.players, &(&1 ++ [parse_player_line(line)]))
          "013" -> update_in(acc.teams, &(&1 ++ [parse_team_line(line)]))
          "132" -> put_in(acc.tournament[:round_dates], parse_round_dates(line))
          code -> parse_header_line(acc, code, line)
        end
      end)

    validate_games!(result.players)
    result
  end

  defp read(line, {start_col, end_col}) do
    line |> String.slice(start_col - 1, end_col - start_col + 1) |> String.trim()
  end

  defp parse_header_line(acc, code, line) do
    field = Enum.find_value(@header_codes, fn {f, c} -> if c == code, do: f end)
    value = line |> String.slice(4..-1//1) |> String.trim()

    case field do
      nil ->
        acc

      :round_dates ->
        acc

      :deputy_arbiter ->
        update_in(acc.tournament.deputy_arbiters, &(&1 ++ [value]))

      f when f in [:start_date, :end_date] ->
        put_in(acc.tournament[f], String.replace(value, "/", "-"))

      f
      when f in [
             :number_of_players,
             :number_of_rated_players,
             :number_of_teams,
             :number_of_rounds
           ] ->
        put_in(acc.tournament[f], parse_int(value) || 0)

      f ->
        put_in(acc.tournament[f], value)
    end
  end

  defp parse_player_line(line) do
    %{
      rank: parse_int(read(line, @player_cols.starting_rank)),
      sex: line |> read(@player_cols.sex) |> String.downcase(),
      title: read(line, @player_cols.title),
      name: read(line, @player_cols.name),
      fide_rating: parse_int(read(line, @player_cols.fide_rating)) || 0,
      federation: read(line, @player_cols.federation),
      fide_number: parse_int(read(line, @player_cols.fide_number)),
      birth_date: line |> read(@player_cols.birth_date) |> iso_date(),
      points: parse_float(read(line, @player_cols.points)) || 0.0,
      games: parse_games(line)
    }
  end

  defp parse_games(line, round \\ 1, acc \\ []) do
    cols = round_cols(round)
    {id_start, _} = cols.id

    if String.length(line) < id_start do
      Enum.reverse(acc)
    else
      id_raw = read(line, cols.id)
      colour = read(line, cols.colour)
      result = read(line, cols.result)

      if id_raw == "" and colour == "" and result == "" do
        Enum.reverse(acc)
      else
        game = %{
          opponent_rank: if(id_raw in ["", "0000"], do: nil, else: parse_int(id_raw)),
          colour: if(colour in ["", "-"], do: nil, else: colour),
          result: if(result == "", do: nil, else: result)
        }

        parse_games(line, round + 1, [game | acc])
      end
    end
  end

  defp parse_team_line(line, slot \\ 1, ranks \\ []) do
    cols = team_player_cols(slot)
    {start, _} = cols

    cond do
      String.length(line) < start ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      read(line, cols) == "" ->
        %{name: read(line, @team_cols.name), player_ranks: Enum.reverse(ranks)}

      true ->
        parse_team_line(line, slot + 1, [parse_int(read(line, cols)) | ranks])
    end
  end

  defp parse_round_dates(line, round \\ 1, acc \\ []) do
    cols = round_date_cols(round)
    {start, _} = cols

    if String.length(line) < start or read(line, cols) == "" do
      Enum.reverse(acc)
    else
      date =
        case String.split(read(line, cols), "/") do
          [y, m, d] when byte_size(y) == 2 -> "20#{y}-#{m}-#{d}"
          [y, m, d] -> "#{y}-#{m}-#{d}"
          _ -> nil
        end

      parse_round_dates(line, round + 1, [date | acc])
    end
  end

  defp iso_date(""), do: ""
  defp iso_date("0000" <> _), do: ""
  defp iso_date(slash), do: String.replace(slash, "/", "-")

  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(""), do: nil

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end
