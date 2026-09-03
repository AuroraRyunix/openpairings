defmodule PairingsEngineWeb.UserLive.Features do
  @moduledoc """
  `/users/features` - the switches for the optional national-federation
  packs, per account.

  ## Why this is not part of `PairingsEngineWeb.UserLive.Settings`

  That page is `require_sudo_mode`: it changes the email address and the
  password, so it re-asks for the password before it will show itself. That
  is right for those two things and absurd for these five. Nothing on this
  page can lock anybody out, take anything over, or reveal anything the
  account holder cannot already see - the worst a stolen session can do here
  is hide five buttons from a page it is already looking at. Ordinary
  authentication, therefore, like every other page in the application.

  It is also reachable on a local installation, where `/users/settings` is
  deliberately not: an arbiter running the binary on their own laptop is
  exactly the person who most needs to say "I am not in Belgium".

  ## One card per federation

  `PairingsEngine.Features.federations/0` currently has one entry, and a
  one-item dropdown would be worse UI than a card that names the country and
  says plainly that nothing else is packaged yet. When a second pack
  arrives it is a second card and no change here.

  ## What the copy has to say, and why

  Two things, both near the top, because both are the questions this page
  will actually be asked:

    * **Turning something off does not change a tournament.** It hides
      buttons. This is the rule the whole design rests on (see
      `PairingsEngine.Features`), and an arbiter mid-event will not touch a
      switch that might restate their standings.
    * **The two readers depend on the sync, and the dependency is not
      enforced.** The lookup and the club update read the member list the
      sync downloads. With the sync off they search whatever was last
      downloaded, which is a legitimate state and not a mistake to be
      corrected by silently switching the sync back on.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport, only: [setting_group: 1, setting_toggle: 1]

  alias PairingsEngine.Features

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Federation features"))
     |> assign_features(socket.assigns.current_scope.user)}
  end

  defp assign_features(socket, user) do
    assign(socket, user: user, enabled: Features.enabled(user))
  end

  # The form submits the complete set every time - every switch is present,
  # each with the hidden `value="false"` companion `setting_toggle/1` emits -
  # so this is a replace and never a merge. Two tabs open on this page cannot
  # produce a half-applied state; the later save simply wins, which is what
  # a checkbox is understood to do.
  #
  # Nothing here re-checks a permission, because there is none to check: this
  # is the account editing its own preferences. The gates that DO matter live
  # at the controls these keys switch on - and, because a `phx-click` payload
  # is written by whoever is on the other end of the socket, in those
  # handlers' bodies as well as in their markup.
  @impl true
  def handle_event("save", params, socket) do
    keys =
      params
      |> Map.get("feature", %{})
      |> Enum.filter(fn {_key, value} -> value == "true" end)
      |> Enum.map(fn {key, _value} -> key end)

    case Features.set_enabled(socket.assigns.user, keys) do
      {:ok, user} ->
        {:noreply, assign_features(socket, user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save that. Please try again."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active="features"
    >
      <h1>{gettext("Federation features")}</h1>

      <p class="hint">
        {gettext(
          "Some national federations have their own member list, their own file format, and their own habits. Switch on the ones you work with; leave the rest off and they stay out of your way."
        )}
      </p>

      <div class="set-card">
        <h2>{gettext("Turning a feature off never changes your tournaments")}</h2>
        <p>
          {gettext(
            "It hides buttons. Everything already imported - players, clubs, scores, categories - stays exactly as it is, and scores exactly as it did."
          )}
        </p>
      </div>

      <form id="features-form" phx-change="save">
        <div :for={federation <- Features.federations()} class="set-card">
          <h2>{federation.name}</h2>
          <p class="hint">{federation.summary}</p>

          <.setting_group>
            <.setting_toggle
              :for={feature <- Features.catalogue_for(federation.code)}
              name={"feature[#{feature.key}]"}
              label={feature.label}
              hint={feature.description}
              checked={feature.key in @enabled}
            />
          </.setting_group>

          <p :if={federation.code == "BEL"} class="hint">
            {gettext(
              "The player lookup and the bulk club update read the member list the rating list sync downloads. They work with the sync switched off - they just search whatever was last downloaded, which may be an old list, or nothing at all if this machine has never synced."
            )}
          </p>
        </div>
      </form>

      <p class="hint">
        {gettext(
          "No other federations are packaged yet. Everything else in the application - FIDE ratings, TRF16 files, the FIDE report forms - is available to everyone and needs no switch."
        )}
      </p>
    </Layouts.app>
    """
  end
end
