defmodule PairingsEngine.Fide.Sync do
  @moduledoc """
  Downloads the combined FIDE rating list (TXT format, published monthly on
  ratings.fide.com) and loads it into the local fide_players table.

  Progress is broadcast on the "fide_sync" PubSub topic and queryable via
  `status/0`.
  """

  use GenServer
  require Logger
  alias PairingsEngine.{Repo, Fide}
  alias PairingsEngine.Fide.FidePlayer

  @list_url "https://ratings.fide.com/download/players_list.zip"
  @topic "fide_sync"

  # Header labels in file order — "ID Number" is one column despite the space.
  @header_labels [
    "ID Number", "Name", "Fed", "Sex", "Tit", "WTit", "OTit", "FOA",
    "SRtng", "SGm", "SK", "RRtng", "RGm", "Rk", "BRtng", "BGm", "BK",
    "B-day", "Flag"
  ]

  @field_labels %{
    fide_id: "ID Number",
    name: "Name",
    federation: "Fed",
    sex: "Sex",
    title: "Tit",
    standard_rating: "SRtng",
    rapid_rating: "RRtng",
    blitz_rating: "BRtng",
    birth_year: "B-day",
    flag: "Flag"
  }

  @numeric ~w(fide_id standard_rating rapid_rating blitz_rating birth_year)a

  defstruct status: :idle, progress: "", error: nil,
            loaded_bytes: 0, total_bytes: 0, imported_rows: 0, total_rows: 0

  ## API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  def start_sync, do: GenServer.cast(__MODULE__, :start_sync)

  def status do
    GenServer.call(__MODULE__, :status)
    |> Map.from_struct()
    |> Map.put(:player_count, Fide.player_count())
    |> Map.put(:last_sync, Fide.last_sync())
  end

  def topic, do: @topic

  ## GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:start_sync, %{status: s} = state) when s in [:downloading, :importing] do
    {:noreply, state}
  end

  def handle_cast(:start_sync, _state) do
    server = self()
    Task.start(fn -> run_sync(server) end)
    {:noreply, broadcast(%__MODULE__{status: :downloading, progress: "Contacting FIDE…"})}
  end

  @impl true
  def handle_info({:sync_update, new_state}, _state), do: {:noreply, broadcast(new_state)}

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:fide_sync, state})
    state
  end

  defp update(server, state) do
    send(server, {:sync_update, state})
    state
  end

  ## The sync job (runs in its own task)

  defp run_sync(server) do
    state = %__MODULE__{status: :downloading}

    with {:ok, zip, state} <- download(server, state),
         {:ok, text, state} <- unpack(server, zip, state),
         {:ok, state} <- import_list(server, text, state) do
      Fide.put_last_sync()
      update(server, %{state | status: :done, progress: ""})
    else
      {:error, reason} ->
        Logger.error("FIDE sync failed: #{inspect(reason)}")
        update(server, %__MODULE__{status: :error, error: format_error(reason)})
    end
  rescue
    e ->
      Logger.error("FIDE sync crashed: #{Exception.message(e)}")
      update(server, %__MODULE__{status: :error, error: Exception.message(e)})
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp download(server, state) do
    # The into: fun runs in this task's process, so chunks and the byte count
    # are accumulated in the process dictionary. Progress is broadcast at most
    # once per megabyte to avoid flooding the LiveView.
    Process.put(:sync_chunks, [])
    Process.put(:sync_loaded, 0)
    Process.put(:sync_last_report, 0)

    into = fn {:data, data}, {req, resp} ->
      total = resp_content_length(resp)
      Process.put(:sync_chunks, [data | Process.get(:sync_chunks)])
      loaded = Process.get(:sync_loaded) + byte_size(data)
      Process.put(:sync_loaded, loaded)

      if loaded - Process.get(:sync_last_report) > 1_048_576 do
        Process.put(:sync_last_report, loaded)
        mb = Float.round(loaded / 1_048_576, 1)
        total_mb = if total > 0, do: " of #{Float.round(total / 1_048_576, 1)}", else: ""

        update(server, %{state |
          status: :downloading,
          loaded_bytes: loaded,
          total_bytes: total,
          progress: "Downloading rating list… #{mb}#{total_mb} MB"
        })
      end

      {:cont, {req, resp}}
    end

    case Req.get(@list_url, into: into) do
      {:ok, %{status: 200}} ->
        zip = Process.get(:sync_chunks) |> Enum.reverse() |> IO.iodata_to_binary()
        loaded = byte_size(zip)
        {:ok, zip, %{state | loaded_bytes: loaded, total_bytes: loaded}}

      {:ok, %{status: status}} ->
        {:error, "FIDE server answered #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resp_content_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [len | _] -> String.to_integer(len)
      _ -> 0
    end
  end

  defp unpack(server, zip, state) do
    state = update(server, %{state | status: :importing, progress: "Unpacking…"})

    case :zip.extract(zip, [:memory]) do
      {:ok, files} ->
        case Enum.find(files, fn {name, _} -> String.ends_with?(to_string(name), ".txt") end) do
          # Kept as raw Latin-1 bytes: fixed-width columns are byte offsets, so
          # converting to UTF-8 first would shift columns on accented names.
          # Each string field is converted after slicing (see parse_line/2).
          {_name, data} ->
            {:ok, data, state}

          nil ->
            {:error, "No .txt file found inside the FIDE zip"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_list(server, text, state) do
    # :binary.split, not String.split: the text is Latin-1, not valid UTF-8.
    [header | lines] = :binary.split(text, ["\r\n", "\n"], [:global])
    offsets = column_offsets(header)
    total = length(lines)
    state = update(server, %{state | total_rows: total})

    rows =
      lines
      |> Stream.reject(&(&1 in ["", "\r"]))
      |> Stream.map(&parse_line(&1, offsets))
      |> Stream.reject(&(is_nil(&1.fide_id) or &1.name in [nil, ""]))

    Repo.transaction(
      fn ->
        # Full replace: the monthly list is authoritative (players do get removed).
        Repo.query!("DELETE FROM fide_players")

        rows
        |> Stream.chunk_every(2000)
        |> Stream.with_index(1)
        |> Enum.each(fn {chunk, i} ->
          Repo.insert_all(FidePlayer, chunk,
            on_conflict: :replace_all,
            conflict_target: :fide_id
          )

          imported = i * 2000

          if rem(i, 25) == 0 do
            update(server, %{state |
              imported_rows: imported,
              progress: "Importing players… #{format_int(imported)} of ~#{format_int(total)}"
            })
          end
        end)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, _} -> {:ok, %{state | imported_rows: total}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Column offsets are derived from the header line so a layout change
  # between months doesn't silently corrupt fields.
  defp column_offsets(header) do
    {starts, _} =
      Enum.reduce(@header_labels, {%{}, 0}, fn label, {acc, from} ->
        case :binary.match(header, label, scope: {from, byte_size(header) - from}) do
          {idx, len} -> {Map.put(acc, label, idx), idx + len}
          :nomatch -> raise "FIDE list header is missing the \"#{label}\" column"
        end
      end)

    for {field, label} <- @field_labels, into: %{} do
      next_label = next_label(label)
      start = Map.fetch!(starts, label)
      stop = if next_label, do: Map.fetch!(starts, next_label), else: :eol
      {field, {start, stop}}
    end
  end

  defp next_label(label) do
    idx = Enum.find_index(@header_labels, &(&1 == label))
    Enum.at(@header_labels, idx + 1)
  end

  defp parse_line(line, offsets) do
    for {field, {start, stop}} <- offsets, into: %{} do
      len = if stop == :eol, do: byte_size(line) - start, else: stop - start

      raw =
        if len > 0 and start < byte_size(line) do
          line
          |> binary_part(start, min(len, byte_size(line) - start))
          |> :unicode.characters_to_binary(:latin1, :utf8)
          |> String.trim()
        else
          ""
        end

      value =
        if field in @numeric do
          case Integer.parse(raw) do
            {n, _} -> n
            :error -> nil
          end
        else
          raw
        end

      {field, value}
    end
  end

  defp format_int(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ".")
end
