defmodule PairingsEngineWeb.RatingInboxLive do
  @moduledoc """
  The rating period inbox (`PairingsEngine.RatingInbox`): per FIDE rating
  period, what was sent for rating, what is missing, which postponed games
  are open and the deadline - for every tournament of this installation, so
  it is administrators only (`live_session :administration`).

  A sent round can be downloaded as a TRF copy and checked with Ainalrami's
  checker. The check replays every round up to it, which takes a while on a
  large tournament, so it runs with `start_async/3` and the page stays
  usable.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{RatingInbox, Repo}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}
  alias PairingsEngineWeb.Postponed

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Rating period inbox"), checks: %{})
     |> assign(periods: RatingInbox.periods())}
  end

  @impl true
  def handle_event("check", %{"id" => id}, socket) do
    with {int, ""} <- Integer.parse(id),
         %SentReceipt{kind: "report"} = receipt <- Repo.get(SentReceipt, int),
         %Tournament{deleted_at: nil} = tournament <- Repo.get(Tournament, receipt.tournament_id),
         {:ok, text} <- RatingInbox.trf_copy(tournament, receipt, :through) do
      {:noreply,
       socket
       |> update(:checks, &Map.put(&1, int, :running))
       |> start_async({:check, int}, fn -> RatingInbox.check(text) end)}
    else
      {:error, reason} ->
        {:noreply, update(socket, :checks, &Map.put(&1, id_int(id), {:error, reason}))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, periods: RatingInbox.periods())}

  @impl true
  def handle_async({:check, id}, {:ok, result}, socket),
    do: {:noreply, update(socket, :checks, &Map.put(&1, id, result))}

  def handle_async({:check, id}, {:exit, reason}, socket),
    do: {:noreply, update(socket, :checks, &Map.put(&1, id, {:error, inspect(reason)}))}

  defp id_int(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp month_id(period), do: Calendar.strftime(period, "%Y-%m")

  defp check_label(:match), do: gettext("Every round matches the checker's own pairing.")
  defp check_label(:differs), do: gettext("Differs from the checker's pairing or standings.")

  defp check_label(:not_replayed),
    do: gettext("Not replayed: the checker does not replay this pairing system.")

  defp check_label(:error), do: gettext("The checker could not read the file.")

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(:no_copy), do: gettext("There is no copy of this file to check.")
  defp error_text(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active="admin"
    >
      <h1>{gettext("Rating period inbox")}</h1>

      <p class="hint" id="rating-inbox-intro">
        {gettext(
          "Every tournament on this installation, by FIDE rating period: what was sent for rating, what is missing, which postponed games are still open, and the deadline. A round counts for the month of its date. The file that was sent is not kept, so a download is a copy rebuilt from the tournament as it is now."
        )}
      </p>

      <div class="actions">
        <button type="button" id="rating-inbox-refresh" class="pe-btn" phx-click="refresh">
          {gettext("Refresh")}
        </button>
        <.link id="rating-inbox-back" navigate={~p"/admin"} class="pe-btn">
          {gettext("Admin")}
        </.link>
      </div>

      <p :if={@periods == []} id="rating-inbox-empty" class="hint">
        {gettext("Nothing sent, missing or open yet.")}
      </p>

      <div
        :for={p <- @periods}
        id={"rating-inbox-period-#{month_id(p.period)}"}
        class="set-card"
        style={p.overdue? && "border-color: var(--warn)"}
      >
        <h2>{Postponed.month_text(p.period)}</h2>
        <p class="hint">
          {gettext("Deadline %{date}.", date: Postponed.date_text(p.deadline))}
          <strong :if={p.overdue?}>
            {gettext("Past the deadline, with rounds or postponed games still to send.")}
          </strong>
        </p>

        <div
          :for={b <- p.tournaments}
          id={"rating-inbox-#{month_id(p.period)}-t#{b.tournament.id}"}
          style="margin-top: 12px"
        >
          <h3>
            <.link navigate={~p"/t/#{b.tournament.id}/settings/export"}>{b.tournament.name}</.link>
          </h3>

          <table :if={b.sent != []} class="pe-table">
            <thead>
              <tr>
                <th>{gettext("Sent")}</th>
                <th>{gettext("File")}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <%= for s <- b.sent do %>
                <tr id={"rating-inbox-receipt-#{s.receipt.id}"}>
                  <td>
                    <span title={PairingsEngineWeb.SentReceipt.stamp_title(s.receipt)}>
                      {PairingsEngineWeb.SentReceipt.stamp_text(s.receipt)}
                    </span>
                    <span :if={s.receipt.kind == "postponed"} class="hint">
                      · {gettext("postponed games")}
                    </span>
                    <span
                      :if={s.changes != []}
                      id={"rating-inbox-drift-#{s.receipt.id}"}
                      class="badge"
                      style="color: var(--warn)"
                    >
                      {PairingsEngineWeb.SentReceipt.drift_title(s.receipt)}
                    </span>
                  </td>
                  <td>
                    <span class="hint" title={s.receipt.final_sha256}>
                      {if s.receipt.final_sha256,
                        do: String.slice(s.receipt.final_sha256, 0, 12),
                        else: gettext("no hash on record")}
                    </span>
                  </td>
                  <td class="num">
                    <div :if={s.receipt.kind == "report"} class="actions">
                      <a
                        id={"rating-inbox-download-#{s.receipt.id}"}
                        class="pe-btn"
                        href={~p"/admin/rating-inbox/receipts/#{s.receipt.id}/trf"}
                      >
                        {gettext("Download TRF copy")}
                      </a>
                      <button
                        type="button"
                        id={"rating-inbox-check-#{s.receipt.id}"}
                        class="pe-btn"
                        phx-click="check"
                        phx-value-id={s.receipt.id}
                        disabled={@checks[s.receipt.id] == :running}
                      >
                        {if @checks[s.receipt.id] == :running,
                          do: gettext("Checking…"),
                          else: gettext("Check")}
                      </button>
                    </div>
                  </td>
                </tr>
                <tr
                  :if={@checks[s.receipt.id] not in [nil, :running]}
                  id={"rating-inbox-result-#{s.receipt.id}"}
                >
                  <td colspan="3">
                    <%= case @checks[s.receipt.id] do %>
                      <% {:error, reason} -> %>
                        <strong>{error_text(reason)}</strong>
                      <% %{status: status, output: output} -> %>
                        <strong>{check_label(status)}</strong>
                        <pre class="hint" style="white-space: pre-wrap">{output}</pre>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <p
            :if={b.missing != []}
            id={"rating-inbox-missing-#{b.tournament.id}-#{month_id(p.period)}"}
          >
            <strong>{gettext("Missing")}:</strong>
            {ngettext(
              "round %{rounds} finished, no receipt.",
              "rounds %{rounds} finished, no receipt.",
              length(b.missing),
              rounds: Enum.join(b.missing, ", ")
            )}
          </p>

          <div
            :if={b.open != []}
            id={"rating-inbox-open-#{b.tournament.id}-#{month_id(p.period)}"}
          >
            <strong>
              {ngettext(
                "%{count} postponed game still open:",
                "%{count} postponed games still open:",
                length(b.open)
              )}
            </strong>
            <span :for={g <- b.open} class="hint">
              {gettext("round %{round}, board %{board}", round: g.round, board: g.pairing.board)};
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
