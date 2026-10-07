defmodule PairingsEngine.RatingLists.Csv do
  @moduledoc """
  Reads a custom rating list from CSV text.

  The first row must name the columns. Required: `id`, `name`, `rating`.
  Optional: `federation`, `title`, `birth_year`, `fide_id`. Names are matched
  without regard to case, and a few common aliases (`elo`, `fed`, `born`...)
  are understood. The separator (`,`, `;` or tab) is detected from the header
  row; UTF-8 and Windows-1252 are both read; double quotes protect a separator
  inside a field.

  Nothing is imported unless every row is valid: `parse/1` returns either the
  rows or the list of problems, each naming its line.
  """

  alias PairingsEngine.Encoding

  @max_rows 100_000
  @max_errors 20
  @titles ~w(GM IM FM CM WGM WIM WFM WCM)

  @aliases %{
    "id" => :id,
    "nr" => :id,
    "number" => :id,
    "name" => :name,
    "naam" => :name,
    "nom" => :name,
    "rating" => :rating,
    "elo" => :rating,
    "cote" => :rating,
    "federation" => :federation,
    "fed" => :federation,
    "title" => :title,
    "titel" => :title,
    "birth_year" => :birth_year,
    "birthyear" => :birth_year,
    "birth" => :birth_year,
    "born" => :birth_year,
    "year" => :birth_year,
    "fide_id" => :fide_id,
    "fideid" => :fide_id,
    "fide" => :fide_id
  }

  @type row :: %{
          ext_id: String.t(),
          name: String.t(),
          rating: pos_integer() | nil,
          federation: String.t(),
          title: String.t(),
          birth_year: integer() | nil,
          fide_id: integer() | nil
        }

  @doc "The row limit of one list."
  def max_rows, do: @max_rows

  @doc """
  `{:ok, rows}` or `{:error, [message]}` (at most #{@max_errors} messages; the
  last one says how many more there were).
  """
  @spec parse(binary()) :: {:ok, [row()]} | {:error, [String.t()]}
  def parse(raw) when is_binary(raw) do
    text = raw |> strip_bom() |> decode()

    case numbered_lines(text) do
      [] ->
        {:error, ["The file is empty."]}

      [{header, _} | data] ->
        sep = separator(header)
        header_cells = header |> split_line(sep) |> Enum.map(&normalize_header/1)

        with {:ok, columns} <- columns(header_cells),
             :ok <- check_size(data) do
          build(data, sep, columns)
        end
    end
  end

  defp check_size(data) do
    if length(data) > @max_rows,
      do: {:error, ["The file has #{length(data)} rows; one list takes at most #{@max_rows}."]},
      else: :ok
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp decode(bin), do: if(String.valid?(bin), do: bin, else: Encoding.cp1252_decode(bin))

  # Lines with their 1-based numbers; blank lines are dropped but keep their
  # numbers, so a message points at the line the user sees.
  defp numbered_lines(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
  end

  defp separator(header) do
    {sep, n} =
      [{";", count(header, ";")}, {"\t", count(header, "\t")}, {",", count(header, ",")}]
      |> Enum.max_by(&elem(&1, 1))

    if n == 0, do: ",", else: sep
  end

  defp count(line, char), do: length(String.split(line, char)) - 1

  defp normalize_header(cell) do
    cell
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp columns(header_cells) do
    mapped =
      header_cells
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {cell, i}, acc ->
        case Map.get(@aliases, cell) do
          nil -> acc
          field -> Map.put_new(acc, field, i)
        end
      end)

    case Enum.reject([:id, :name, :rating], &Map.has_key?(mapped, &1)) do
      [] ->
        {:ok, mapped}

      missing ->
        {:error,
         [
           "The first row must name the columns; missing: " <>
             Enum.map_join(missing, ", ", &Atom.to_string/1) <> "."
         ]}
    end
  end

  defp build(data, sep, columns) do
    {rows, errors, _seen} =
      Enum.reduce(data, {[], [], MapSet.new()}, fn {line, line_no}, {rows, errors, seen} ->
        case row(split_line(line, sep), columns) do
          {:ok, row} ->
            key = String.downcase(row.ext_id)

            if MapSet.member?(seen, key) do
              {rows, [{line_no, "the id #{row.ext_id} appears twice"} | errors], seen}
            else
              {[row | rows], errors, MapSet.put(seen, key)}
            end

          {:error, reason} ->
            {rows, [{line_no, reason} | errors], seen}
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, Enum.reverse(rows)}
      errors -> {:error, error_messages(errors)}
    end
  end

  defp error_messages(errors) do
    shown = errors |> Enum.take(@max_errors) |> Enum.map(fn {n, r} -> "Line #{n}: #{r}." end)

    case length(errors) - @max_errors do
      more when more > 0 -> shown ++ ["#{more} more problems not listed."]
      _ -> shown
    end
  end

  defp row(cells, columns) do
    get = fn field ->
      case Map.fetch(columns, field) do
        {:ok, i} -> cells |> Enum.at(i, "") |> String.trim()
        :error -> ""
      end
    end

    with {:ok, ext_id} <- required(get.(:id), "the id is empty"),
         {:ok, name} <- required(get.(:name), "the name is empty"),
         {:ok, rating} <- rating(get.(:rating)),
         {:ok, federation} <- federation(get.(:federation)),
         {:ok, title} <- title(get.(:title)),
         {:ok, birth_year} <- birth_year(get.(:birth_year)),
         {:ok, fide_id} <- fide_id(get.(:fide_id)) do
      {:ok,
       %{
         ext_id: ext_id,
         name: name,
         rating: rating,
         federation: federation,
         title: title,
         birth_year: birth_year,
         fide_id: fide_id
       }}
    end
  end

  defp required("", reason), do: {:error, reason}
  defp required(value, _), do: {:ok, value}

  # A blank rating, or 0, is an unrated player.
  defp rating(""), do: {:ok, nil}

  defp rating(value) do
    case small_int(value) do
      {:ok, 0} -> {:ok, nil}
      {:ok, n} when n in 1..4000 -> {:ok, n}
      _ -> {:error, "the rating #{inspect(value)} is not a number between 1 and 4000"}
    end
  end

  defp federation(""), do: {:ok, ""}

  defp federation(value) do
    upper = String.upcase(value)

    if Regex.match?(~r/\A[A-Z]{3}\z/, upper),
      do: {:ok, upper},
      else: {:error, "the federation #{inspect(value)} is not a three-letter code"}
  end

  defp title(""), do: {:ok, ""}

  defp title(value) do
    upper = String.upcase(value)

    if upper in @titles,
      do: {:ok, upper},
      else: {:error, "the title #{inspect(value)} is not one of #{Enum.join(@titles, ", ")}"}
  end

  defp birth_year(""), do: {:ok, nil}

  defp birth_year(value) do
    case small_int(value) do
      {:ok, n} when n in 1880..2100 -> {:ok, n}
      _ -> {:error, "the birth year #{inspect(value)} is not a year"}
    end
  end

  defp fide_id(""), do: {:ok, nil}

  defp fide_id(value) do
    case small_int(value) do
      {:ok, n} when n >= 1 and n <= 2_000_000_000 -> {:ok, n}
      _ -> {:error, "the FIDE ID #{inspect(value)} is not a FIDE ID"}
    end
  end

  # Length-bounded before `Integer.parse/1`, as in `ResultsImport`.
  defp small_int(value) when byte_size(value) <= 12 do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp small_int(_), do: :error

  defp split_line(line, sep), do: do_split(line, sep, "", [], false)

  defp do_split("", _sep, acc, fields, _quoted), do: Enum.reverse([acc | fields])

  defp do_split(<<"\"\"", rest::binary>>, sep, acc, fields, true),
    do: do_split(rest, sep, acc <> "\"", fields, true)

  defp do_split(<<"\"", rest::binary>>, sep, acc, fields, true),
    do: do_split(rest, sep, acc, fields, false)

  defp do_split(<<"\"", rest::binary>>, sep, "", fields, false),
    do: do_split(rest, sep, "", fields, true)

  defp do_split(<<c::utf8, rest::binary>>, sep, acc, fields, quoted) do
    ch = <<c::utf8>>

    if ch == sep and not quoted,
      do: do_split(rest, sep, "", [acc | fields], false),
      else: do_split(rest, sep, acc <> ch, fields, quoted)
  end
end
