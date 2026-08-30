defmodule PairingsEngine.Results do
  @moduledoc """
  What a result code is, and what it means from one player's seat.

  ## Why this module exists

  A stored result is a short string - `"1-0"`, `"1/2-1/2U"`, `"0-0FF"` - and
  four different questions get asked of it: which codes may be stored, how
  many points each side gets, was the game played over the board, and did
  this player win. The first three had one answer each. The fourth was
  re-derived, independently, in five places, by comparing the points already
  awarded against `tournament.points_win`:

      if game.points >= tournament.points_win, do: :win, else: :loss

  That reads correctly under 1/½/0 and is wrong the moment a tournament
  scores anything else. Under the Belgian 3-2-1 scheme (`points_win` 2.0,
  `presence_value` 1.0) a **draw** stores 2.0, so `2.0 >= 2.0` calls it a
  win - on the player card, the crosstable, the pairing-explanation trail
  and the players grid at once, with the standings beside them disagreeing.

  The code always knew. `"1/2-1/2"` is a draw whatever a draw is worth, so
  the classification belongs to the code and is written down once, here.

  ## The table

  Each row is `{code, white_outcome, black_outcome, played?, forfeit?}`.

    * **outcome** is `:win | :draw | :loss` from that seat. The asymmetric
      disciplinary codes (VCL.13) are why the two seats are listed
      separately rather than mirrored: `"1/2-0"` is a draw for White and a
      loss for Black.
    * **played?** means contested over the board - FIDE Art. 16's unplayed
      rules apply when it is false. A forfeit is unplayed for BOTH sides,
      including the one awarded the point.
    * **forfeit?** separates the never-played forfeits from `"0-0"`, which
      is a played game both players lose (both defaulted or were ejected
      after making moves).

  `"…U"` are played-but-unrated (TRF `W`/`D`/`L`, VCL4THP Q185): contested
  games that do not reach the rating report, typically ended before the
  minimum number of moves. They score and pair exactly like their rated
  twins, so they classify identically here - what makes them unrated is the
  rating report, not the result.

  `"+--"`/`"--+"` are the historical forfeit notation, still readable from
  SWAR imports and old data; `entry_codes/0` no longer offers them.

  ## What still keeps its own table, and why

  `PairingsEngine.Keizer.classify_result/2` answers a **different** question.
  Keizer's scoring needs `:half_win` and `:forfeit_win` as distinct buckets,
  because a forfeit win pays half the winner's OWN value rather than the
  opponent's. Its atoms happen to collapse onto these three by value today,
  but that is arithmetic coincidence, not the same question, so it is left
  alone deliberately rather than folded in and re-expanded.

  `PairingsEngine.Pairing.trf_game/3` maps code plus seat to a TRF16
  character. That is a detail of the file format, it is already driven by
  the code rather than by points, and it sits on the path that feeds the
  pairing engine - so it keeps its explicit table too.
  """

  @table [
    #  code          white  black  played?  forfeit?
    {"1-0", :win, :loss, true, false},
    {"1/2-1/2", :draw, :draw, true, false},
    {"0-1", :loss, :win, true, false},
    {"1/2-0", :draw, :loss, true, false},
    {"0-1/2", :loss, :draw, true, false},
    {"1-0FF", :win, :loss, false, true},
    {"0-1FF", :loss, :win, false, true},
    {"0-0FF", :loss, :loss, false, true},
    {"0-0", :loss, :loss, true, false},
    {"1-0U", :win, :loss, true, false},
    {"0-1U", :loss, :win, true, false},
    {"1/2-1/2U", :draw, :draw, true, false},
    {"+--", :win, :loss, false, true},
    {"--+", :loss, :win, false, true}
  ]

  # A pairing-allocated bye is stored as a pairing with no black player. It
  # is not a game, so it has no outcome and no seat; its points come from
  # `PairingsEngine.Standings.bye_points/2`, the single source of truth for
  # every kind of bye.
  @bye "bye"

  # The blank a board sits at between being paired and someone entering a
  # score. Not a played "0-0" - no record is built for it at all.
  @blank ""

  @codes [@blank] ++ Enum.map(@table, &elem(&1, 0)) ++ [@bye]

  @doc """
  Every code that may be stored in `pairings.result`, including the blank
  and `"bye"`. This is what the schema validates against.
  """
  def codes, do: @codes

  @doc """
  The codes an arbiter may write from the result-entry UI - every real
  result, plus the blank that clears one.

  Excludes `"bye"` (assigned by the pairing engine, never typed) and the
  legacy `"+--"`/`"--+"` notation (readable, not offerable - the explicit
  `"…FF"` codes replaced it).

  Both the Pairings page and the phone read this, which is the point: the
  phone carried a hand-copied ten-item list whose comment claimed it
  mirrored the Pairings page, and it had been missing the three unrated
  codes since the day they shipped.
  """
  def entry_codes, do: @codes -- [@bye, "+--", "--+"]

  @doc """
  `{white_outcome, black_outcome, played?, forfeit?}` for a stored code.

  Returns `{:none, :none, false, false}` for the blank, for `"bye"`, and for
  anything unrecognised - all three mean "no game to classify", and every
  caller that cares about byes has already branched on `opponent_id` by the
  time it reaches this.
  """
  def classify(code)

  for {code, white, black, played?, forfeit?} <- @table do
    def classify(unquote(code)) do
      {unquote(white), unquote(black), unquote(played?), unquote(forfeit?)}
    end
  end

  def classify(_other), do: {:none, :none, false, false}

  @doc """
  `:win | :draw | :loss` from one seat, or `:none` when there is no game.

  `white?` is a boolean seat rather than a colour atom, matching the shape
  `PairingsEngine.Standings` already has in hand as it builds a record.
  """
  def outcome(code, white?) when is_boolean(white?) do
    {white, black, _played?, _forfeit?} = classify(code)
    if white?, do: white, else: black
  end

  @doc "Was this game contested over the board?"
  def played?(code) do
    {_w, _b, played?, _forfeit?} = classify(code)
    played?
  end

  @doc "Is this one of the never-played forfeit codes?"
  def forfeit?(code) do
    {_w, _b, _played?, forfeit?} = classify(code)
    forfeit?
  end

  ## ---------- Written forms ----------

  # Every spelling a human may type for a result, mapped to the code it
  # stores. It lives here rather than in `PairingsEngine.ResultsImport`
  # because the parser's accepted set and its documented set had drifted
  # apart in both directions at once: three tokens were accepted and
  # documented nowhere, while the three unrated codes - importable through
  # every other path in the app - were rejected outright, so a bulk CSV
  # could not express a result the same round could express by click.
  #
  # Keys are matched upper-cased and trimmed, so lower-case input works and
  # each letter token needs only one spelling.
  @aliases %{
    "1-0" => "1-0",
    "0-1" => "0-1",
    "1/2-1/2" => "1/2-1/2",
    "½-½" => "1/2-1/2",
    "0.5-0.5" => "1/2-1/2",
    "=" => "1/2-1/2",
    "1/2-0" => "1/2-0",
    "½-0" => "1/2-0",
    "0.5-0" => "1/2-0",
    "0-1/2" => "0-1/2",
    "0-½" => "0-1/2",
    "0-0.5" => "0-1/2",
    "0-0" => "0-0",
    "X" => "0-0",
    "1-0FF" => "1-0FF",
    "+/-" => "1-0FF",
    "0-1FF" => "0-1FF",
    "-/+" => "0-1FF",
    "0-0FF" => "0-0FF",
    "-/-" => "0-0FF",
    "1-0U" => "1-0U",
    "0-1U" => "0-1U",
    "1/2-1/2U" => "1/2-1/2U",
    "½-½U" => "1/2-1/2U",
    "0.5-0.5U" => "1/2-1/2U"
  }

  @doc """
  Parses one written result token into the code it stores.

  Case-insensitive and whitespace-trimmed. Returns `{:ok, code}` or
  `:error`.
  """
  def parse_token(token) when is_binary(token) do
    case Map.fetch(@aliases, token |> String.trim() |> String.upcase()) do
      {:ok, code} -> {:ok, code}
      :error -> :error
    end
  end

  @doc """
  Every accepted spelling, grouped by the code it stores, in table order -
  so a document listing the accepted tokens can be checked against the
  parser rather than drifting from it.
  """
  def token_groups do
    @aliases
    |> Enum.group_by(fn {_token, code} -> code end, fn {token, _code} -> token end)
    |> Enum.map(fn {code, tokens} -> {code, Enum.sort(tokens)} end)
    |> Enum.sort_by(fn {code, _tokens} -> Enum.find_index(@codes, &(&1 == code)) end)
  end
end
