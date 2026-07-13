defmodule PairingsEngine.Kbsb.Parser do
  @moduledoc """
  Parses a Belgian national (KBSB/FRBE) rating-list export into plain row
  maps ready for `Repo.insert_all/3`.

  There is no verified sample of the "official" file in this codebase (see
  docs/kbsb-sync.md for why) so, unlike the FIDE parser's fixed byte
  offsets, columns here are resolved **by header name** against a small set
  of recognised French/Dutch/English aliases. That makes the parser
  resilient to column reordering and to the exact delimiter/locale the
  federation ends up using — adjust `@field_headers` once a real export is
  available and doesn't match.

  Recognised delimiters: `;` (typical for French/Belgian locale CSV, since
  `,` is the decimal separator there) or `,`, auto-detected from the header
  line. Only `national_id` (matricule) and `last_name` are required columns;
  everything else is optional and defaults to nil/blank when absent.

  Field splitting is RFC-4180-style, done by hand (no new deps): a field
  wrapped in double quotes may contain the delimiter (and newlines aren't
  supported inside a quoted field — a value straddling a line break isn't
  something this parser reassembles), and a doubled `""` inside a quoted
  field unescapes to one literal `"`. See `split_row/2`.
  """

  alias PairingsEngine.SwarImport

  @field_headers %{
    national_id: ["MATRICULE", "STAMNUMMER", "ID"],
    last_name: ["NOM", "NAAM", "NAME", "LASTNAME"],
    first_name: ["PRENOM", "PRÉNOM", "VOORNAAM", "FIRSTNAME"],
    national_rating: ["ELO", "ELO NAT", "ELO NATIONAL", "NATIONAAL ELO", "NATIONAL ELO"],
    fide_id: ["FIDE", "ID FIDE", "FIDE ID", "IDFIDE"],
    club_number: ["N CLUB", "N° CLUB", "CLUBNR", "CLUB NR", "CLUBNUMMER", "CLUB NUMBER"],
    club_name: ["CLUB"],
    federation: ["FEDERATION", "FÉDÉRATION", "FEDERATIE", "FED"],
    birth_year: ["ANNEE", "ANNÉE", "GEBOORTEJAAR", "BIRTH", "BIRTHYEAR", "NE(E)", "NE"]
  }

  @numeric ~w(national_rating fide_id club_number birth_year)a

  @doc """
  Parses the raw file contents (as read from disk or an upload) into
  `{:ok, rows}` where each row is a map with the schema's field atoms as
  keys, or `{:error, reason}` if the file is empty or missing a required
  column.
  """
  def parse(binary) when is_binary(binary) do
    lines =
      binary
      |> strip_bom_bytes()
      |> decode()
      |> strip_bom()
      |> String.split(["\r\n", "\n"])
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        {:error, "The file is empty"}

      [header | rows] ->
        delimiter = detect_delimiter(header)
        headers = header |> split_row(delimiter) |> Enum.map(&normalize_header/1)

        with {:ok, offsets} <- column_offsets(headers) do
          parsed =
            rows
            |> Enum.map(&parse_row(&1, delimiter, offsets))
            |> Enum.reject(&(&1.national_id in [nil, ""] or &1.last_name in [nil, ""]))

          {:ok, parsed}
        end
    end
  end

  # Strips the raw 3-byte UTF-8 BOM (EF BB BF) from the binary *before*
  # encoding detection. Order matters: a file that's actually CP1252-encoded
  # but prefixed with a UTF-8 BOM has those three bytes decode (via
  # `decode/1`'s CP1252 fallback) into three *valid but wrong* characters
  # ("ï»¿") rather than the BOM codepoint — `strip_bom/1` never recognizes
  # them, so the header's first cell reads "ï»¿MATRICULE" and
  # `column_offsets/1` reports a false "missing national ID column". Doing
  # it here, on the raw bytes, sidesteps encoding entirely.
  defp strip_bom_bytes(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom_bytes(binary), do: binary

  # The file may arrive as UTF-8 (most likely for a modern export) or as
  # Windows-1252/Latin-1 (common for older Belgian federation tooling, same
  # as the .swar format — see PairingsEngine.SwarImport.cp1252_decode/1).
  defp decode(binary) do
    if String.valid?(binary), do: binary, else: SwarImport.cp1252_decode(binary)
  end

  # Belt-and-braces: covers a UTF-8-decoded BOM codepoint that arrives some
  # other way (e.g. already-decoded text handed in directly) even though
  # `strip_bom_bytes/1` above handles the common raw-file case.
  defp strip_bom("﻿" <> rest), do: rest
  defp strip_bom(text), do: text

  defp detect_delimiter(header) do
    semi = header |> String.split(";") |> length()
    comma = header |> String.split(",") |> length()
    if comma > semi, do: ",", else: ";"
  end

  defp normalize_header(h), do: h |> String.trim() |> String.trim("\"") |> String.upcase()

  defp column_offsets(headers) do
    found =
      for {field, aliases} <- @field_headers, into: %{} do
        {field, Enum.find_index(headers, &(&1 in aliases))}
      end

    cond do
      is_nil(found.national_id) ->
        {:error, "The file is missing a national ID / matricule column"}

      is_nil(found.last_name) ->
        {:error, "The file is missing a name column"}

      true ->
        {:ok, found}
    end
  end

  defp parse_row(line, delimiter, offsets) do
    cells = line |> split_row(delimiter) |> Enum.map(&clean_cell/1)

    for {field, idx} <- offsets, into: %{} do
      raw = get_cell(cells, idx)

      value =
        cond do
          field in @numeric -> parse_int(raw)
          field in [:first_name, :club_name, :federation] -> raw || ""
          true -> raw
        end

      {field, value}
    end
  end

  # RFC-4180-style field splitting, hand-rolled (no new deps): a field is
  # "quoted" only when the opening `"` is the very first character of that
  # field (matched below via the empty accumulator) — a delimiter inside a
  # quoted field is literal text, not a field boundary, and a doubled `""`
  # inside a quoted field unescapes to one literal `"`. Newlines inside a
  # quoted field are unsupported: `parse/1` already splits the file into
  # lines before this ever runs, so a field spanning a line break arrives
  # here pre-split into two unrelated rows.
  defp split_row(line, delimiter) do
    line
    |> String.graphemes()
    |> split_chars(delimiter, false, [], [])
  end

  defp split_chars([], _delimiter, _in_quotes, field, fields),
    do: Enum.reverse([finish_field(field) | fields])

  # Opening quote: only at the very start of a field (accumulator empty,
  # not already inside a quoted field).
  defp split_chars(["\"" | rest], delimiter, false, [], fields),
    do: split_chars(rest, delimiter, true, [], fields)

  # `""` inside a quoted field is an escaped literal quote.
  defp split_chars(["\"", "\"" | rest], delimiter, true, field, fields),
    do: split_chars(rest, delimiter, true, ["\"" | field], fields)

  # Closing quote.
  defp split_chars(["\"" | rest], delimiter, true, field, fields),
    do: split_chars(rest, delimiter, false, field, fields)

  # Delimiter outside quotes ends the current field.
  defp split_chars([c | rest], delimiter, false, field, fields) when c == delimiter,
    do: split_chars(rest, delimiter, false, [], [finish_field(field) | fields])

  defp split_chars([c | rest], delimiter, in_quotes, field, fields),
    do: split_chars(rest, delimiter, in_quotes, [c | field], fields)

  defp finish_field(field), do: field |> Enum.reverse() |> IO.iodata_to_binary()

  defp clean_cell(c), do: String.trim(c)

  defp get_cell(_cells, nil), do: nil
  defp get_cell(cells, idx), do: Enum.at(cells, idx)

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
end
