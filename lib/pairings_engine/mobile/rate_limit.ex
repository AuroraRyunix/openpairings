defmodule PairingsEngine.Mobile.RateLimit do
  @moduledoc """
  Per-IP throttle for the mobile enrollment code-entry endpoint. The numeric
  code is short, so wrong guesses are counted and, past `@max_attempts` inside
  a rolling window, further attempts from that IP are blocked — making a
  brute-force of the 6-digit space infeasible. A successful enrollment clears
  the IP's counter. Owns a `:public` ETS table (same pattern as
  `PairingsEngine.Tools.Session`), swept periodically.
  """
  use GenServer

  @table __MODULE__
  @window_ms :timer.minutes(10)
  @max_attempts 8
  @sweep_ms :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "True if `ip` may still attempt a code (under the failure cap in the window)."
  def allow?(ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, ip) do
      [{^ip, count, ts}] -> now - ts >= @window_ms or count < @max_attempts
      [] -> true
    end
  end

  @doc "Records a wrong-code attempt from `ip`."
  def record_failure(ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, ip) do
      [{^ip, count, ts}] when now - ts < @window_ms -> :ets.insert(@table, {ip, count + 1, ts})
      _ -> :ets.insert(@table, {ip, 1, now})
    end

    :ok
  end

  @doc "Clears `ip`'s counter after a successful enrollment."
  def clear(ip) do
    :ets.delete(@table, ip)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
