defmodule PairingsEngineWeb.RatingInboxLive do
  @moduledoc """
  The rating period inbox (`PairingsEngine.RatingInbox`): per FIDE rating
  period, what was sent for rating, what is missing, which postponed games
  are open and the deadline - for every tournament of this installation, so
  it is administrators only (`live_session :administration`).

  A send can be downloaded - the exact file that was sent, or for an older
  round (sent before files were kept) a rebuilt copy, labelled as one - and
  checked with Ainalrami's checker. The check replays every round up to it, which takes a while on a
  large tournament, so it runs with `start_async/3` and the page stays
  usable.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{RatingInbox, Repo, SentReceipts}
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
         %SentReceipt{} = receipt <- Repo.get(SentReceipt, int),
         %Tournament{deleted_at: nil} = tournament <- Repo.get(Tournament, receipt.tournament_id),
         {:ok, text, _kind} <- RatingInbox.file_for(tournament, receipt, :through) do
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

  # How a list stands (`RatingInbox.list_status/2`): the words, and the
  # colour that goes with the level.
  defp list_text(%{level: :normal} = list),
    do:
      gettext("Goes to the list of %{month}: send it before %{date}.",
        month: Postponed.month_text(list.target),
        date: Postponed.date_text(list.closes)
      )

  defp list_text(%{level: :later} = list),
    do:
      gettext(
        "Past the list of %{month}: it goes to a later list now, the list of %{later} at the earliest, and is not rated at all if it misses the list of %{last}.",
        month: Postponed.month_text(list.target),
        later: Postponed.month_text(list.lands_in),
        last: Postponed.month_text(Date.beginning_of_month(list.last_chance))
      )

  defp list_text(%{level: :late} = list),
    do:
      gettext(
        "Will not be rated: it missed the list of %{last}, the third list after the tournament ended.",
        last: Postponed.month_text(Date.beginning_of_month(list.last_chance))
      )

  defp list_style(%{level: :later}), do: "color: var(--warn)"
  defp list_style(%{level: :late}), do: "color: var(--danger)"
  defp list_style(_), do: nil

  defp period_style(:later), do: "border-color: var(--warn)"
  defp period_style(:late), do: "border-color: var(--danger)"
  defp period_style(_), do: nil

  defp check_label(:match), do: gettext("Every round matches the checker's own pairing.")
  defp check_label(:differs), do: gettext("Differs from the checker's pairing or standings.")

  defp check_label(:not_replayed),
    do: gettext("Not replayed: the checker does not replay this pairing system.")

  defp check_label(:error), do: gettext("The checker could not read the file.")

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(:no_copy), do: gettext("There is no copy of this file to check.")

  defp error_text(:open_postponed),
    do:
      gettext(
        "No copy: the tournament is in FIDE mode and a postponed game in it has no result, so no TRF of it is made."
      )

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
          "Every tournament on this installation, by FIDE rating period: what was sent for rating, what is missing, which postponed games are still open, and which rating list each goes to. A round counts for the month of its date. A download is the exact file that was sent; a send from before files were kept can only be offered as a copy rebuilt from the tournament as it is now. Nothing here is refused: a late report is still sent, and the list it will make is shown."
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
        data-level={p.level}
        style={period_style(p.level)}
      >
        <h2>{Postponed.month_text(p.period)}</h2>

        <div
          :for={b <- p.tournaments}
          id={"rating-inbox-#{month_id(p.period)}-t#{b.tournament.id}"}
          style="margin-top: 12px"
        >
          <h3>
            <.link navigate={~p"/t/#{b.tournament.id}/settings/export"}>{b.tournament.name}</.link>
          </h3>

          <p
            :if={b.missing != [] and b.report_list}
            id={"rating-inbox-list-#{b.tournament.id}-#{month_id(p.period)}"}
            class="hint"
            data-level={b.report_list.level}
            style={list_style(b.report_list)}
          >
            {list_text(b.report_list)}
          </p>
          <p
            :if={b.open != [] and b.open_list}
            id={"rating-inbox-open-list-#{b.tournament.id}-#{month_id(p.period)}"}
            class="hint"
            data-level={b.open_list.level}
            style={list_style(b.open_list)}
          >
            <strong>{gettext("Postponed-games file")}:</strong> {list_text(b.open_list)}
          </p>

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
                    <div
                      :if={s.receipt.kind == "report" or SentReceipts.file?(s.receipt)}
                      class="actions"
                    >
                      <span
                        :if={SentReceipts.file?(s.receipt)}
                        class="hint"
                        title={s.receipt.file_name}
                      >
                        {gettext("file as sent")}
                      </span>
                      <span :if={not SentReceipts.file?(s.receipt)} class="hint">
                        {gettext("rebuilt copy")}
                      </span>
                      <a
                        id={"rating-inbox-download-#{s.receipt.id}"}
                        class="pe-btn"
                        href={~p"/admin/rating-inbox/receipts/#{s.receipt.id}/trf"}
                      >
                        {if SentReceipts.file?(s.receipt),
                          do: gettext("Download file"),
                          else: gettext("Download TRF copy")}
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
