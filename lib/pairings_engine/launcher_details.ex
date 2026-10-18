defmodule PairingsEngine.LauncherDetails do
  @moduledoc """
  The server side of the launcher's *Details* panel and of
  `openpairings.sh details`: the secret that lets them ask
  `GET /_launcher/stats` (`PairingsEngineWeb.Plugs.LauncherStats`), the CPU
  sample that endpoint reports, and the last few slow queries.

  The contract - who may ask, what comes back - is `docs/launcher-details.md`.
  The short version: a desktop copy only, a loopback peer only, and only with
  the header `x-launcher-token` carrying this start's secret. Everything else
  gets a 404 and nothing more.

  ## The secret

  The Windows launcher makes one per start and hands it over in
  `OPENPAIRINGS_LAUNCHER_TOKEN`. When nothing hands one over (`openpairings.sh`,
  a Mac, a terminal), this process makes its own and writes it to
  `<data>/run/launcher.token` - first line the secret, second line the port -
  readable by the owner only, and deletes it again on a clean stop. A crash
  leaves a stale file; the next start overwrites it, and a stale secret opens
  nothing because the server that knew it is gone.

  ## What it costs

  On a hosted server: one idle process for the life of the node. No secret,
  no telemetry handler, no scheduler sampling - the endpoint answers 404 there
  regardless. On a desktop copy: one telemetry handler that does a single
  comparison per query, and scheduler wall-time accounting switched on only
  from the first time somebody asks for the CPU figure.
  """
  use GenServer

  require Logger

  @env "OPENPAIRINGS_LAUNCHER_TOKEN"
  @header "x-launcher-token"
  @slow_ms 100
  @keep_slow 5

  @doc "The request header that carries the secret."
  def header, do: @header

  @doc "The environment variable a launcher hands its secret over in."
  def env_var, do: @env

  @doc "A query at or above this many milliseconds counts as slow."
  def slow_ms, do: @slow_ms

  @doc "This start's secret, or nil where there is none (hosted, or not started)."
  def token, do: Application.get_env(:pairings_engine, :launcher_token)

  @doc "Whether `given` is this start's secret. Constant-time."
  def authorized?(given) when is_binary(given) and given != "" do
    case token() do
      token when is_binary(token) -> Plug.Crypto.secure_compare(given, token)
      _none -> false
    end
  end

  def authorized?(_given), do: false

  @doc "Where a generated secret is written, for a data directory."
  def token_file(data_dir), do: Path.join([data_dir, "run", "launcher.token"])

  @doc """
  Scheduler utilisation in percent since the previous call, or nil on the
  first call (there is nothing to compare with yet) and wherever this process
  is not answering.
  """
  def cpu_percent(server \\ __MODULE__) do
    GenServer.call(server, :cpu, 1_000)
  catch
    :exit, _reason -> nil
  end

  @doc "The last few queries that took #{@slow_ms} ms or longer, newest first."
  def slow_queries(server \\ __MODULE__) do
    GenServer.call(server, :slow, 1_000)
  catch
    :exit, _reason -> []
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # --- server -------------------------------------------------------------

  @impl true
  def init(opts) do
    if Keyword.get_lazy(opts, :local?, &PairingsEngine.Authz.local_mode?/0) do
      # So terminate/2 runs on a clean stop, and the token file goes with it.
      Process.flag(:trap_exit, true)

      {token, file} =
        case Keyword.get_lazy(opts, :env_token, fn -> System.get_env(@env) end) do
          given when is_binary(given) and byte_size(given) >= 16 ->
            {given, nil}

          _none ->
            token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
            {token, write_token(Keyword.get_lazy(opts, :data_dir, &data_dir/0), token, port())}
        end

      Application.put_env(:pairings_engine, :launcher_token, token)

      handler = {__MODULE__, self()}

      :telemetry.attach(
        handler,
        [:pairings_engine, :repo, :query],
        &__MODULE__.handle_query/4,
        self()
      )

      {:ok, %{local?: true, token_file: file, handler: handler, sample: nil, slow: []}}
    else
      {:ok, %{local?: false}}
    end
  end

  @impl true
  def handle_call(:cpu, _from, %{local?: true} = state) do
    # Wall-time accounting is per process and reference counted: on from the
    # first question, off again when this process ends. Nobody asking, no
    # accounting.
    if state.sample == nil, do: :erlang.system_flag(:scheduler_wall_time, true)

    sample = :scheduler.get_sample()

    percent =
      with previous when previous not in [nil, :undefined] <- state.sample,
           current when current != :undefined <- sample,
           {:total, share, _text} <-
             List.keyfind(:scheduler.utilization(previous, current), :total, 0) do
        Float.round(share * 100, 1)
      else
        _first -> nil
      end

    {:reply, percent, %{state | sample: sample}}
  end

  def handle_call(:slow, _from, %{local?: true} = state), do: {:reply, state.slow, state}
  def handle_call(:slow, _from, state), do: {:reply, [], state}
  def handle_call(:cpu, _from, state), do: {:reply, nil, state}

  @impl true
  def handle_info({:slow_query, entry}, %{local?: true} = state) do
    {:noreply, %{state | slow: Enum.take([entry | state.slow], @keep_slow)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{local?: true} = state) do
    :telemetry.detach(state.handler)
    if state.token_file, do: File.rm(state.token_file)
    forget_token()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # On a whole-VM stop the application controller is busy dying and answers
  # every question with an exit; the secret dies with the VM regardless, so
  # there is nothing to forget and no reason to crash on the way out.
  defp forget_token do
    Application.delete_env(:pairings_engine, :launcher_token)
  catch
    :exit, _stopping -> :ok
  end

  @doc false
  # Runs in the process that made the query, on every query: one comparison,
  # and a message only for a slow one.
  def handle_query(_event, measurements, metadata, server) do
    with native when is_integer(native) <- measurements[:total_time],
         ms when ms >= @slow_ms <- System.convert_time_unit(native, :native, :microsecond) / 1000 do
      send(
        server,
        {:slow_query,
         %{
           ms: Float.round(ms, 1),
           source: metadata[:source],
           query: metadata[:query] |> to_string() |> String.slice(0, 160),
           at: DateTime.utc_now(:second)
         }}
      )
    end

    :ok
  end

  # --- the token file -------------------------------------------------------

  defp write_token(nil, _token, _port), do: nil

  defp write_token(dir, token, port) do
    run = Path.join(dir, "run")
    file = token_file(dir)

    with :ok <- File.mkdir_p(run),
         _ <- File.chmod(run, 0o700),
         # Empty and private first, the secret after: there is no moment at
         # which the secret sits in a file somebody else may read. On Windows
         # chmod does nothing and the profile folder's own rights do the job.
         :ok <- File.write(file, ""),
         _ <- File.chmod(file, 0o600),
         :ok <- File.write(file, "#{token}\n#{port}\n") do
      file
    else
      {:error, reason} ->
        Logger.warning("Launcher details: could not write #{file}: #{inspect(reason)}")
        nil
    end
  end

  defp data_dir do
    case Application.get_env(:pairings_engine, PairingsEngine.Repo, [])[:database] do
      path when is_binary(path) -> Path.dirname(path)
      _memory -> nil
    end
  end

  defp port do
    Application.get_env(:pairings_engine, PairingsEngineWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4000)
  end
end
