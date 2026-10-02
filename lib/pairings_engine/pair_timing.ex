defmodule PairingsEngine.PairTiming do
  @moduledoc """
  Where the "Pair round" click spends its time.

  Every stage between the arbiter's click and the Pairings page coming back
  is wrapped in a telemetry span, `[:pairings_engine, :pair_click, stage]`
  (`:start` / `:stop` / `:exception`, the standard `:telemetry.span/3`
  shape, `duration` in native time units). With nothing attached a span is
  two handler-table lookups - nothing anyone could measure next to a
  pairing - so the spans are always there and nothing is ever logged unless
  asked for.

  To see them, set `PAIR_TIMING=1` in the environment (or
  `config :pairings_engine, :pair_timing, true`): the application then
  attaches `log_handler/4` at boot and every stage is logged at info level,
  one line each, as `pair timing: <stage> <ms> ms`.

  The stages, in click order (`PairingsEngineWeb.PairingsLive` and
  `PairingsEngine.Pairing`):

    * `:click` - the whole `"pair"` event handler, every stage below
    * `:snapshot` - the restore point taken before pairing (`Snapshots`)
    * `:pair` - `Pairing.pair_next_round/2`, made of
      * `:warnings` - the postponed-game checks
      * `:load` - the roster, the round counts, the tournament's history
      * `:input` - the engine's input: the TRF and the arbiter's wishes
      * `:engine` - the engine call itself
      * `:save` - the round, its boards and its bye rows, one transaction
      * `:deviations` - the FIDE-compliance stamp
      * `:broadcast` - telling open pages, and queueing the public page
      * `:status` - the tournament's derived status
      * `:explanation` - handing the account to its background job
    * `:audit` - the audit trail's rows for the round
    * `:refresh` - reloading everything the page shows

  and, after the page is back, `:echo` - the same LiveView handling its own
  click's broadcast, which it receives like every other open page. It
  reloads (a `:refresh` inside the `:echo`) only when something changed
  since the click's own `:refresh`.

  The LiveView's own render and diff are Phoenix's
  `[:phoenix, :live_view, :render]` span; `test/bench/pair_click_stages_bench_test.exs`
  puts all of them side by side, with what runs in the background.
  """

  require Logger

  @prefix [:pairings_engine, :pair_click]
  @handler "pairings-engine-pair-timing"

  @stages ~w(click snapshot pair warnings load input engine save deviations broadcast status explanation audit refresh echo)a

  @doc "The stages, for whoever attaches to them."
  def stages, do: @stages

  @doc "The telemetry event prefix: `[:pairings_engine, :pair_click]`."
  def prefix, do: @prefix

  @doc """
  Runs `fun` inside the `stage` span and returns what it returned.
  """
  def span(stage, fun) when stage in @stages and is_function(fun, 0) do
    :telemetry.span(@prefix ++ [stage], %{}, fn -> {fun.(), %{}} end)
  end

  @doc """
  Attaches the log handler when `PAIR_TIMING` is set or `:pair_timing` is
  configured on. Called once at boot; a no-op otherwise.
  """
  def maybe_attach do
    if enabled?(), do: attach(), else: :ok
  end

  @doc false
  def enabled? do
    Application.get_env(:pairings_engine, :pair_timing, false) == true or
      System.get_env("PAIR_TIMING") in ["1", "true"]
  end

  @doc "Attaches the log handler to every stage's `:stop` event."
  def attach do
    events = for stage <- @stages, do: @prefix ++ [stage, :stop]

    case :telemetry.attach_many(@handler, events, &__MODULE__.log_handler/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the log handler."
  def detach, do: :telemetry.detach(@handler)

  @doc false
  def log_handler([:pairings_engine, :pair_click, stage, :stop], %{duration: duration}, _meta, _) do
    Logger.info("pair timing: #{stage} #{format_ms(duration)} ms")
  end

  @doc "A native-unit duration in milliseconds, one decimal."
  def format_ms(duration) do
    ms = System.convert_time_unit(duration, :native, :microsecond) / 1000
    :erlang.float_to_binary(ms, decimals: 1)
  end
end
