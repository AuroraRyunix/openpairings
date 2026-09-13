defmodule PairingsEngine.Federations.BEL.SqliteFile do
  @moduledoc """
  Reads a KBSB `players.sqlite` (the one table the public monthly zip
  contains, and the one `PairingsEngine.Federations.BEL.Http` downloads) -
  shared by the automatic HTTP sync AND the manual file upload, which the
  brief asks to accept "this same zip, or the `players.sqlite` inside it,
  as well as whatever it accepted before" (the older delimited-text
  format, still handled by `PairingsEngine.Federations.BEL.Parser`).

  `read/1` accepts either a zip (detected by its `PK` signature) or a bare
  `.sqlite` file (detected by the standard 16-byte SQLite header) and
  returns raw column-keyed row maps plus, if present, the optional
  `clubs` table - see `PairingsEngine.Federations.BEL.Clubs`.

  `to_member_row/2` converts one raw row into the atom-keyed map
  `PairingsEngine.Federations.BEL.Sync.import_rows/3` expects, applying
  the field allowlist decided in docs/kbsb-sync.md: only what a feature
  actually reads is kept. `Birthday` (a full date) is reduced to its year;
  `LoginModif` and `DateModif` are never read at all - they aren't even in
  `@required_columns` below, so they can't reach this far.
  """

  @max_uncompressed_bytes 100_000_000

  @required_columns ~w(IdNumber Name Sex Birthday Fed Club Affiliated Elo
                        EloPrevious Gain Games GamesPrevious Performance
                        Opponents LastGames Border Arbiter NatPlayer
                        NatFideSign G Died FideId)

  @doc "`true` for a zip (`PK\\x03\\x04` signature)."
  def zip?(<<0x50, 0x4B, 0x03, 0x04, _rest::binary>>), do: true
  def zip?(_binary), do: false

  @doc "`true` for a raw SQLite database file (the standard 16-byte header)."
  def sqlite?(<<"SQLite format 3\0", _rest::binary>>), do: true
  def sqlite?(_binary), do: false

  @doc """
  `{:ok, %{rows: [raw_map], clubs: map() | nil}}` from either a zip
  containing `players.sqlite` or a bare `players.sqlite` file, or
  `{:error, reason}`.
  """
  def read(binary) when is_binary(binary) do
    cond do
      zip?(binary) -> read_zip(binary)
      sqlite?(binary) -> open_players_db(binary)
      true -> {:error, :not_sqlite}
    end
  end

  defp read_zip(zip_bytes) do
    with {:ok, entries} <- :zip.list_dir(zip_bytes),
         :ok <- check_uncompressed_size(entries) do
      case :zip.extract(zip_bytes, [:memory]) do
        {:ok, files} ->
          case Enum.find(files, fn {name, _} ->
                 String.ends_with?(to_string(name), "players.sqlite")
               end) do
            {_name, data} -> open_players_db(data)
            nil -> {:error, "No players.sqlite found inside the zip."}
          end

        {:error, reason} ->
          {:error, "Could not unzip the file: #{inspect(reason)}"}
      end
    end
  end

  defp check_uncompressed_size(entries) do
    total =
      Enum.reduce(entries, 0, fn
        {:zip_file, _name, info, _comment, _offset, _comp_size}, acc -> acc + elem(info, 1)
        _other, acc -> acc
      end)

    if total > @max_uncompressed_bytes do
      {:error,
       "The zip declares #{total} uncompressed bytes, past the " <>
         "#{@max_uncompressed_bytes}-byte limit."}
    else
      :ok
    end
  end

  defp open_players_db(sqlite_bytes) do
    tmp_path =
      Path.join(System.tmp_dir!(), "kbsb_players_#{System.unique_integer([:positive])}.sqlite")

    File.write!(tmp_path, sqlite_bytes)

    try do
      case Exqlite.Sqlite3.open(tmp_path, mode: :readonly) do
        {:ok, conn} ->
          try do
            with :ok <- validate_players_table(conn),
                 {:ok, rows} <- read_players(conn) do
              {:ok, %{rows: rows, clubs: read_clubs_table(conn)}}
            end
          after
            Exqlite.Sqlite3.close(conn)
          end

        {:error, reason} ->
          {:error, "Could not open players.sqlite: #{inspect(reason)}"}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp validate_players_table(conn) do
    case table_columns(conn, "players") do
      [] ->
        {:error, "players.sqlite has no \"players\" table."}

      columns ->
        case @required_columns -- columns do
          [] ->
            :ok

          missing ->
            {:error,
             "players.sqlite's \"players\" table is missing column(s): " <>
               Enum.join(missing, ", ")}
        end
    end
  end

  defp table_columns(conn, table) do
    case Exqlite.Sqlite3.prepare(conn, "PRAGMA table_info(#{table})") do
      {:ok, stmt} ->
        {:ok, info} = Exqlite.Sqlite3.fetch_all(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        Enum.map(info, fn row -> Enum.at(row, 1) end)

      {:error, _reason} ->
        []
    end
  end

  defp read_players(conn) do
    columns = @required_columns
    sql = "SELECT " <> Enum.join(columns, ", ") <> " FROM players"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         {:ok, rows} <- fetch_release(conn, stmt) do
      {:ok, Enum.map(rows, &(Enum.zip(columns, &1) |> Map.new()))}
    else
      {:error, reason} -> {:error, "Could not read players.sqlite's rows: #{inspect(reason)}"}
    end
  end

  defp fetch_release(conn, stmt) do
    result = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  # Optional: absent on most months until the maintainer starts publishing
  # one. The pinned, documented shape (docs/kbsb-sync.md) is exactly
  # `Club INTEGER PRIMARY KEY, Name TEXT` - matched first, case-sensitively.
  # The wider alias list below is a LENIENT FALLBACK only, in case a real
  # export ever differs - see `PairingsEngine.Federations.BEL.Clubs`.
  defp read_clubs_table(conn) do
    case table_columns(conn, "clubs") do
      [] ->
        nil

      columns ->
        number_col =
          Enum.find(columns, &(&1 == "Club")) ||
            Enum.find(columns, &(String.downcase(&1) in ["club", "idclub", "clubnumber"]))

        name_col =
          Enum.find(columns, &(&1 == "Name")) ||
            Enum.find(columns, &(String.downcase(&1) in ["name", "clubname"]))

        if number_col && name_col do
          sql = "SELECT #{number_col}, #{name_col} FROM clubs"

          case Exqlite.Sqlite3.prepare(conn, sql) do
            {:ok, stmt} ->
              {:ok, rows} = fetch_release(conn, stmt)

              Enum.reduce(rows, %{}, fn [num, name], acc ->
                if is_integer(num) and is_binary(name) and name != "" do
                  Map.put(acc, num, name)
                else
                  acc
                end
              end)

            {:error, _reason} ->
              nil
          end
        else
          nil
        end
    end
  end

  @doc """
  Converts one raw `players` table row (string column keys, as `read/1`
  returns) into the atom-keyed map `Sync.import_rows/3` inserts - the
  field allowlist from docs/kbsb-sync.md: `Birthday` reduces to a year,
  `LoginModif`/`DateModif` are never read, and `Affiliated`/`Died`
  (0/1 integers in the source) become booleans. `club_names` is the
  resolved `%{club_number => name}` map from
  `PairingsEngine.Federations.BEL.Clubs.resolve/2` - looked up here so
  every stored row already carries its display name, matching how
  `club_name` worked before (denormalized onto the Member row).
  """
  def to_member_row(row, club_names \\ %{}) do
    club_number = int(row["Club"])

    %{
      national_id: to_string(row["IdNumber"]),
      last_name: last_name(row["Name"]),
      first_name: first_name(row["Name"]),
      national_rating: int(row["Elo"]),
      fide_id: int(row["FideId"]),
      club_number: club_number,
      club_name: Map.get(club_names, club_number, ""),
      federation: row["Fed"] || "",
      birth_year: birth_year(row["Birthday"]),
      died: bool(row["Died"]),
      affiliated: bool(row["Affiliated"])
    }
  end

  # "Last, First" per the brief - split on the first comma only, so a
  # last name that itself contains a comma (rare, but seen in Belgian club
  # records) doesn't lose everything after the second one.
  defp last_name(nil), do: ""

  defp last_name(name) when is_binary(name),
    do: name |> String.split(",", parts: 2) |> hd() |> String.trim()

  defp first_name(nil), do: ""

  defp first_name(name) when is_binary(name) do
    case String.split(name, ",", parts: 2) do
      [_last, first] -> String.trim(first)
      [_only] -> ""
    end
  end

  # `Birthday` arrives as either a "YYYYMMDD"-style string/integer or a
  # bare year - either way, only the leading 4 digits (the year) are kept.
  # The full date is deliberately never stored: no feature reads a
  # player's day of birth, only the year (see `ClubRefresh.year_agrees?/2`).
  defp birth_year(nil), do: nil
  defp birth_year(""), do: nil
  defp birth_year(0), do: nil

  defp birth_year(date) when is_integer(date), do: date |> Integer.to_string() |> birth_year()

  defp birth_year(date_str) when is_binary(date_str) do
    case String.slice(date_str, 0, 4) do
      <<y1, y2, y3, y4>> when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9 ->
        String.to_integer(<<y1, y2, y3, y4>>)

      _ ->
        nil
    end
  end

  defp birth_year(_other), do: nil

  defp bool(1), do: true
  defp bool(0), do: false
  defp bool(true), do: true
  defp bool(false), do: false
  defp bool(_other), do: nil

  defp int(nil), do: nil
  defp int(n) when is_integer(n), do: n

  defp int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp int(_other), do: nil
end
