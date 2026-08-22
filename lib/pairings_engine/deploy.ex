defmodule PairingsEngine.Deploy do
  @moduledoc """
  The "this server is about to restart" notice, announced by the deploy
  script before it restarts the service.

  ## Why the state is in memory, deliberately

  A pending restart is true only of the node that is about to be restarted.
  Holding it in memory means it disappears exactly when it stops being true -
  the process dies with the release it was warning about - so there is no
  stale row to clean up, and a banner can never outlive the restart it
  described. Putting this in the database would create precisely that bug.

  ## Why a stored deadline rather than only a broadcast

  `Phoenix.PubSub` reaches the sockets connected *right now*. An arbiter who
  opens the results page two minutes into a ten-minute countdown would see
  nothing at all, which is the one person the warning exists for. So the
  deadline is held here and read by every mount, and the broadcast only
  exists to update pages that are ALREADY open.

  ## What it must not claim

  Not "you will be logged out". The deploy reuses `SECRET_KEY_BASE` rather
  than regenerating it (docs/deployment.md, step 4) precisely so a restart
  never invalidates sessions. What a restart actually costs is the LiveView
  socket dropping for a few seconds and any unsaved form input going with
  it - which for an arbiter halfway through entering a round's results is
  the real damage. Warning about a logout that cannot happen is how people
  learn to ignore banners.
  """
  use GenServer

  @topic "system:deploy"

  # How long after the deadline the notice clears itself.
  #
  # This is the failure path, not the happy one: if the deploy dies between
  # announcing and restarting - a failed build, a dropped connection, an
  # aborted script - nothing ever restarts this node, and without an expiry
  # the banner would sit at zero forever on every open page. The script is
  # also expected to call `cancel/0` when it aborts, but that only helps
  # when the script is alive to do it.
  @grace_after_deadline_ms :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "PubSub topic carrying `{:deploy_notice, restart_at | nil}`."
  def topic, do: @topic

  @doc """
  Announce a restart `seconds` from now. Returns the deadline.

  Re-announcing replaces the previous deadline, so a script that retries
  does not leave two countdowns racing.
  """
  def announce(seconds) when is_integer(seconds) and seconds > 0 do
    GenServer.call(__MODULE__, {:announce, seconds})
  end

  @doc "Withdraw a pending notice - for a deploy that aborted before restarting."
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "The pending restart time, or nil. Read by every LiveView mount."
  def restart_at, do: GenServer.call(__MODULE__, :restart_at)

  @impl true
  def init(nil), do: {:ok, %{restart_at: nil, timer: nil}}

  @impl true
  def handle_call({:announce, seconds}, _from, state) do
    restart_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    state =
      state
      |> cancel_timer()
      |> Map.put(:restart_at, restart_at)
      |> Map.put(
        :timer,
        Process.send_after(self(), :expire, seconds * 1000 + @grace_after_deadline_ms)
      )

    broadcast(restart_at)
    {:reply, {:ok, restart_at}, state}
  end

  def handle_call(:cancel, _from, state) do
    broadcast(nil)
    {:reply, :ok, %{cancel_timer(state) | restart_at: nil}}
  end

  def handle_call(:restart_at, _from, state), do: {:reply, state.restart_at, state}

  @impl true
  def handle_info(:expire, state) do
    broadcast(nil)
    {:noreply, %{state | restart_at: nil, timer: nil}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp broadcast(restart_at) do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:deploy_notice, restart_at})
  end
end
