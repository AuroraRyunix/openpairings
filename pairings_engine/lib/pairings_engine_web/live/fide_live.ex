defmodule PairingsEngineWeb.FideLive do
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.Fide.Sync

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Sync.topic())
    end

    {:ok, assign(socket, page_title: "FIDE database", status: Sync.status())}
  end

  @impl true
  def handle_info({:fide_sync, _state}, socket) do
    {:noreply, assign(socket, status: Sync.status())}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    Sync.start_sync()
    {:noreply, assign(socket, status: Sync.status())}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    Sync.cancel_sync()
    {:noreply, assign(socket, status: Sync.status())}
  end

  defp busy?(%{status: s}), do: s in [:downloading, :importing]

  defp percent(%{status: :downloading, loaded_bytes: loaded, total_bytes: total}) when total > 0 do
    Float.round(loaded / total * 100, 1)
  end

  defp percent(%{status: :importing, imported_rows: done, total_rows: total}) when total > 0 do
    Float.round(done / total * 100, 1)
  end

  defp percent(_), do: nil

  defp format_count(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active="fide">
      <h1>FIDE database</h1>
      <p class="subtitle">
        A local copy of the FIDE rating list, used to look up players when registering them.
      </p>

      <div class="card">
        <p>
          <strong>{format_count(@status.player_count)}</strong> players in the local database.
          <%= if @status.last_sync do %>
            Last updated: <strong>{@status.last_sync}</strong> (UTC).
          <% else %>
            The database is empty — download the rating list to get started.
          <% end %>
        </p>

        <div :if={busy?(@status)} class="progress-block">
          <div class="progress-track">
            <div
              class={["progress-fill", percent(@status) == nil && "indeterminate"]}
              style={percent(@status) && "width: #{percent(@status)}%"}
            />
          </div>
          <p class="ok-note">{if @status.progress != "", do: @status.progress, else: "Working…"}</p>
        </div>
        <p :if={@status.status == :error} class="error-note">
          Update failed: {@status.error}
        </p>

        <p class="hint">
          FIDE publishes a new list every month (~1.9 million players, download is around 41 MB).
          Updating takes a minute or two.
        </p>
        <div class="actions">
          <button class="pe-btn primary" phx-click="sync" disabled={busy?(@status)}>
            {cond do
              busy?(@status) -> "Updating…"
              @status.player_count > 0 -> "Update from FIDE"
              true -> "Download rating list"
            end}
          </button>
          <button :if={busy?(@status)} class="pe-btn" phx-click="cancel">
            Cancel
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
