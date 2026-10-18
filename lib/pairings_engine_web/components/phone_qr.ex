defmodule PairingsEngineWeb.Components.PhoneQr do
  @moduledoc """
  The "Phone QR" dialog of the Pairings page: every QR code the arbiter may
  want to hold up for a phone, large enough to scan across a table, each with
  its address in words and a label for what it opens.

  It used to live at the bottom of the local view, where it was one more thing
  on a page meant for a projector. The local view is for the hall now; this is
  for the arbiter's own screen, shown for as long as it takes to scan.

  The events (`phone_qr_open`, `phone_qr_close`, `generate_enrollment`,
  `revoke_enrollment`) are handled by `PairingsEngineWeb.PairingsLive`; this
  module is the markup and the small helpers that turn form params and
  enrolments into text.
  """
  use PairingsEngineWeb, :html

  alias PairingsEngine.Mobile
  alias PairingsEngineWeb.PublicLink

  attr :tournament, :map, required: true
  attr :new_enrollment, :map, default: nil
  attr :enrollments, :list, default: []
  attr :local_mode?, :boolean, default: false

  def phone_qr_dialog(assigns) do
    assigns = assign(assigns, :public_url, PublicLink.url(assigns.tournament, :pairings))

    ~H"""
    <div class="pe-modal" id="phone-qr-modal" phx-window-keydown="phone_qr_close" phx-key="escape">
      <div
        class="pe-modal-card pe-modal-wide"
        phx-click-away="phone_qr_close"
        id="phone-qr-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="phone-qr-title"
        tabindex="-1"
        phx-hook="DialogFocus"
        data-dialog
      >
        <header class="pe-modal-head">
          <h2 id="phone-qr-title">{gettext("Phone QR")}</h2>

          <p>{gettext("Hold the screen up, or turn it round, and let the phone scan.")}</p>
        </header>

        <div class="pe-modal-body">
          <%!-- The public page, for a tournament that has one. --%>
          <section :if={@public_url} id="phone-qr-public" class="phone-qr-block">
            <h3>{gettext("Results page")}</h3>

            <.big_qr
              id="phone-qr-public-code"
              url={@public_url}
              label={gettext("QR code for the public results page")}
            />
            <p class="phone-qr-url" id="phone-qr-public-url">{@public_url}</p>

            <p class="hint">
              {gettext("Opens the pairings and results for anyone, no login needed.")}
            </p>
          </section>

          <%!-- Not offered on a local run, because it cannot work there and
                looks like it can: the QR would encode "localhost", which a
                phone resolves to itself, and the listener only answers the
                machine it runs on (that is what keeps a no-login build safe).
                `Mobile.create_enrollment/2` refuses too; this just says so. --%>
          <section :if={@local_mode?} id="phone-qr-enroll-unavailable" class="phone-qr-block">
            <h3>{gettext("Enter results on a phone")}</h3>

            <p class="hint">
              {gettext(
                "Not available when OpenPairings runs on your own computer. This machine only accepts connections from itself - which is what keeps a no-login build safe - so a phone cannot reach it, and the QR code would point the phone at itself. Helpers can enter results from a phone when a tournament runs on a shared server."
              )}
            </p>
          </section>

          <section :if={not @local_mode?} id="phone-qr-enroll" class="phone-qr-block">
            <h3>{gettext("Enter results on a phone")}</h3>

            <p class="hint">
              {gettext(
                "Let helpers enter results from their phone, no account needed. Show them the QR code or the 8-digit code. Access is result-entry only, scoped to this tournament, and you can revoke it any time."
              )}
            </p>

            <%!-- Level and board range travel WITH the code from the moment it
                  is minted; there is no "edit an enrolment" screen. Name
                  first, and optional: an arbiter mid-round must be able to
                  mint a code with one tap. --%>
            <form id="phone-qr-enroll-form" phx-submit="generate_enrollment" class="phone-qr-form">
              <label>
                {gettext("Name (optional)")}
                <input
                  type="text"
                  name="label"
                  class="pe-input"
                  maxlength="60"
                  placeholder={gettext("Anke, Board 1-10 helper")}
                />
              </label>

              <label>
                {gettext("Access level")}
                <select name="level" class="pe-select">
                  <option value="helper">{gettext("Helper - fill blanks, latest round only")}</option>

                  <option value="deputy">{gettext("Deputy - enter and correct, any round")}</option>
                </select>
              </label>

              <label>
                {gettext("Boards (optional)")}
                <span style="display: flex; gap: 4px; align-items: center">
                  <input
                    type="number"
                    min="1"
                    name="board_from"
                    class="pe-input"
                    style="width: 64px"
                    placeholder={gettext("from")}
                  /> <span aria-hidden="true">–</span>
                  <input
                    type="number"
                    min="1"
                    name="board_to"
                    class="pe-input"
                    style="width: 64px"
                    placeholder={gettext("to")}
                  />
                </span>
              </label>
              <button class="pe-btn primary" type="submit">{gettext("Generate a code")}</button>
            </form>

            <div :if={@new_enrollment} id="phone-qr-new-enrollment" class="phone-qr-new">
              <.big_qr
                id="phone-qr-enroll-code"
                url={url(~p"/m/e/#{@new_enrollment.token}")}
                label={gettext("QR code for entering results on a phone")}
              />

              <div>
                <div :if={@new_enrollment.label != ""} class="enroll-name">
                  {@new_enrollment.label}
                </div>

                <div class="enroll-code-label">{gettext("8-digit code")}</div>

                <div class="enroll-code">{@new_enrollment.code}</div>

                <p class="phone-qr-url" id="phone-qr-enroll-url">
                  {url(~p"/m/e/#{@new_enrollment.token}")}
                </p>

                <p class="enroll-url">
                  <.rich_text text={
                    gettext("Scan the QR, or open %[url] on the phone and enter the code.")
                  }>
                    <:part name="url"><strong>{url(~p"/m")}</strong></:part>
                  </.rich_text>
                </p>

                <p class="hint">{enrollment_scope_label(@new_enrollment)}</p>

                <p class="hint">
                  {gettext("Expires %{when}.", when: enroll_expiry(@new_enrollment.expires_at))}
                </p>
              </div>
            </div>

            <div :if={@enrollments != []} id="phone-qr-enrollments" style="margin-top: 18px">
              <h4 style="margin: 0 0 8px; font-size: 14px">{gettext("Active phones")}</h4>

              <table class="pe-table" role="presentation">
                <tbody>
                  <tr :for={e <- @enrollments}>
                    <td><strong>{enrollment_name_label(e)}</strong></td>

                    <td class="hint">{gettext("Code %{code}", code: e.code)}</td>

                    <td class="hint">{enrollment_scope_label(e)}</td>

                    <td class="hint">{claim_status_label(e)}</td>

                    <td class="hint">
                      {gettext("expires %{when}", when: enroll_expiry(e.expires_at))}
                    </td>

                    <td style="text-align: right">
                      <button
                        class="pe-btn danger-link"
                        phx-click="revoke_enrollment"
                        phx-value-id={e.id}
                      >
                        {gettext("Revoke")}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>

        <footer class="pe-modal-foot">
          <button type="button" id="phone-qr-close" class="pe-btn" phx-click="phone_qr_close">
            {gettext("Close")}
          </button>
        </footer>
      </div>
    </div>
    """
  end

  # A QR code as one image with a name, rather than a raw SVG of a few hundred
  # unnamed squares. The address it encodes is printed beside it, so the name
  # says what it is for, not the address.
  attr :id, :string, required: true
  attr :url, :string, required: true
  attr :label, :string, required: true

  defp big_qr(assigns) do
    ~H"""
    <div class="enroll-qr phone-qr-big" id={@id}>
      <div class="enroll-qr-inner" role="img" aria-label={@label}>
        {Phoenix.HTML.raw(
          String.replace(Mobile.qr_svg(@url), "<svg", ~s(<svg aria-hidden="true"), global: false)
        )}
      </div>
    </div>
    """
  end

  def enroll_expiry(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %H:%M")

  defp enrollment_level_label("deputy"), do: gettext("Deputy")
  defp enrollment_level_label(_helper), do: gettext("Helper")

  defp board_range_label(nil, nil), do: nil
  defp board_range_label(from, nil), do: gettext("Boards %{from}+", from: from)
  defp board_range_label(nil, to), do: gettext("Boards up to %{to}", to: to)
  defp board_range_label(from, to), do: gettext("Boards %{from}-%{to}", from: from, to: to)

  # "Boards 1-10 · Helper" rather than a bare token id: one enrolment can be
  # used by unlimited phones, so this line is the audit trail for what the
  # CODE may do.
  defp enrollment_scope_label(e) do
    level = enrollment_level_label(e.level)

    case board_range_label(e.board_from, e.board_to) do
      nil -> level
      range -> gettext("%{range} · %{level}", range: range, level: level)
    end
  end

  defp enrollment_name_label(%Mobile.Enrollment{label: ""}), do: gettext("No name given")
  defp enrollment_name_label(%Mobile.Enrollment{label: label}), do: label

  # "Not used yet" versus claimed-and-when. `claimed_at` only ever moves
  # nil -> a timestamp, so there is no third state.
  defp claim_status_label(%Mobile.Enrollment{claimed_at: nil}), do: gettext("Not used yet")

  defp claim_status_label(%Mobile.Enrollment{claimed_at: %DateTime{} = claimed_at}),
    do: gettext("Claimed %{when}", when: enroll_expiry(claimed_at))

  # Blank stays "no restriction" rather than an error; so does anything that
  # does not parse as an integer. `Mobile.create_enrollment/2`'s own
  # validation guards the range that does get set.
  defp parse_board(nil), do: nil
  defp parse_board(""), do: nil

  defp parse_board(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  @doc "The options for `Mobile.create_enrollment/2`, from the form's params."
  def enrollment_opts(params) do
    [
      label: params |> Map.get("label", "") |> to_string() |> String.trim(),
      level: Map.get(params, "level", "helper"),
      board_from: parse_board(params["board_from"]),
      board_to: parse_board(params["board_to"])
    ]
  end

  @doc "What to tell the arbiter when minting failed on the changeset."
  def enrollment_changeset_error(%Ecto.Changeset{} = changeset) do
    if changeset.errors[:board_from] || changeset.errors[:board_to] do
      gettext(
        "Board range is invalid - \"to\" must be at least \"from\", and both must be 1 or higher."
      )
    else
      gettext("Could not enrol a phone - please retry.")
    end
  end
end
