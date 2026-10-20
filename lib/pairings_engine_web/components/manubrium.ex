defmodule PairingsEngineWeb.Components.Manubrium do
  @moduledoc """
  The server-rendered shells of Manubrium's phone-side pieces
  (docs/manubrium.md): the outbox, the count in the header, and the incident
  dialog. Each is `phx-update="ignore"`: drawn once here, with its words
  through gettext in `data-t-*` attributes, and kept up to date in the
  browser by `assets/js/manubrium/` - because they have to work while the
  LiveView behind them cannot be reached.
  """
  use PairingsEngineWeb, :html

  alias PairingsEngine.Incidents

  @doc """
  The list of what this phone has sent, is waiting to send, and had
  refused. `standalone` when it is on a page with no LiveView (the code
  page, `/m`), where `app.js` starts it instead of the hook.
  """
  attr :standalone, :boolean, default: false

  def outbox(assigns) do
    ~H"""
    <section
      id="manubrium-outbox"
      class="mq"
      phx-update="ignore"
      hidden
      aria-label={gettext("Sent and waiting")}
      data-standalone={@standalone}
      data-t-board={gettext("Board %{board}", board: "{board}")}
      data-t-waiting={gettext("Waiting")}
      data-t-sending={gettext("Sending")}
      data-t-sent={gettext("Sent")}
      data-t-refused={gettext("Not accepted")}
      data-t-dismiss={gettext("Dismiss")}
      data-t-allsent={gettext("All sent")}
      data-t-waitingcount={gettext("Waiting: %{n}", n: "{n}")}
      data-t-refusedcount={gettext("Not accepted: %{n}", n: "{n}")}
      data-t-problem={
        gettext(
          "The server did not take this page's entries (error %{status}). Reload the page; nothing is lost.",
          status: "{status}"
        )
      }
      data-t-leaveconfirm={
        gettext(
          "%{n} entries on this phone have not reached the server yet. If you leave now they are lost. Leave anyway?",
          n: "{n}"
        )
      }
    >
      <p class="mq-offline" data-mq-offline hidden>
        {gettext("No connection. Results stay on this phone and are sent when the wifi is back.")}
      </p>
      <p class="mq-offline" data-mq-memory hidden>
        {gettext(
          "This browser will not let the page keep entries if it closes. Keep it open until everything is sent."
        )}
      </p>
      <p class="mq-problem" data-mq-problem role="alert" hidden></p>
      <%!-- Not a live region: the header's count is the one that speaks,
            and this list appears inside a section that starts hidden. --%>
      <ul class="mq-list" data-mq-list></ul>
      <button type="button" class="mq-dismiss" data-mq-dismiss-all hidden>
        {gettext("Dismiss all not accepted")}
      </button>
    </section>
    """
  end

  @doc """
  The header's count: all sent, how many wait, how many were refused.
  Empty (and so invisible, by CSS) until the phone has entries; never
  `hidden`, because a status line that is out of the accessibility tree
  when its text arrives is not read out.
  """
  def count(assigns) do
    ~H"""
    <span id="manubrium-count" class="mq-count" data-mq-count phx-update="ignore" role="status"></span>
    """
  end

  @doc """
  The incident dialog, one per page; the hook fills in the board. Offers
  only the kinds `level` may log (`PairingsEngine.Incidents.kinds_for/1`) -
  the server checks again.
  """
  attr :level, :string, required: true

  def incident_dialog(assigns) do
    assigns =
      assign(assigns, kinds: Incidents.kinds_for(assigns.level), max: Incidents.note_max())

    ~H"""
    <dialog
      id="manubrium-incident"
      class="mq-dialog"
      phx-update="ignore"
      aria-labelledby="manubrium-incident-title"
      data-title={gettext("Board %{board}", board: "{board}")}
    >
      <form id="manubrium-incident-form" method="dialog">
        <h2 id="manubrium-incident-title" class="mq-dialog-title">
          <span data-mq-incident-title>{gettext("Incident")}</span>
        </h2>

        <fieldset class="mq-kinds">
          <legend>{gettext("What happened")}</legend>
          <label :for={kind <- @kinds} class="mq-kind">
            <input type="radio" name="type" value={kind} required checked={length(@kinds) == 1} />
            {kind_label(kind)}
          </label>
        </fieldset>

        <label class="mq-note">
          {gettext("Note (optional)")}
          <textarea name="note" rows="3" maxlength={@max}></textarea>
        </label>
        <p class="mq-hint">
          {gettext("No names, please: the board already says who is involved. The time is added.")}
        </p>

        <div class="mq-dialog-actions">
          <button type="button" class="mq-btn" data-mq-cancel>{gettext("Cancel")}</button>
          <button type="submit" class="mq-btn mq-btn--primary">{gettext("Log it")}</button>
        </div>
      </form>
    </dialog>
    """
  end

  @doc "What an incident kind is called, everywhere it is shown."
  def kind_label("illegal_move"), do: gettext("Illegal move")
  def kind_label("clock"), do: gettext("Clock problem")
  def kind_label("device"), do: gettext("Phone or electronic device")
  def kind_label("dispute"), do: gettext("Dispute")
  def kind_label("arbiter_call"), do: gettext("Arbiter call")
  def kind_label("other"), do: gettext("Other")
  def kind_label(kind), do: kind
end
