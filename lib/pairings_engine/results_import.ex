defmodule PairingsEngine.ResultsImport do
  @moduledoc """
  Bulk CSV import of a round's results — "board number + result" lines
  entered by the arbiter, applied to exactly the boards named and leaving
  everyone else alone. See `docs/results-import.md`.

  `parse_text/1` is a pure parser (raw file bytes in, `{board, result}`
  pairs out); `apply_import/3` matches each parsed board against a round's
  actual pairings and writes results through
  `PairingsEngine.Tournaments.update_pairing_result/2` — the exact same
  write path the Pairings page's inline result `<select>` uses, so live
  broadcasts and status refresh happen identically whether a result came
  from a click or a CSV line.
  """

  alias PairingsEngine.Repo
  alias PairingsEngine.SwarImport
  alias PairingsEngine.Tournaments

  ## ---------- Parsing ----------

  @doc """
  Parses CSV text (raw file bytes — UTF-8 or Windows-1252, with or without a
  UTF-8 BOM) into a list of `{board, result}` pairs.

  Accepts either `;` or `,` as the field separator (auto-detected per file:
  a line containing `;` uses `;`, everything else uses `,`), tolerates one
  optional header row (skipped when its first field doesn't parse as an
  integer board number), and blank lines are ignored.

  Recognized result tokens (case-insensitive, whitespace-trimmed):

    * `1-0` — white wins
    * `0-1` — black wins
    * `1/2-1/2`, `½-½`, `0.5-0.5`, `=` — draw
    * `0-0`, `X` — both lose, game actually played
    * `1-0FF`, `+/-` — white wins by forfeit
    * `0-1FF`, `-/+` — black wins by forfeit
    * `0-0FF`, `-/-` — double forfeit (neither played)

  Returns `{:ok, [{board, result}]}` when every line parses cleanly, or
  `{:error, [reason, ...]}` — one entry per malformed line or duplicate
  board — otherwise. Never raises.
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
    if String.valid?(bin), do: bin, else: SwarImport.cp1252_decode(bin)
  end

  defp detect_separator(lines) do
    if Enum.any?(lines, &String.contains?(&1, ";")), do: ";", else: ","
  end

  # A header row's first field won't parse as a plain integer ("Board",
  # "Bord nr", ...) — a data row's always will. Only ever called with a
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

  defp normalize_result(token) do
    case token |> String.trim() |> String.upcase() do
      "1-0" -> {:ok, "1-0"}
      "0-1" -> {:ok, "0-1"}
      t when t in ["1/2-1/2", "½-½", "0.5-0.5", "="] -> {:ok, "1/2-1/2"}
      t when t in ["1/2-0", "½-0", "0.5-0"] -> {:ok, "1/2-0"}
      t when t in ["0-1/2", "0-½", "0-0.5"] -> {:ok, "0-1/2"}
      t when t in ["0-0", "X"] -> {:ok, "0-0"}
      t when t in ["1-0FF", "+/-"] -> {:ok, "1-0FF"}
      t when t in ["0-1FF", "-/+"] -> {:ok, "0-1FF"}
      t when t in ["0-0FF", "-/-"] -> {:ok, "0-0FF"}
      _ -> {:error, :unrecognized}
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
  `rows` keep their current result — this is a partial-entry-friendly
  update, not a wholesale replace.

  Returns `{:ok, count}` (number of results written) or
  `{:error, [reason, ...]}`.
  """
  def apply_import(tournament, round_number, rows) when is_list(rows) do
    case Tournaments.get_round(tournament.id, round_number) do
      nil ->
        {:error, ["Round #{round_number} has not been paired yet"]}

      round ->
        boards = Map.new(round.pairings, &{&1.board, &1})

        {resolved, errors} =
          Enum.reduce(rows, {[], []}, fn {board, result}, {resolved, errors} ->
            case Map.get(boards, board) do
              nil ->
                {resolved, ["board #{board}: no such board in round #{round_number}" | errors]}

              %{result: "bye"} ->
                {resolved, ["board #{board}: is a bye — no result to enter" | errors]}

              pairing ->
                {[{pairing, result} | resolved], errors}
            end
          end)

        if errors == [] do
          write_all(tournament.id, Enum.reverse(resolved))
        else
          {:error, Enum.reverse(errors)}
        end
    end
  end

  # Mirrors PairingsEngine.SwarImport's bulk-write shape: individual writes
  # inside the transaction don't broadcast (a subscriber could otherwise
  # query the database before the writes are actually committed) —
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
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)
        end)
      end)

    case txn_result do
      {:ok, :ok} ->
        Tournaments.broadcast_tournament_change(tournament_id, :results)
        Tournaments.refresh_status!(tournament_id)
        {:ok, length(pairs)}

      {:error, changeset} ->
        {:error, ["Could not save results: #{changeset_error_text(changeset)}"]}
    end
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
