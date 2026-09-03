defmodule PairingsEngine.ResultsImport do
  @moduledoc """
  Bulk CSV import of a round's results - "board number + result" lines
  entered by the arbiter, applied to exactly the boards named and leaving
  everyone else alone. See `docs/results-import.md`.

  `parse_text/1` is a pure parser (raw file bytes in, `{board, result}`
  pairs out); `apply_import/3` matches each parsed board against a round's
  actual pairings and writes results through
  `PairingsEngine.Tournaments.update_pairing_result/2` - the exact same
  write path the Pairings page's inline result `<select>` uses, so live
  broadcasts and status refresh happen identically whether a result came
  from a click or a CSV line.
  """

  alias PairingsEngine.Encoding
  alias PairingsEngine.PairingDisplay
  alias PairingsEngine.Repo
  alias PairingsEngine.Results
  alias PairingsEngine.Tournaments

  ## ---------- Parsing ----------

  @doc """
  Parses CSV text (raw file bytes - UTF-8 or Windows-1252, with or without a
  UTF-8 BOM) into a list of `{board, result}` pairs.

  Accepts either `;` or `,` as the field separator (auto-detected per file:
  a line containing `;` uses `;`, everything else uses `,`), tolerates one
  optional header row (skipped when its first field doesn't parse as an
  integer board number), and blank lines are ignored.

  Recognized result tokens (case-insensitive, whitespace-trimmed):

    * `1-0` - white wins
    * `0-1` - black wins
    * `1/2-1/2`, `½-½`, `0.5-0.5`, `=` - draw
    * `1/2-0`, `½-0`, `0.5-0` - asymmetric ½-0 (VCL.13 disciplinary)
    * `0-1/2`, `0-½`, `0-0.5` - asymmetric 0-½
    * `0-0`, `X` - both lose, game actually played
    * `1-0FF`, `+/-` - white wins by forfeit
    * `0-1FF`, `-/+` - black wins by forfeit
    * `0-0FF`, `-/-` - double forfeit (neither played)
    * `1-0U`, `0-1U`, `1/2-1/2U` (also `½-½U`, `0.5-0.5U`) - played but not
      rated

  That list is `PairingsEngine.Results.token_groups/0` written out, and it
  had drifted from the parser in both directions: the two asymmetric rows
  were accepted and documented nowhere, while the three unrated codes -
  writable from the Pairings page, the phone, TRF and SWAR alike - were
  rejected here, so a bulk CSV was the one path that could not express a
  result the same round could express by click.

  Returns `{:ok, [{board, result}]}` when every line parses cleanly, or
  `{:error, [reason, ...]}` - one entry per malformed line or duplicate
  board - otherwise. Never raises.
  """
  def parse_text(raw) when is_binary(raw) do
    lines =
      raw
      |> strip_bom()
      |> decode_text()
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        {:error, ["The file is empty"]}

      lines ->
        separator = detect_separator(lines)

        lines
        |> maybe_drop_header(separator)
        |> Enum.with_index(1)
        |> Enum.map(fn {line, line_no} -> parse_line(line, separator, line_no) end)
        |> finalize()
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp decode_text(bin) do
    if String.valid?(bin), do: bin, else: Encoding.cp1252_decode(bin)
  end

  defp detect_separator(lines) do
    if Enum.any?(lines, &String.contains?(&1, ";")), do: ";", else: ","
  end

  # A header row's first field won't parse as a plain integer ("Board",
  # "Bord nr", ...) - a data row's always will. Only ever called with a
  # non-empty list (the caller already handled `[]` itself).
  defp maybe_drop_header([first | rest] = lines, separator) do
    case String.split(first, separator, parts: 2) do
      [board_str, _] ->
        case Integer.parse(String.trim(board_str)) do
          {_n, ""} -> lines
          _ -> rest
        end

      _ ->
        rest
    end
  end

  defp parse_line(line, separator, line_no) do
    case String.split(line, separator, parts: 2) do
      [board_str, result_str] ->
        with {board, ""} <- Integer.parse(String.trim(board_str)),
             {:ok, result} <- normalize_result(result_str) do
          {:ok, line_no, board, result}
        else
          {:error, :unrecognized} ->
            {:error, "line #{line_no}: unrecognized result #{inspect(String.trim(result_str))}"}

          _ ->
            {:error, "line #{line_no}: invalid board number #{inspect(String.trim(board_str))}"}
        end

      _ ->
        {:error, "line #{line_no}: expected \"board,result\" (got #{inspect(line)})"}
    end
  end

  # Every spelling a human may type lives with the codes themselves, in
  # PairingsEngine.Results - see this module's `parse_text/1` doc for what
  # went wrong while it lived here.
  defp normalize_result(token) do
    case Results.parse_token(token) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :unrecognized}
    end
  end

  defp finalize(parsed) do
    {oks, errors} =
      Enum.reduce(parsed, {[], []}, fn
        {:ok, line_no, board, result}, {oks, errors} -> {[{line_no, board, result} | oks], errors}
        {:error, reason}, {oks, errors} -> {oks, [reason | errors]}
      end)

    oks = Enum.reverse(oks)
    errors = Enum.reverse(errors) ++ duplicate_board_errors(oks)

    if errors == [] do
      {:ok, Enum.map(oks, fn {_line_no, board, result} -> {board, result} end)}
    else
      {:error, errors}
    end
  end

  defp duplicate_board_errors(oks) do
    oks
    |> Enum.group_by(fn {_line_no, board, _result} -> board end)
    |> Enum.filter(fn {_board, entries} -> length(entries) > 1 end)
    |> Enum.sort_by(fn {board, _entries} -> board end)
    |> Enum.map(fn {board, entries} ->
      lines = entries |> Enum.map(fn {line_no, _b, _r} -> line_no end) |> Enum.join(", ")
      "board #{board}: listed more than once (lines #{lines})"
    end)
  end

  ## ---------- Applying ----------

  @doc """
  Applies parsed `{board, result}` rows (as returned by `parse_text/1`) to
  `tournament`'s round `round_number`. All-or-nothing: every row is
  validated against that round's actual pairings first (unknown board, a
  bye board, or a board named twice are all collected as errors) and
  *nothing* is written unless every row is valid. Boards not mentioned in
  `rows` keep their current result - this is a partial-entry-friendly
  update, not a wholesale replace.

  Returns `{:ok, count}` (number of results written) or
  `{:error, [reason, ...]}`.
  """
  def apply_import(tournament, round_number, rows) when is_list(rows) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil ->
        {:error, ["Round #{round_number} has not been paired yet"]}

      round ->
        # Keyed on the DISPLAYED label, not on `pairing.board`. The arbiter
        # is transcribing a pairing sheet, and every document they can read -
        # the printed sheet, the Pairings page, the public page, the
        # projector - prints the frozen `display_board` label. Those two
        # numbers are identical for every tournament with no fixed-table
        # player in it, and diverge the moment there is one: a pin on real
        # board 3 of 5 makes the sheet read 1, 2, 3, 4 for real boards 1, 2,
        # 4, 5.
        #
        # This used to key on `pairing.board`, so transcribing that sheet
        # wrote four results onto three wrong games and returned {:ok, 4}.
        # The standings were then wrong and nothing said so. It was not
        # specific to a low `fixed_board`: the same damage was measured with
        # SWAR's own 1001.
        #
        # `PairingDisplay.board_labels/1` is used rather than reading
        # `display_board` here, so there is one definition of "the label"
        # and this cannot drift from what the sheet prints.
        by_label =
          round.pairings
          |> PairingDisplay.board_labels()
          |> Enum.group_by(& &1.board, & &1.pairing)

        {resolved, errors} =
          Enum.reduce(rows, {[], []}, fn {board, result}, {resolved, errors} ->
            case resolve_board(by_label, board, round_number) do
              {:ok, %{result: "bye"}} ->
                {resolved, ["board #{board}: is a bye - no result to enter" | errors]}

              {:ok, pairing} ->
                {[{pairing, result} | resolved], errors}

              {:error, message} ->
                {resolved, [message | errors]}
            end
          end)

        if errors == [] do
          write_all(tournament.id, Enum.reverse(resolved))
        else
          {:error, Enum.reverse(errors)}
        end
    end
  end

  # A label names exactly one game, except where the arbiter has pinned a
  # fixed table to a number an ordinary board already uses - which the app
  # allows on purpose, and which prints as two rows carrying the same label.
  #
  # There, "1" is taken to mean the ORDINARY board 1. That is what an
  # arbiter reading a sheet means by it: the fixed-table row is sorted last
  # and carries a "(table 1)" note, so it is the annotated one, not the
  # plain one. A non-special label is unique by construction
  # (`compute_labels/1` numbers them 1..N), so this always resolves to a
  # single game.
  #
  # The fixed table is then not addressable from a CSV in that configuration
  # and has to be entered from the Pairings page. Out of SWAR's own 1001
  # range there is no clash, the label is unique, and it imports like any
  # other - which it could not do at all before this function existed, since
  # 1001 is never a real board number.
  defp resolve_board(by_label, board, round_number) do
    case Map.get(by_label, to_string(board), []) do
      [] ->
        {:error, "board #{board}: no such board in round #{round_number}"}

      [only] ->
        {:ok, only}

      several ->
        case Enum.reject(several, & &1.display_special) do
          [ordinary] ->
            {:ok, ordinary}

          [] ->
            {:error,
             "board #{board}: names #{length(several)} fixed tables in round " <>
               "#{round_number}, so it is ambiguous - enter these from the Pairings page"}
        end
    end
  end

  # Mirrors PairingsEngine.SwarImport's bulk-write shape: individual writes
  # inside the transaction don't broadcast (a subscriber could otherwise
  # query the database before the writes are actually committed) -
  # broadcast once, for real, after commit, then let `refresh_status!/1`
  # recompute round/tournament status the same way any other result write
  # does.
  defp write_all(_tournament_id, []), do: {:ok, 0}

  defp write_all(tournament_id, pairs) do
    txn_result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          Enum.each(pairs, fn {pairing, result} ->
            case Tournaments.update_pairing_result(pairing, result) do
              {:ok, _} -> :ok
              # A changeset, or a bare reason atom from the write gate - both
              # roll the whole import back, and both are worded below.
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)
      end)

    case txn_result do
      {:ok, :ok} ->
        Tournaments.broadcast_tournament_change(tournament_id, :results)
        Tournaments.refresh_status!(tournament_id)
        {:ok, length(pairs)}

      # Both of `ensure_writable/1`'s reasons, in the app's own words. While
      # only `:archived` had a clause, a handed-off tournament fell through
      # to the changeset branch below, where `changeset.errors` on the atom
      # parses as a remote call to `:handed_off.errors/0` - so importing a
      # round's results into a checked-out tournament raised
      # `UndefinedFunctionError` instead of refusing.
      {:error, reason} when reason in [:archived, :handed_off] ->
        {:error, [Tournaments.refusal_message(reason, "importing results")]}

      {:error, changeset} ->
        {:error, ["Could not save results: #{changeset_error_text(changeset)}"]}
    end
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
