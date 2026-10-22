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

  require Logger

  alias PairingsEngine.{RatingInbox, Repo, SentReceipts}
  alias PairingsEngine.Tournaments.{SentReceipt, Tournament}
  alias PairingsEngineWeb.Postponed

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Rating inbox"), checks: %{})
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
        # The send (or its tournament) is gone: say so where the answer
        # would have been, instead of a button that does nothing.
        {:noreply, update(socket, :checks, &Map.put(&1, id_int(id), {:error, :send_gone}))}
    end
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, periods: RatingInbox.periods())}

  @impl true
  def handle_async({:check, id}, {:ok, result}, socket),
    do: {:noreply, update(socket, :checks, &Map.put(&1, id, result))}

  def handle_async({:check, id}, {:exit, reason}, socket) do
    Logger.warning("Rating inbox check #{id} crashed: #{inspect(reason)}")
    {:noreply, update(socket, :checks, &Map.put(&1, id, {:error, :crashed}))}
  end

  defp id_int(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp month_id(period), do: Calendar.strftime(period, "%Y-%m")

  # A rating list by the day FIDE publishes it: "1 November 2026". Named by
  # its date and not by "the list of October", which half the readers took
  # for the list published in October.
  defp list_date_text(%Date{} = list),
    do: gettext("1 %{month}", month: Postponed.month_text(list))

  # How a list stands (`RatingInbox.list_status/3`): the words, and the
  # class that colours them.
  defp list_text(%{level: :normal, basis: :interim} = list),
    do:
      gettext(
        "This tournament lasts more than 30 days, so each month's rounds are reported on their own (FIDE B.02, 4.1). These rounds are for the rating list of %{list}: to be uploaded by %{date}.",
        list: list_date_text(list.list),
        date: Postponed.date_text(list.closes)
      )

  defp list_text(%{level: :normal} = list),
    do:
      gettext("For the rating list of %{list}: to be uploaded by %{date}.",
        list: list_date_text(list.list),
        date: Postponed.date_text(list.closes)
      )

  defp list_text(%{level: :later, basis: :interim} = list),
    do:
      gettext(
        "Overdue. This tournament lasts more than 30 days, so each month's rounds are reported on their own (FIDE B.02, 4.1), and these missed the rating list of %{list}. They can still go into the list of %{later}.",
        list: list_date_text(list.list),
        later: list_date_text(list.lands_in)
      )

  defp list_text(%{level: :later} = list),
    do:
      gettext(
        "Missed the rating list of %{list}. It can still go into a later one, the list of %{later} at the earliest; after %{last} it is not rated at all.",
        list: list_date_text(list.list),
        later: list_date_text(list.lands_in),
        last: Postponed.date_text(list.last_chance)
      )

  defp list_text(%{level: :late} = list),
    do:
      gettext(
        "Will not be rated: it missed the rating list of %{last}, the third list after its last day.",
        last: list_date_text(list.last_list)
      )

  defp level_class(:later), do: "is-later"
  defp level_class(:late), do: "is-late"
  defp level_class(_), do: nil

  defp level_badge(:later), do: gettext("overdue")
  defp level_badge(:late), do: gettext("too late")

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

  defp error_text(:send_gone),
    do: gettext("This send no longer exists - press Refresh.")

  defp error_text(other) do
    Logger.warning("Rating inbox: unexpected check error #{inspect(other)}")
    gettext("The check could not be run.")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active="admin"
    >
      <div class="page-header rinbox-header">
        <div>
          <h1>{gettext("Rating inbox")}</h1>

          <p class="subtitle" style="margin: 0">
            {gettext("What was sent for rating, and what still has to come, per rating period")}
          </p>
        </div>

        <div class="actions" style="margin-top: 0">
          <button type="button" id="rating-inbox-refresh" class="pe-btn" phx-click="refresh">
            {gettext("Refresh")}
          </button>

          <.link id="rating-inbox-back" navigate={~p"/admin"} class="pe-btn">
            {gettext("Admin")}
          </.link>
        </div>
      </div>

      <p class="hint rinbox-intro" id="rating-inbox-intro">
        {gettext(
          "Listed here: every tournament from which a round was sent for rating, and every tournament marked FIDE-homologated (Settings, FIDE). A round counts for the month of its date."
        )} {gettext(
          "\"Sent\" means the arbiter pressed Send and the file was downloaded to their computer. Whether they then mailed it to you is something this page cannot know: the download here is that same file, in case it never arrived."
        )}
      </p>

      <p :if={@periods == []} id="rating-inbox-empty" class="hint rinbox-intro">
        {gettext(
          "Nothing here yet. A tournament appears once a round of it has been sent for rating, or once it is marked FIDE-homologated and has a finished round."
        )}
      </p>

      <section
        :for={p <- @periods}
        id={"rating-inbox-period-#{month_id(p.period)}"}
        class={["set-card", "rinbox-period", level_class(p.level)]}
        data-level={p.level}
      >
        <h2>
          {Postponed.month_text(p.period)}
          <span :if={p.overdue?} class={["badge", "rinbox-level", level_class(p.level)]}>
            {level_badge(p.level)}
          </span>
        </h2>

        <article
          :for={b <- p.tournaments}
          id={"rating-inbox-#{month_id(p.period)}-t#{b.tournament.id}"}
          class="rinbox-t"
        >
          <h3 class="rinbox-t-name">
            <.link navigate={~p"/t/#{b.tournament.id}/settings/export"}>{b.tournament.name}</.link>
            <span
              :if={not RatingInbox.rated?(b.tournament)}
              id={"rating-inbox-unrated-#{b.tournament.id}-#{month_id(p.period)}"}
              class="badge muted"
            >
              {gettext("not marked FIDE-homologated")}
            </span>
          </h3>

          <p
            :if={not RatingInbox.rated?(b.tournament)}
            class="rinbox-note"
          >
            {gettext(
              "Listed because a round of it was sent. It is not marked FIDE-homologated, so no report is expected for its other rounds and no rating list applies."
            )}
          </p>

          <p
            :if={b.missing != [] and b.report_list}
            id={"rating-inbox-list-#{b.tournament.id}-#{month_id(p.period)}"}
            class={["rinbox-note", level_class(b.report_list.level)]}
            data-level={b.report_list.level}
            data-basis={b.report_list.basis}
          >
            {list_text(b.report_list)}
          </p>

          <p
            :if={b.open != [] and b.open_list}
            id={"rating-inbox-open-list-#{b.tournament.id}-#{month_id(p.period)}"}
            class={["rinbox-note", level_class(b.open_list.level)]}
            data-level={b.open_list.level}
          >
            <strong>{gettext("Postponed-games file")}:</strong> {list_text(b.open_list)}
          </p>

          <ul :if={b.sent != []} class="rinbox-receipts">
            <li :for={s <- b.sent} id={"rating-inbox-receipt-#{s.receipt.id}"} class="rinbox-receipt">
              <div class="rinbox-receipt-main">
                <span title={PairingsEngineWeb.SentReceipt.stamp_title(s.receipt)}>
                  {PairingsEngineWeb.SentReceipt.stamp_text(s.receipt)}
                </span>

                <span :if={s.receipt.kind == "postponed"} class="badge muted">
                  {gettext("postponed games")}
                </span>

                <span
                  :if={s.changes != []}
                  id={"rating-inbox-drift-#{s.receipt.id}"}
                  class="badge rinbox-drift"
                >
                  {PairingsEngineWeb.SentReceipt.drift_title(s.receipt)}
                </span>

                <span class="rinbox-receipt-file">
                  <%= cond do %>
                    <% SentReceipts.file?(s.receipt) -> %>
                      <span title={s.receipt.file_name}>{gettext("file as sent")}</span>
                    <% s.receipt.kind == "report" -> %>
                      {gettext("rebuilt copy")}
                    <% true -> %>
                      {gettext("no file kept")}
                  <% end %>
                  ·
                  <span title={s.receipt.final_sha256}>
                    {if s.receipt.final_sha256,
                      do: String.slice(s.receipt.final_sha256, 0, 12),
                      else: gettext("no hash on record")}
                  </span>
                </span>
              </div>

              <div
                :if={s.receipt.kind == "report" or SentReceipts.file?(s.receipt)}
                class="rinbox-receipt-actions"
              >
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

              <div
                :if={@checks[s.receipt.id] not in [nil, :running]}
                id={"rating-inbox-result-#{s.receipt.id}"}
                class="rinbox-check"
                role="status"
              >
                <%= case @checks[s.receipt.id] do %>
                  <% {:error, reason} -> %>
                    <strong>{error_text(reason)}</strong>
                  <% %{status: status, output: output} -> %>
                    <strong>{check_label(status)}</strong> <pre :if={String.trim(output) != ""}>{output}</pre>
                <% end %>
              </div>
            </li>
          </ul>

          <p
            :if={b.missing != []}
            id={"rating-inbox-missing-#{b.tournament.id}-#{month_id(p.period)}"}
            class="rinbox-line"
          >
            <strong>{gettext("Not sent yet:")}</strong> {ngettext(
              "round %{rounds} has finished and has no receipt.",
              "rounds %{rounds} have finished and have no receipt.",
              length(b.missing),
              rounds: Enum.join(b.missing, ", ")
            )}
          </p>

          <p
            :if={b.open != []}
            id={"rating-inbox-open-#{b.tournament.id}-#{month_id(p.period)}"}
            class="rinbox-line"
          >
            <strong>
              {ngettext(
                "%{count} postponed game still open:",
                "%{count} postponed games still open:",
                length(b.open)
              )}
            </strong>
            {Enum.map_join(b.open, "; ", fn g ->
              gettext("round %{round}, board %{board}",
                round: g.round,
                board: g.pairing.display_board || g.pairing.board
              )
            end)}
          </p>
        </article>
      </section>
    </Layouts.app>
    """
  end
end
