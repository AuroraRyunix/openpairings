defmodule PairingsEngineWeb.BoardConnectHTML do
  @moduledoc "The board connect consent page (see `PairingsEngineWeb.BoardConnectController`)."
  use PairingsEngineWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="board-connect">
        <section class="set-card board-connect-card" id="board-connect">
          <span class="board-connect-icon" aria-hidden="true">
            <.icon name="hero-signal" class="size-6" />
          </span>
          <h1>{gettext("Connect a board box")}</h1>

          <p class="board-connect-box" id="board-connect-box">
            <%= if @request.box do %>
              {gettext("%{box} asks to read your tournaments.", box: @request.box)}
            <% else %>
              {gettext("A board box asks to read your tournaments.")}
            <% end %>
          </p>

          <p class="hint">{gettext("If you allow it, you will be sent to:")}</p>
          <p class="board-connect-host" id="board-connect-host">{@request.host}</p>
          <p :if={!@request.secure?} class="setting-warning" id="board-connect-plain">
            {gettext(
              "This address is plain http. That is normal for a box on this computer or in the hall, and nowhere else."
            )}
          </p>

          <ul class="board-connect-what">
            <li>
              {gettext(
                "It sees every tournament you may edit that is current: not finished, or finished within the last %{days} days. One you lose access to, or archive, drops off at once.",
                days: PairingsEngine.BoardLink.finished_days()
              )}
            </li>
            <li>
              {gettext(
                "What its boards see is shown beside the pairings. A board never enters a result; you still do."
              )}
            </li>
            <li>
              {gettext("You can withdraw it at any time on your account page, under Live boards.")}
            </li>
          </ul>

          <p :if={@codes >= @max} class="setting-warning" id="board-connect-full">
            {gettext(
              "Your account already has %{max} board boxes connected. Withdraw one on your account page first.",
              max: @max
            )}
          </p>

          <p class="hint" id="board-connect-not-you">
            {gettext("Did not ask for this yourself? Cancel.")}
          </p>

          <form
            method="post"
            action={~p"/boards/connect"}
            id="board-connect-form"
            class="board-connect-actions"
          >
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input type="hidden" name="return_to" value={@request.return_to} />
            <input type="hidden" name="state" value={@request.state} />
            <input :if={@request.box} type="hidden" name="box" value={@request.box} />
            <button
              type="submit"
              name="decision"
              value="deny"
              class="pe-btn"
              id="board-connect-cancel"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              name="decision"
              value="allow"
              class="pe-btn primary"
              id="board-connect-allow"
              disabled={@codes >= @max}
            >
              {gettext("Allow")}
            </button>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def invalid(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="board-connect">
        <section class="set-card board-connect-card" id="board-connect-invalid">
          <h1>{gettext("Connect a board box")}</h1>
          <p>
            {gettext(
              "This request does not say where to go back to, or names an address that is not a web address. Nothing was connected. Start again from the box."
            )}
          </p>
          <.link navigate={~p"/"} class="pe-btn">{gettext("Go to Tournaments")}</.link>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
