defmodule PairingsEngine.LauncherDetails.Stats do
  @moduledoc """
  What `GET /_launcher/stats` answers: the JSON documented in
  `docs/launcher-details.md`. Raw numbers for anything that wants to compute,
  and `summary` - the same numbers as label/value lines in words and units,
  English or Dutch - for anything that only wants to show them (the Windows
  launcher, `openpairings.sh details`).

  Cheap by rule, because it is asked every two seconds for as long as
  somebody leaves a panel open: no query that reads a table end to end except
  `count(*)` on tournaments, which is a few hundred rows on the largest desk,
  no process asked anything it could be slow to answer, and nothing that
  waits. The process scan for open pages reads one key of each process's
  dictionary, about a millisecond for the few thousand processes a desktop
  copy has.
  """

  import Ecto.Query

  alias PairingsEngine.BoardLink.Link
  alias PairingsEngine.LauncherDetails
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  @mb 1_048_576
  # The same window the Live boards page uses for "online".
  @online_s 60

  @doc "The whole answer, as a map ready for JSON. `lang` is \"en\" or \"nl\"."
  def collect(lang \\ "en") do
    lang = if lang == "nl", do: "nl", else: "en"
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    stats = %{
      app: "openpairings",
      version: vsn(:pairings_engine),
      engine_version: vsn(:ainalrami),
      uptime_s: div(uptime_ms, 1000),
      started_at:
        DateTime.utc_now(:second) |> DateTime.add(-div(uptime_ms, 1000)) |> DateTime.to_iso8601(),
      system: system(),
      beam: %{
        memory_bytes: %{
          total: memory[:total],
          processes: memory[:processes],
          ets: memory[:ets],
          binary: memory[:binary],
          code: memory[:code]
        },
        processes: :erlang.system_info(:process_count),
        schedulers: :erlang.system_info(:schedulers_online),
        run_queue: :erlang.statistics(:run_queue),
        cpu_percent: LauncherDetails.cpu_percent()
      },
      database: database(),
      log: log(),
      openpairings: %{
        live_views: live_views(),
        tournaments: safe(fn -> Repo.aggregate(Tournament, :count, log: false) end),
        board_links_online: safe(&board_links_online/0)
      }
    }

    Map.put(stats, :summary, summary(stats, lang))
  end

  # --- the parts --------------------------------------------------------------

  defp vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp system do
    {family, name} = :os.type()

    os =
      case {family, name} do
        {:win32, _} -> "windows"
        {:unix, :darwin} -> "macos"
        {:unix, other} -> to_string(other)
      end

    %{
      os: os,
      os_version: :os.version() |> Tuple.to_list() |> Enum.join("."),
      arch: to_string(:erlang.system_info(:system_architecture)),
      cores: :erlang.system_info(:logical_processors_available) |> integer_or_nil(),
      otp: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      load_average: load_average()
    }
  end

  defp integer_or_nil(n) when is_integer(n), do: n
  defp integer_or_nil(_unknown), do: nil

  # Linux only, and only because it is a file read: os_mon would answer for
  # every system, at the price of an application and a port program.
  defp load_average do
    with {:ok, text} <- File.read("/proc/loadavg"),
         [one, five, fifteen | _] <- String.split(text),
         {one, _} <- Float.parse(one),
         {five, _} <- Float.parse(five),
         {fifteen, _} <- Float.parse(fifteen) do
      [one, five, fifteen]
    else
      _none -> nil
    end
  end

  defp database do
    path = Application.get_env(:pairings_engine, Repo, [])[:database]

    %{
      path: path,
      size_bytes: file_size(path),
      wal_bytes: path && file_size(path <> "-wal"),
      ping_ms: ping(),
      slow_queries:
        LauncherDetails.slow_queries()
        |> Enum.map(&%{&1 | at: DateTime.to_iso8601(&1.at)}),
      slow_threshold_ms: LauncherDetails.slow_ms()
    }
  end

  defp file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _none -> nil
    end
  end

  defp file_size(_none), do: nil

  # A round trip through the pool, the same road every page takes: checkout,
  # query, checkin. What a slow disk or a busy pool costs shows up here.
  defp ping do
    {micros, result} =
      :timer.tc(fn ->
        try do
          Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 2_000, log: false)
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    case result do
      {:ok, _} -> Float.round(micros / 1000, 2)
      _error -> nil
    end
  end

  defp log do
    data = data_dir()

    cond do
      System.get_env(LauncherDetails.env_var()) not in [nil, ""] and is_binary(data) and
          File.exists?(Path.join(data, "launcher.log")) ->
        %{source: "file", path: Path.join(data, "launcher.log")}

      System.get_env("INVOCATION_ID") not in [nil, ""] ->
        %{source: "journald", unit: systemd_unit()}

      true ->
        %{source: "stdout"}
    end
  end

  defp data_dir do
    case Application.get_env(:pairings_engine, Repo, [])[:database] do
      path when is_binary(path) -> Path.dirname(path)
      _memory -> nil
    end
  end

  # "0::/system.slice/openpairings.service" -> "openpairings.service".
  defp systemd_unit do
    with {:ok, text} <- File.read("/proc/self/cgroup"),
         [unit | _] <- Regex.run(~r/[^\/\s]+\.service/, text) do
      unit
    else
      _none -> nil
    end
  end

  # Pages open: LiveView processes, which Phoenix labels with the view's mount
  # as their initial call. One dictionary key per process, nothing copied.
  defp live_views do
    Enum.count(Process.list(), fn pid ->
      match?(
        {{:dictionary, :"$initial_call"}, {_view, :mount, 3}},
        :erlang.process_info(pid, {:dictionary, :"$initial_call"})
      )
    end)
  end

  defp board_links_online do
    since = DateTime.add(DateTime.utc_now(:second), -@online_s)
    Repo.aggregate(from(l in Link, where: l.last_seen_at >= ^since), :count, log: false)
  end

  defp safe(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # --- in words -----------------------------------------------------------------

  @labels %{
    "en" => %{
      version: "Version",
      uptime: "Running for",
      cpu: "CPU",
      memory: "Memory",
      database: "Database",
      slow: "Slow queries",
      system: "System",
      pages: "Pages open",
      tournaments: "Tournaments",
      boards: "Board links online"
    },
    "nl" => %{
      version: "Versie",
      uptime: "Draait al",
      cpu: "Processor",
      memory: "Geheugen",
      database: "Database",
      slow: "Trage queries",
      system: "Systeem",
      pages: "Open pagina's",
      tournaments: "Toernooien",
      boards: "Bordkoppelingen online"
    }
  }

  @doc "The label of each summary line, in order, for a language - what a launcher shows before the server answers."
  def labels(lang \\ "en") do
    l = @labels[lang] || @labels["en"]

    [l.version, l.uptime, l.cpu, l.memory, l.database, l.slow, l.system, l.pages] ++
      [l.tournaments, l.boards]
  end

  defp summary(s, lang) do
    l = @labels[lang]
    nl? = lang == "nl"
    beam = s.beam
    mem = beam.memory_bytes
    db = s.database
    app = s.openpairings

    version =
      ["OpenPairings #{s.version}", s.engine_version && "Ainalrami #{s.engine_version}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    cpu =
      [
        if(beam.cpu_percent, do: "#{num(beam.cpu_percent, 1, nl?)} %", else: "—"),
        "(#{beam.schedulers} schedulers, #{if nl?, do: "wachtrij", else: "run queue"} #{beam.run_queue})",
        s.system.load_average &&
          "load " <> Enum.map_join(s.system.load_average, " ", &num(&1, 2, nl?))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    memory =
      "#{mb(mem.total, nl?)} (#{if nl?, do: "processen", else: "processes"} #{mb(mem.processes, nl?)}, " <>
        "ETS #{mb(mem.ets, nl?)}, binary #{mb(mem.binary, nl?)}; " <>
        "#{beam.processes} #{if nl?, do: "processen", else: "processes"})"

    database =
      [
        if(db.ping_ms, do: "#{num(db.ping_ms, 1, nl?)} ms", else: "—"),
        db.size_bytes && mb(db.size_bytes + (db.wal_bytes || 0), nl?)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    slow =
      case db.slow_queries do
        [] ->
          if nl?,
            do: "geen boven #{db.slow_threshold_ms} ms",
            else: "none over #{db.slow_threshold_ms} ms"

        list ->
          Enum.map_join(list, "; ", fn q -> "#{num(q.ms, 0, nl?)} ms #{q.source || "?"}" end)
      end

    sys = s.system

    system =
      "#{os_name(sys.os)} #{sys.os_version}, #{sys.arch}, " <>
        "#{if sys.cores, do: "#{sys.cores} #{if nl?, do: "kernen", else: "cores"}, ", else: ""}" <>
        "OTP #{sys.otp}"

    [
      [l.version, version],
      [l.uptime, duration(s.uptime_s, nl?)],
      [l.cpu, cpu],
      [l.memory, memory],
      [l.database, database],
      [l.slow, slow],
      [l.system, system],
      [l.pages, to_string(app.live_views)],
      [l.tournaments, dash(app.tournaments)],
      [l.boards, dash(app.board_links_online)]
    ]
    |> Enum.map(fn [label, value] -> %{label: label, value: value} end)
  end

  defp os_name("windows"), do: "Windows"
  defp os_name("macos"), do: "macOS"
  defp os_name("linux"), do: "Linux"
  defp os_name(other), do: other

  defp dash(nil), do: "—"
  defp dash(n), do: to_string(n)

  defp mb(nil, _nl?), do: "—"
  defp mb(bytes, nl?), do: "#{num(bytes / @mb, 1, nl?)} MB"

  defp num(value, 0, _nl?), do: value |> round() |> Integer.to_string()

  defp num(value, decimals, nl?) do
    text = :erlang.float_to_binary(value / 1, decimals: decimals)
    if nl?, do: String.replace(text, ".", ","), else: text
  end

  defp duration(seconds, _nl?) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days} d #{hours} h"
      hours > 0 -> "#{hours} h #{minutes} min"
      minutes > 0 -> "#{minutes} min"
      true -> "#{seconds} s"
    end
  end
end
