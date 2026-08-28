defmodule PairingsEngine.PgnExport do
  @moduledoc """
  Metadata-only PGN export. OpenPairings never records moves, so every
  game's movetext is just its result token (or `*` for an unplayed/unknown
  result) - the value here is the Seven Tag Roster, built from the
  tournament, round and pairing data the app already has. See
  `docs/pgn-export.md`.
  """

  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  @doc """
  Builds PGN text for `tournament`. `round_number` limits the export to one
  round; `nil` (the default) exports every paired round, in round order.
  Byes are skipped - there's no opponent to record a game against. Returns
  `""` when there's nothing to export (unpaired round, or a round with only
  byes).

  `opts[:board]` (default `false`) adds a supplemental `[Board "N"]` tag
  to every game, right after `Round`. `N` is the REAL `pairing.board` -
  see `board_tag/1` for why this is the one board-numbered surface in the
  app that does NOT print `PairingDisplay`'s label.
  """
  def export(tournament, round_number \\ nil, opts \\ []) do
    board? = Keyword.get(opts, :board, false)

    tournament
    |> rounds_for(round_number)
    |> Enum.flat_map(&games_for_round(tournament, &1, board?))
    |> Enum.map(&game_text/1)
    |> Enum.join("\n\n")
    |> append_trailing_newline()
  end

  defp rounds_for(tournament, nil) do
    Tournaments.list_rounds(tournament.id)
    |> Enum.map(&Tournaments.get_round(tournament.id, &1.number))
  end

  defp rounds_for(tournament, round_number) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil -> []
      round -> [round]
    end
  end

  defp games_for_round(tournament, round, board?) do
    round.pairings
    |> Enum.reject(&(&1.result == "bye" or is_nil(&1.black_player_id)))
    |> Enum.map(&{tournament, round, &1, if(board?, do: &1.board)})
  end

  defp game_text({tournament, round, pairing, board}) do
    headers =
      [
        tag("Event", tournament.name),
        tag("Site", site_tag(tournament)),
        tag("Date", date_tag(round.date)),
        tag("Round", to_string(round.number))
      ] ++
        board_tag(board) ++
        [
          tag("White", pairing.white_player.name),
          tag("Black", pairing.black_player.name),
          tag("Result", result_tag(pairing.result))
        ] ++ optional_tags(pairing)

    Enum.join(headers, "\n") <> "\n\n" <> result_tag(pairing.result)
  end

  # `nil` when `export/3`'s `board:` option wasn't passed - supplemental,
  # right after Round, the conventional spot for a team/multi-board [Board]
  # tag in the wild.
  #
  # The REAL `pairing.board`, and this is the one place in the app that
  # deliberately disagrees with `PairingDisplay`'s label. It used to carry
  # the label, on the reasoning that the tag should match what the arbiter
  # reads on the pairing sheet.
  #
  # What [Board] is FOR settles it. Nothing renders a PGN tag to a human at
  # the board; the tag is how a reader or a database tells one game of a
  # round apart from the others - (Event, Round, Board) is the natural key
  # for a round's games, and PGN gives a reader nothing else to key on
  # short of the player names. That job requires a value unique within the
  # round, and the label is not one: `fixed_board` may legitimately collide
  # with an ordinary board number (a decision, not a bug - see
  # `PairingsEngine.FixedBoardCollisionTest`), so a round could export two
  # games both tagged [Board "1"] and a reader had no way to separate them.
  # `pairing.board` is engine-assigned and unique within a round by
  # construction, which is exactly the property the tag needs.
  #
  # This pulls the OPPOSITE way from the printed result cards and place
  # cards, which were just moved onto the label for the mirror-image reason
  # (see `PairingsEngineWeb.PrintController.round_and_board/2`): a card is
  # read by a person who has to find a physical table, so it must agree
  # with the sheet on the wall; a PGN is read by software that has to tell
  # two games apart, so it must be unique. Same underlying tension, two
  # different documents, two different correct answers - resolving both the
  # same way would have broken one of them.
  #
  # Nothing is lost by dropping the label here: PGN carries no notion of a
  # physical/accessible table, the fixed-table fact is not something a game
  # database has any use for, and inventing a non-standard tag to smuggle
  # it across would only give readers a second board number to disagree
  # with the first. An arbiter who wants the sheet's numbering has the
  # sheet.
  defp board_tag(nil), do: []
  defp board_tag(board), do: [tag("Board", to_string(board))]

  defp site_tag(%Tournament{venue: v}) when is_binary(v) and v != "", do: v
  defp site_tag(%Tournament{city: c}) when is_binary(c) and c != "", do: c
  defp site_tag(_), do: "?"

  defp date_tag(date) when is_binary(date) do
    case String.split(date, "-") do
      [y, m, d] when byte_size(y) == 4 and byte_size(m) == 2 and byte_size(d) == 2 ->
        "#{y}.#{m}.#{d}"

      _ ->
        "????.??.??"
    end
  end

  defp date_tag(_), do: "????.??.??"

  # Forfeits carry a nominal decisive result even though the game was never
  # played; a double forfeit or a played double-loss has no single-sided
  # PGN equivalent, so it falls back to "*" (PGN's own "unknown result"
  # marker) same as a blank/not-yet-entered result.
  defp result_tag("1-0"), do: "1-0"
  defp result_tag("0-1"), do: "0-1"
  defp result_tag("1/2-1/2"), do: "1/2-1/2"
  # Played but unrated: the game happened and had a winner, so PGN records
  # it exactly as its rated twin. PGN has no "unrated" concept to preserve.
  defp result_tag("1-0U"), do: "1-0"
  defp result_tag("0-1U"), do: "0-1"
  defp result_tag("1/2-1/2U"), do: "1/2-1/2"
  defp result_tag("1-0FF"), do: "1-0"
  defp result_tag("0-1FF"), do: "0-1"
  # The legacy spellings of those same two single-sided forfeits.
  # `Keizer.classify_result/2` and `Standings` both accept them, and they
  # reach this module from historical rows and hand-edited data; here they
  # fell to the catch-all and exported as "*", an unknown result, where
  # their `FF` twins export as a decisive one.
  #
  # "0-0FF" is deliberately still absent, with "0-0", "1/2-0" and "0-1/2":
  # a double forfeit and the asymmetric results have no single-sided PGN
  # equivalent, so "*" is the honest tag for them.
  defp result_tag("+--"), do: "1-0"
  defp result_tag("--+"), do: "0-1"
  defp result_tag(_), do: "*"

  defp optional_tags(pairing) do
    elo_tags(pairing.white_player, "White") ++ elo_tags(pairing.black_player, "Black")
  end

  defp elo_tags(player, side) do
    rating =
      if (player.fide_rating || 0) > 0, do: player.fide_rating, else: player.national_rating

    elo_tag =
      if is_integer(rating) and rating > 0, do: [tag("#{side}Elo", to_string(rating))], else: []

    fide_tag = if player.fide_id, do: [tag("#{side}FideId", to_string(player.fide_id))], else: []

    elo_tag ++ fide_tag
  end

  defp tag(name, value), do: "[#{name} \"#{escape(value)}\"]"

  defp escape(value) do
    value
    |> to_string()
    # A PGN tag is one line: a newline/CR (or other control char) in a player
    # name would split the tag or inject a fake one into the exported file.
    # Flatten controls to spaces first, then escape the two PGN metacharacters.
    |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp append_trailing_newline(""), do: ""
  defp append_trailing_newline(text), do: text <> "\n"
end
