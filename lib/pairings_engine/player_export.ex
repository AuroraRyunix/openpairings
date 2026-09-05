defmodule PairingsEngine.PlayerExport do
  @moduledoc """
  The player list as a CSV file, with the arbiter choosing which fields go
  in it, in which order, how the rows are sorted, and what separates the
  columns.

  ## Why any of that is configurable

  A player-list CSV is never read by this app - it goes to a spreadsheet, a
  federation's upload form, or somebody's script. Each of those wants a
  different shape, and the differences are not cosmetic:

    * **Delimiter.** Excel splits on the list separator of the machine's
      locale, not on a comma. On a Belgian or Dutch Windows that is a
      SEMICOLON, so a comma-separated file opens as one column of text and
      the arbiter has to walk the import wizard. Offering the separator is
      the difference between "double-click it" and "explain the wizard".
    * **Field choice and order.** A federation form wants its columns in
      its own order; `Enum.filter` over a fixed master list cannot express
      that, which is why `columns/1` below preserves the order it is GIVEN
      rather than the order they are declared in.
    * **Row order.** Seeded order is what a pairing list is checked
      against; alphabetical is what a registration desk works from.

  ## Header labels are English, and not translated

  Every other string a person sees in this app goes through gettext. These
  do not, deliberately: a header that changes with the interface language
  silently breaks whatever formula, lookup or script reads the file, and
  the arbiter who set that up did not change any setting - somebody else
  picked a different language. The field KEYS are the stable contract and
  they are visible in the download URL; the labels just happen to read as
  English. Same choice, for the same reason, as the printed player list's
  column table in `PairingsEngineWeb.PrintController`.

  ## Formula injection

  A cell that starts with `=`, `+`, `-` or `@` is executed as a formula by
  Excel and LibreOffice. Player names are typed by whoever registered, so
  a name like `=HYPERLINK("http://...","click")` would run on the machine
  of anyone who opens the file - the classic CSV-injection route, and the
  reason `guard/1` below prefixes those with an apostrophe.

  It is applied ONLY to text columns. Numbers are rendered by this module
  from integers and floats, never from typed text, so a leading `-` there
  is a negative number and must be left alone - guarding it would turn
  `-1.5` extra points into a string in every spreadsheet that opened it.
  """

  alias PairingsEngine.Tournaments.Player

  # {key, label, kind}. `kind` is `:text` when the value can contain
  # anything a person typed (and so needs the formula guard), `:plain` when
  # this module renders it from a number, a date or a boolean.
  @columns [
    {:pairing_number, "Nr", :plain},
    {:name, "Name", :text},
    {:title, "Title", :text},
    {:sex, "Sex", :text},
    {:birth_year, "Birth year", :plain},
    {:birth_date, "Birth date", :plain},
    {:federation, "Federation", :text},
    {:fide_id, "FIDE ID", :plain},
    {:fide_rating, "FIDE rating", :plain},
    {:national_id, "National ID", :text},
    {:national_rating, "National rating", :plain},
    {:elo_used, "Rating used", :plain},
    {:club, "Club", :text},
    {:club_number, "Club number", :plain},
    {:category, "Category", :text},
    {:status, "Status", :text},
    {:paid, "Paid", :text},
    {:affiliated, "Affiliated", :plain},
    {:absent, "Absent", :plain},
    {:absent_rounds, "Absent rounds", :text},
    {:forfeit, "Forfeit", :plain},
    {:start_round, "Start round", :plain},
    {:extra_points, "Extra points", :plain},
    {:fixed_board, "Fixed board", :plain},
    {:special_table, "Special table", :plain},
    {:manual_rank, "Manual rank", :plain}
  ]

  # What an arbiter who has not chosen gets: a registration list. Wide
  # enough to be useful on its own, narrow enough to read on one screen.
  @default_columns [
    :pairing_number,
    :name,
    :title,
    :fide_rating,
    :national_rating,
    :federation,
    :club
  ]

  # Named rather than passed as raw characters so that a delimiter can
  # never arrive from a query string as, say, a quote or a newline.
  @delimiters %{"comma" => ",", "semicolon" => ";", "tab" => "\t", "pipe" => "|"}
  # Listed rather than taken from the map, whose key order is not the
  # declaration order and would shuffle the picker between releases.
  @delimiter_order ~w(comma semicolon tab pipe)

  @sort_orders ~w(seed name)

  @doc "Every exportable column, in declaration order: `{key, label, kind}`."
  def columns, do: @columns

  @doc "The column keys used when the arbiter has not chosen any."
  def default_columns, do: @default_columns

  @doc "Delimiter names, for the picker and for `export/2`'s `:delimiter`."
  def delimiter_names, do: @delimiter_order

  @doc "Row orders `export/2` accepts."
  def sort_orders, do: @sort_orders

  @doc """
  The label declared for `key`, or `nil`.
  """
  def label(key) do
    Enum.find_value(@columns, fn {k, label, _kind} -> if k == key, do: label end)
  end

  @doc """
  Turns a comma-separated list of column keys into known keys, KEEPING THE
  ORDER GIVEN and dropping unknown or repeated ones.

  The order is the point: this is how the arbiter's chosen column order
  survives the round trip through the download URL. An empty or wholly
  unrecognised list falls back to `default_columns/0` rather than producing
  a file with no columns at all.
  """
  def parse_columns(nil), do: @default_columns
  def parse_columns(""), do: @default_columns

  def parse_columns(csv) when is_binary(csv) do
    known = Map.new(@columns, fn {k, _l, _kind} -> {Atom.to_string(k), k} end)

    parsed =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn name -> if k = known[name], do: [k], else: [] end)
      |> Enum.uniq()

    if parsed == [], do: @default_columns, else: parsed
  end

  @doc """
  The CSV text.

  Options:

    * `:columns` - ordered column keys (default `default_columns/0`)
    * `:delimiter` - one of `delimiter_names/0` (default `"comma"`)
    * `:sort` - `"seed"` or `"name"` (default `"seed"`)
    * `:skip_absent` - drop players flagged permanently absent
    * `:bom` - prepend a UTF-8 byte-order mark (default `true`)

  Rows end with CRLF, per RFC 4180 - and because a lone LF is what makes
  Excel put the whole file on one line.
  """
  def export(players, opts \\ []) do
    columns = Keyword.get(opts, :columns, @default_columns)
    delimiter = Map.get(@delimiters, to_string(Keyword.get(opts, :delimiter, "comma")), ",")
    cols = Enum.filter(@columns, fn {k, _l, _kind} -> k in columns end)

    # Ordered as the CALLER asked, not as declared above.
    ordered = Enum.map(columns, fn key -> Enum.find(cols, fn {k, _, _} -> k == key end) end)
    ordered = Enum.reject(ordered, &is_nil/1)

    rows =
      players
      |> filter_players(opts)
      |> sort_players(Keyword.get(opts, :sort, "seed"))
      |> Enum.map(fn player ->
        Enum.map_join(ordered, delimiter, fn {key, _label, kind} ->
          player |> value(key) |> guard(kind) |> escape(delimiter)
        end)
      end)

    header =
      Enum.map_join(ordered, delimiter, fn {_k, label, _kind} -> escape(label, delimiter) end)

    bom = if Keyword.get(opts, :bom, true), do: "﻿", else: ""

    bom <> Enum.join([header | rows], "\r\n") <> "\r\n"
  end

  # The permanent "Absent" checkbox only - NOT `absent_rounds`, which says
  # a player misses round 3, not that they are out of the tournament. A
  # registration list that dropped everyone with one round off would be
  # missing most of a club championship.
  defp filter_players(players, opts) do
    if Keyword.get(opts, :skip_absent, false) do
      Enum.reject(players, & &1.absent)
    else
      players
    end
  end

  # `Enum.sort_by/2` is stable, so players who have no `pairing_number` yet
  # keep the order they arrived in - which is `Tournaments.list_players/1`'s
  # rating-then-name order, i.e. the seeding they WOULD be given. Sorting
  # them all to 0 instead would have scrambled a list that is most often
  # exported before the first round is paired.
  defp sort_players(players, "name") do
    Enum.sort_by(players, &String.downcase(&1.name || ""))
  end

  defp sort_players(players, _seed) do
    Enum.sort_by(players, &{is_nil(&1.pairing_number), &1.pairing_number || 0})
  end

  defp value(%Player{} = p, :elo_used) do
    if p.fide_rating && p.fide_rating > 0, do: p.fide_rating, else: p.national_rating
  end

  defp value(%Player{} = p, :birth_date) do
    case p.birth_date do
      %Date{} = d -> Date.to_iso8601(d)
      _ -> ""
    end
  end

  defp value(%Player{} = p, key), do: Map.get(p, key)

  defp guard(nil, _kind), do: ""
  defp guard(true, _kind), do: "yes"
  defp guard(false, _kind), do: "no"
  defp guard(value, :plain), do: to_string(value)

  defp guard(value, :text) do
    string = to_string(value)

    if String.starts_with?(string, ["=", "+", "-", "@", "\t", "\r"]) do
      "'" <> string
    else
      string
    end
  end

  # RFC 4180: a field carrying the delimiter, a quote or a line break is
  # quoted, and its own quotes are doubled.
  defp escape(value, delimiter) do
    string = to_string(value)

    if String.contains?(string, [delimiter, "\"", "\n", "\r"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end
end
