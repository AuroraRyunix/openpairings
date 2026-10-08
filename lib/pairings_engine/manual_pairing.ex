defmodule PairingsEngine.ManualPairing do
  @moduledoc """
  Manual pairing alteration (MPA) - the arbiter changing a round's boards by
  hand (C.04.2:4.4), with the safeguards VCL4THP Q65-Q69 and the TEC
  Manual's MPA PIBE ask for.

  ## A session, with a start and an end (Q65)

  A round's hand edits happen inside a session stored on the round
  (`Round.mpa_session`). It starts explicitly ("Edit pairings by hand" on
  the Pairings page) or implicitly with the first hand edit applied to the
  round, and it ends only explicitly, with "Finish hand edits" - the point
  at which the round is checked. The next round cannot be paired while a
  session is open, so the check cannot be skipped by moving on.

  ## During the session (Q66, Q67)

  `warnings/4` judges the boards a staged edit would create, before it is
  applied: a game the two players already played over the board, a pair the
  arbiter prohibited, a pairing-allocated bye to a player C.2 rules out of
  it, three same colours in a row or a colour difference above two before
  the last round, and both players getting the colour opposite to the one
  each is due. The Pairings page shows them in the edit's own confirmation,
  which then needs an explicit tick (Level 3).

  ## At the end (Q68, Q69)

  `assess/2` runs the pairing checker - the pairing engine, over the field
  as the round now seats it (`PairingsEngine.Pairing.engine_field/2`) - and
  compares its pairing with the round's boards, colours included, board
  order not. If they differ the page shows the checker's pairing and asks
  for an explicit confirmation; confirmed, the round keeps its boards and
  records an MPA PIBE (`Round.mpa_pibe`) that the TRF writes as a `###` line
  (`PairingsEngine.TrfExport`). Re-entering a round's session and finishing
  it again replaces its PIBE, or removes it when the boards now match - at
  most one per round, and unpairing the round removes it with the round.

  An individual, single-pool Swiss is checked by the Dutch system's engine.
  A round robin paired by hand (VCL4THP Q100, `RoundRobin.by_hand?/1`) is
  held to its own round of the Berger table instead, and to the round-robin
  rules (`PairingsEngine.ManualRoundRobin`: meeting once per cycle, Q101;
  three colours running, Q102) - the table being the only pairing a round
  robin has. Any other round that ends a session with boards different from
  where it started records the PIBE without a check.

  Hand edits do not take a tournament out of FIDE mode: the regulations
  foresee them, and the PIBE is how the TRF says where the pairings stop
  being the system's own.
  """

  import Ecto.Query, only: [from: 2]

  alias PairingsEngine.{ManualRoundRobin, Pairing, Repo, RoundRobin, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  @c2_reasons [:pairing_bye, :forfeit_win, :full_point_bye]

  ## ---------- the boards ----------

  @doc """
  The boards of `round` (pairings preloaded) as `[white, black, bye?]` by
  player id, sorted - the shape a session stores and compares. A fully
  empty board is left out; a vacancy has a nil seat and `bye? == false`.
  """
  def boards(%Round{pairings: pairings}) when is_list(pairings) do
    pairings
    |> Enum.reject(&(is_nil(&1.white_player_id) and is_nil(&1.black_player_id)))
    |> Enum.map(&[&1.white_player_id, &1.black_player_id, &1.result == "bye"])
    |> Enum.sort()
  end

  @doc "Whether a session is open on `round`."
  def open?(%Round{mpa_session: session}), do: is_map(session)
  def open?(_round), do: false

  @doc "The lowest round number of `tournament_id` with a session open, or nil."
  def open_round(tournament_id) do
    Repo.one(
      from r in Round,
        where: r.tournament_id == ^tournament_id and not is_nil(r.mpa_session),
        order_by: r.number,
        limit: 1,
        select: r.number
    )
  end

  @doc """
  Opens a session on `round`, remembering `before` (its boards in the shape
  of `boards/1`; the round's own by default) as where it started. Does
  nothing when one is already open. `{:ok, true}` when this opened it,
  `{:ok, false}` when one was already open.
  """
  def start(%Round{} = round, before \\ nil) do
    with :ok <- Tournaments.ensure_writable(round.tournament_id) do
      session = %{"before" => before || boards(round)}

      {count, _} =
        Repo.update_all(
          from(r in Round, where: r.id == ^round.id and is_nil(r.mpa_session)),
          set: [mpa_session: session]
        )

      if count == 1, do: Tournaments.broadcast_tournament_change(round.tournament_id, :rounds)
      {:ok, count == 1}
    end
  end

  @doc """
  Closes the session on `round`. `pibe` is `{:set, line}` to record the
  round's MPA PIBE, `:clear` to remove it, `:keep` to leave it as it is.
  """
  def finish(%Round{} = round, pibe) do
    with :ok <- Tournaments.ensure_writable(round.tournament_id) do
      set =
        case pibe do
          {:set, line} when is_binary(line) -> [mpa_pibe: line]
          :clear -> [mpa_pibe: nil]
          :keep -> []
        end

      # SQL NULL, not a JSON `null`: a nil handed to a map column is
      # stored as the text "null", which `open_round/1` would still see.
      # A round robin's player left off the boards sits the round out with
      # the table's zero-point bye, whoever decided it.
      RoundRobin.record_sitting_out(round)

      Repo.update_all(
        from(r in Round,
          where: r.id == ^round.id,
          update: [set: [mpa_session: fragment("NULL")]]
        ),
        set: set
      )

      Tournaments.broadcast_tournament_change(round.tournament_id, :rounds)
      :ok
    end
  end

  ## ---------- the checker's field ----------

  @doc """
  Whether a round of `tournament` can be held to a pairing checker: an
  individual Dutch Swiss paired as one pool, both legs not mirrored (the
  engine), or a round robin paired by hand (its Berger table).
  """
  def checkable?(%Tournament{} = t), do: swiss_checkable?(t) or RoundRobin.by_hand?(t)

  defp swiss_checkable?(t) do
    t.pairing_system == "swiss" and not t.pair_by_category and not t.swiss_match_format and
      not Tournament.paired_as_teams?(t)
  end

  @doc """
  The field round `round_number` is judged in (`Pairing.engine_field/2`),
  or `:error` for a tournament that cannot be checked or a field that could
  not be rebuilt.
  """
  def field(%Tournament{} = t, round_number) do
    if swiss_checkable?(t) do
      case Pairing.engine_field(t, round_number) do
        {:ok, field} -> {:ok, field}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  ## ---------- during the session: the absolute criteria (Q66, Q67) ----------

  @doc """
  What breaks the rules among `new_boards` - `{white_id, black_id}` per
  board, `{player_id, :pab}` for a pairing-allocated bye - in round
  `round_number` of `field`. A list of maps, each with a `:kind`
  (`:rematch`, `:forbidden`, `:bye`, `:colour_three`, `:colour_imbalance`
  or `:wrong_colours`) and the `:players` (ids) it is about; `:round` for a
  rematch (the round they met), `:reason` for a bye, `:colour` ("w"/"b") for
  a colour.
  """
  def warnings(field, %Tournament{} = t, round_number, new_boards) do
    rank = field.local_rank_by_player_id
    by_rank = Map.new(field.players, &{&1.rank, &1})
    before_last? = round_number < t.rounds_count

    Enum.flat_map(new_boards, fn
      {w, :pab} ->
        bye_warnings(field, w, Map.get(rank, w))

      {w, b} when is_integer(w) and is_integer(b) ->
        with rw when is_integer(rw) <- Map.get(rank, w),
             rb when is_integer(rb) <- Map.get(rank, b),
             %{} = pw <- Map.get(by_rank, rw),
             %{} = pb <- Map.get(by_rank, rb) do
          pair_warnings(field, {w, pw}, {b, pb}, round_number, before_last?)
        else
          _ -> []
        end

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp bye_warnings(_field, _id, nil), do: []

  defp bye_warnings(field, id, rank) do
    reason =
      field.players
      |> Ainalrami.Pairing.bye_eligibility(field.opts)
      |> Map.get(rank)

    if reason in @c2_reasons, do: [%{kind: :bye, players: [id], reason: reason}], else: []
  end

  defp pair_warnings(field, {w, pw}, {b, pb}, round_number, before_last?) do
    rematch =
      pw.games
      |> Enum.with_index(1)
      |> Enum.find_value(fn {game, i} ->
        if game.opponent_rank == pb.rank and played?(game), do: i
      end)

    forbidden? =
      Enum.any?(field.opts[:forbidden_pairs] || [], fn group ->
        case applicable(group, round_number) do
          nil -> false
          ranks -> pw.rank in ranks and pb.rank in ranks
        end
      end)

    colours =
      if before_last?,
        do: colour_warnings(pw, "w", w) ++ colour_warnings(pb, "b", b),
        else: []

    wrong? = preference(pw) == "b" and preference(pb) == "w"

    Enum.concat([
      if(rematch, do: [%{kind: :rematch, players: [w, b], round: rematch}], else: []),
      if(forbidden?, do: [%{kind: :forbidden, players: [w, b]}], else: []),
      colours,
      if(wrong?, do: [%{kind: :wrong_colours, players: [w, b]}], else: [])
    ])
  end

  defp applicable({ranks, first, last}, round) when round >= first and round <= last, do: ranks
  defp applicable({_ranks, _first, _last}, _round), do: nil
  defp applicable(ranks, _round) when is_list(ranks), do: ranks
  defp applicable(_other, _round), do: nil

  # A postponed game ("?") counts as a draw for pairing, so as played.
  defp played?(%{result: "?"}), do: true
  defp played?(game), do: Ainalrami.Trf.game_was_played?(game.result)

  defp played_colours(player) do
    player.games
    |> Enum.filter(&played?/1)
    |> Enum.map(& &1.colour)
    |> Enum.filter(&(&1 in ["w", "b"]))
  end

  defp colour_warnings(player, colour, id) do
    colours = played_colours(player) ++ [colour]
    difference = abs(Enum.count(colours, &(&1 == "w")) - Enum.count(colours, &(&1 == "b")))

    three? =
      case Enum.take(colours, -3) do
        [c, c, c] -> true
        _ -> false
      end

    Enum.concat([
      if(three?, do: [%{kind: :colour_three, players: [id], colour: colour}], else: []),
      if(difference > 2,
        do: [%{kind: :colour_imbalance, players: [id], colour: colour}],
        else: []
      )
    ])
  end

  # The colour a player is due - the ladder of `Ainalrami.Pairing`'s colour
  # state (C.04.3 A.6): a difference of two or more, then the same colour
  # twice running, then a difference of one, then alternation. nil for a
  # player with no played game.
  defp preference(player) do
    colours = played_colours(player)
    whites = Enum.count(colours, &(&1 == "w"))
    blacks = Enum.count(colours, &(&1 == "b"))
    last = List.last(colours)
    run = colours |> Enum.reverse() |> Enum.take_while(&(&1 == last)) |> length()
    lower = if whites > blacks, do: "b", else: "w"

    cond do
      colours == [] -> nil
      abs(whites - blacks) > 1 -> lower
      run > 1 -> invert(last)
      whites != blacks -> lower
      true -> invert(last)
    end
  end

  defp invert("w"), do: "b"
  defp invert("b"), do: "w"

  ## ---------- at the end: the pairing checker (Q68, Q69) ----------

  @doc """
  What finishing the session on `round` (pairings preloaded) means:

    * `{:error, {:vacant, board}}` / `{:error, :no_boards}` - not a round
      that can be finished yet;
    * `:unchanged` - the boards are where the session started and there is
      no PIBE to reconsider;
    * `{:matches, info}` - the pairing checker pairs the round exactly so;
    * `{:differs, info}` - it does not (or finds no legal pairing at all);
      `info.correct` is its pairing (`:none` when there is none),
      `info.missing`/`info.added` the boards only one side has,
      `info.warnings` the absolute-criteria breaches (`warnings/4`) and
      `info.line` the PIBE line to record;
    * `{:unchecked, info}` - the round cannot be checked (`checkable?/1`)
      and its boards changed; `info.line` records the change itself.
  """
  def assess(%Tournament{} = t, %Round{} = round) do
    current = boards(round)
    before = (round.mpa_session || %{})["before"] || current

    cond do
      vacant = Enum.find(round.pairings, &vacant?/1) ->
        {:error, {:vacant, vacant.board}}

      current == [] ->
        {:error, :no_boards}

      current == before and (is_nil(round.mpa_pibe) or not checkable?(t)) ->
        :unchanged

      true ->
        judge(t, round, before, current)
    end
  end

  defp vacant?(%{result: "bye"}), do: false

  defp vacant?(p),
    do: is_nil(p.white_player_id) != is_nil(p.black_player_id)

  defp judge(t, round, before, current) do
    if RoundRobin.by_hand?(t),
      do: judge_round_robin(t, round, before, current),
      else: judge_swiss(t, round, before, current)
  end

  # The checker of a round robin is its Berger table (VCL4THP Q100); the
  # player of the table left off the boards sits the round out, as the
  # table's own bye does.
  defp judge_round_robin(t, round, before, current) do
    seated = current |> Enum.flat_map(fn [w, b, _] -> [w, b] end) |> MapSet.new()

    edited =
      Enum.map(current, &pair/1) ++
        for p <- Pairing.full_roster_players(t.id),
            not MapSet.member?(seated, p.id),
            do: {p.id, nil}

    tpn = tpns(t.id)
    warnings = ManualRoundRobin.warnings(t, round.number, edited, complete: true)

    case RoundRobin.table_round(t, round.number) do
      {:ok, table} ->
        missing = table -- edited
        added = edited -- table

        if missing == [] and added == [] do
          {:matches, %{warnings: warnings}}
        else
          {:differs,
           %{
             correct: table,
             missing: missing,
             added: added,
             warnings: warnings,
             line: line(round.number, format(missing, tpn, "BYE"), format(added, tpn, "BYE"))
           }}
        end

      :error ->
        unchecked(round, before, Enum.map(current, &pair/1), tpn)
    end
  end

  defp judge_swiss(t, round, before, current) do
    edited = Enum.map(current, &pair/1)
    tpn = tpns(t.id)

    case field(t, round.number) do
      {:ok, field} ->
        warnings = warnings(field, t, round.number, Enum.map(edited, &warn_shape/1))

        case checker_pairs(field) do
          {:ok, correct} ->
            missing = correct -- edited
            added = edited -- correct

            if missing == [] and added == [] do
              {:matches, %{warnings: warnings}}
            else
              {:differs,
               %{
                 correct: correct,
                 missing: missing,
                 added: added,
                 warnings: warnings,
                 line: line(round.number, format(missing, tpn), format(added, tpn))
               }}
            end

          :no_legal_pairing ->
            {:differs,
             %{
               correct: :none,
               missing: [],
               added: edited,
               warnings: warnings,
               line: line(round.number, "no legal pairing", format(edited, tpn))
             }}

          :error ->
            unchecked(round, before, edited, tpn)
        end

      :error ->
        unchecked(round, before, edited, tpn)
    end
  end

  defp unchecked(round, before, edited, tpn) do
    before = Enum.map(before, &pair/1)
    missing = before -- edited
    added = edited -- before

    # Nothing moved since the session began: whatever the round's record
    # said, it still says.
    text =
      if missing == [] and added == [] and round.mpa_pibe,
        do: round.mpa_pibe,
        else: line(round.number, format(missing, tpn), format(added, tpn))

    {:unchecked, %{missing: missing, added: added, warnings: [], line: text}}
  end

  # `{white, black}`, black nil for the pairing-allocated bye.
  defp pair([w, b, _bye?]), do: {w, b}

  defp warn_shape({w, nil}), do: {w, :pab}
  defp warn_shape(pair), do: pair

  # The pairing checker's own pairing of the field, as player ids.
  defp checker_pairs(field) do
    field.players
    |> Ainalrami.Pairing.pair_next_round(field.opts)
    |> Enum.map(fn {w, b} ->
      id = &Map.fetch!(field.player_by_local_rank, &1).id
      {id.(w), if(b in [nil, 0], do: nil, else: id.(b))}
    end)
    |> then(&{:ok, &1})
  rescue
    Ainalrami.Pairing.NoValidPairingError -> :no_legal_pairing
    _ -> :error
  end

  defp tpns(tournament_id) do
    Repo.all(
      from p in Player, where: p.tournament_id == ^tournament_id, select: {p.id, p.pairing_number}
    )
    |> Map.new()
  end

  @doc """
  The PIBE line, without its `###`: `MPA @ Round r: <before> => <after>` -
  the TEC Manual's own example shape.
  """
  def line(round_number, before, after_text),
    do: "MPA @ Round #{round_number}: #{before} => #{after_text}"

  @doc """
  Boards as the TEC Manual writes them: `12-7` (White's starting rank
  first), `44=PAB` for a pairing-allocated bye; `none` for no board. A
  round robin's player sitting the round out is `44=BYE` (`bye`).
  """
  def format(pairs, tpn, bye \\ "PAB")
  def format([], _tpn, _bye), do: "none"

  def format(pairs, tpn, bye) do
    Enum.map_join(pairs, " ", fn
      {w, nil} -> "#{number(tpn, w)}=#{bye}"
      {w, b} -> "#{number(tpn, w)}-#{number(tpn, b)}"
    end)
  end

  defp number(tpn, id), do: Map.get(tpn, id) || "?"
end
