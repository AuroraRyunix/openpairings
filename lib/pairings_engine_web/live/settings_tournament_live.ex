defmodule PairingsEngineWeb.SettingsTournamentLive do
  @moduledoc """
  The "Tournament" settings page (`/t/:id/settings`) — the canonical entry
  point of the split Settings section. Holds the tournament's identity
  (name/venue/city/federation/organizer/dates), its format and round count,
  the tie-break selection, sharing/collaborators, the print logo, and the
  JSON backup export. Pairing options, round dates, categories, extra points
  and FIDE-report identifiers each live on their own sibling page — see the
  sub-nav (`PairingsEngineWeb.SettingsSupport.settings_subnav/1`).
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{Audit, Tournaments, Tiebreaks}
  alias PairingsEngine.Tournaments.Tournament

  # 4th tuple element marks a field as mandatory setup data (see
  # `Tournament.required_setup_fields/0`) — its label renders bold with a
  # red "*". `rounds_count` is also required but is a standalone field below.
  @general_fields [
    {"name", "Tournament name", "text", true},
    {"venue", "Venue", "text", false},
    {"city", "City", "text", false},
    {"federation", "Federation", "text", false},
    {"start_date", "Start date", "date", true},
    {"end_date", "End date", "date", false},
    {"organizer", "Organizer", "text", false},
    {"organizer_club_number", "Organizer club nr / logo", "text", false}
  ]

  # SWAR §5.22 Tie-break Presets (TB_PERSONEL) — see the original SettingsLive
  # for the best-effort mapping rationale onto our own catalogue codes.
  @tb_presets [
    {"fide_rr", "FIDE Round Robin", ~w(DE WIN SB KS)},
    {"disparate_sw", "Disparate Swiss (wide rating range)", ~w(BHC1 BH SB)},
    {"regular_sw", "Regular Swiss", ~w(BHC1 BH PS)},
    {"old_sw", "Old Swiss (classic)", ~w(PS BH SB)}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)
    owner? = Tournaments.owner?(tournament, socket.assigns.current_scope)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> attach_dirty_tracker()
     |> assign(
       tournament: tournament,
       owner?: owner?,
       page_title: "#{tournament.name} · Settings",
       tiebreaks: tournament.tiebreaks,
       note: nil,
       error: nil,
       dirty: false,
       stale: false,
       collaborator_error: nil,
       collaborator_note: nil
     )
     |> assign_collaborators()
     |> allow_upload(:logo,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 1,
       max_file_size: 2_000_000
     )}
  end

  defp assign_collaborators(socket) do
    if socket.assigns.owner? do
      assign(socket, :collaborators, Tournaments.list_collaborators(socket.assigns.tournament))
    else
      assign(socket, :collaborators, [])
    end
  end

  @impl true
  def handle_info({:tournament_changed, _id, _hint}, %{assigns: %{dirty: true}} = socket) do
    handle_stale_check(socket)
  end

  def handle_info({:tournament_changed, _id, _hint}, socket) do
    case Tournaments.get_authorized_tournament(
           socket.assigns.current_scope,
           socket.assigns.tournament.id
         ) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "This tournament was deleted.")
         |> push_navigate(to: ~p"/")}

      tournament ->
        {:noreply,
         socket
         |> assign(tournament: tournament, tiebreaks: tournament.tiebreaks, stale: false)
         |> assign_collaborators()}
    end
  end

  ## ---------- Tiebreaks ----------

  @impl true
  def handle_event("tb_up", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), -1),
       note: nil
     )}
  end

  def handle_event("tb_down", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       tiebreaks: swap(socket.assigns.tiebreaks, String.to_integer(index), 1),
       note: nil
     )}
  end

  def handle_event("tb_remove", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: List.delete(socket.assigns.tiebreaks, code), note: nil)}
  end

  def handle_event("tb_add", %{"code" => ""}, socket), do: {:noreply, socket}

  def handle_event("tb_add", %{"code" => code}, socket) do
    {:noreply, assign(socket, tiebreaks: socket.assigns.tiebreaks ++ [code], note: nil)}
  end

  def handle_event("tb_reset", _params, socket) do
    {:noreply,
     assign(socket, tiebreaks: Tiebreaks.fide_defaults(socket.assigns.tournament.type), note: nil)}
  end

  def handle_event("tb_preset", %{"key" => "personel"}, socket), do: {:noreply, socket}

  def handle_event("tb_preset", %{"key" => key}, socket) do
    case Enum.find(@tb_presets, fn {k, _label, _methods} -> k == key end) do
      nil -> {:noreply, socket}
      {_key, _label, methods} -> {:noreply, assign(socket, tiebreaks: methods, note: nil)}
    end
  end

  ## ---------- Save ----------

  def handle_event("save", %{"tournament" => params}, socket) do
    params = Map.put(params, "tiebreaks", socket.assigns.tiebreaks)

    base = Tournaments.get_tournament!(socket.assigns.tournament.id)

    case Tournaments.update_tournament(base, params) do
      {:ok, tournament} ->
        log_settings_change(socket, base, tournament)

        {:noreply,
         assign(socket,
           tournament: tournament,
           tiebreaks: tournament.tiebreaks,
           note: "Saved.",
           error: nil,
           dirty: false,
           stale: false
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: error_text(changeset), note: nil)}
    end
  end

  ## ---------- Share / Team (collaborators) — owner-only ----------

  def handle_event("add_collaborator", %{"email" => email}, socket) do
    case Tournaments.add_collaborator(
           socket.assigns.current_scope,
           socket.assigns.tournament,
           email
         ) do
      {:ok, collaborator} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "collaborator.invited",
          %{email: collaborator.email}
        )

        note =
          if collaborator.mail_status == :failed do
            "Invite saved, but the email could not be sent — share this link manually: " <>
              "/invites/#{collaborator.invite_token}"
          end

        {:noreply,
         socket
         |> assign(collaborator_error: nil, collaborator_note: note)
         |> assign_collaborators()}

      {:error, :blank_email} ->
        {:noreply,
         assign(socket, collaborator_error: "Enter an email address", collaborator_note: nil)}

      {:error, :cannot_add_owner} ->
        {:noreply,
         assign(socket,
           collaborator_error: "You already own this tournament",
           collaborator_note: nil
         )}

      {:error, :already_added} ->
        {:noreply,
         assign(socket,
           collaborator_error: "That email already has access",
           collaborator_note: nil
         )}

      {:error, :not_owner} ->
        {:noreply,
         assign(socket,
           collaborator_error: "Only the owner can manage collaborators",
           collaborator_note: nil
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, collaborator_error: error_text(changeset), collaborator_note: nil)}
    end
  end

  def handle_event("remove_collaborator", %{"id" => id}, socket) do
    case Tournaments.remove_collaborator(
           socket.assigns.current_scope,
           socket.assigns.tournament,
           id
         ) do
      {:ok, collaborator} ->
        Audit.log(
          socket.assigns.tournament.id,
          socket.assigns.current_scope,
          "collaborator.removed",
          %{email: collaborator.email}
        )

        {:noreply, assign_collaborators(socket)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  ## ---------- Print logo (SWAR parity #14-16) ----------

  def handle_event("validate_logo", _params, socket), do: {:noreply, socket}

  def handle_event("upload_logo", _params, socket) do
    results =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case results do
      [binary] ->
        case Tournaments.set_logo(socket.assigns.tournament, binary) do
          {:ok, tournament} ->
            Audit.log(tournament.id, socket.assigns.current_scope, "logo.uploaded", %{
              content_type: tournament.logo_content_type,
              bytes: byte_size(binary)
            })

            {:noreply,
             socket
             |> assign(tournament: tournament)
             |> put_flash(:info, "Logo uploaded.")}

          {:error, :invalid_image} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "That file isn't a supported image. Only PNG, JPEG, GIF or WebP are accepted " <>
                 "(SVG is not supported) — the file's actual content is checked, not just its name."
             )}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, error_text(changeset))}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Choose an image file first")}
    end
  end

  def handle_event("clear_logo", _params, socket) do
    case Tournaments.clear_logo(socket.assigns.tournament) do
      {:ok, tournament} ->
        Audit.log(tournament.id, socket.assigns.current_scope, "logo.cleared", %{})

        {:noreply,
         socket
         |> assign(tournament: tournament)
         |> put_flash(:info, "Logo removed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not remove the logo")}
    end
  end

  ## ---------- helpers ----------

  defp swap(list, index, delta) do
    target = index + delta

    if target < 0 or target >= length(list) do
      list
    else
      a = Enum.at(list, index)
      b = Enum.at(list, target)
      list |> List.replace_at(index, b) |> List.replace_at(target, a)
    end
  end

  # Per-entry errors (a too-big or wrong-typed file) are what users actually
  # hit here, and LiveView keeps those on the entry, not on the upload config
  # — rendering only the config's errors left the picked file looking accepted
  # while `consume_uploaded_entries` skipped it, so the logo silently never
  # arrived.
  defp upload_error_label(:too_large), do: "Image is larger than 2 MB"
  defp upload_error_label(:too_many_files), do: "One image at a time"
  defp upload_error_label(:not_accepted), do: "Only PNG, JPEG, GIF and WebP images are accepted"
  defp upload_error_label(other), do: inspect(other)

  defp general_fields, do: @general_fields
  defp tb_presets, do: @tb_presets

  defp tb_preset_match(tiebreaks) do
    Enum.find_value(@tb_presets, "personel", fn {key, _label, methods} ->
      if tiebreaks == methods, do: key
    end)
  end

  defp available_tiebreaks(selected) do
    Enum.reject(Tiebreaks.catalogue(), &(&1.code in selected))
  end

  defp tb_name(code), do: (Tiebreaks.get(code) || %{name: code}).name
  defp tb_desc(code), do: (Tiebreaks.get(code) || %{description: ""}).description

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">Settings - Tournament</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:tournament} />

      <.stale_banner stale={@stale} />

      <form phx-submit="save">
        <div class="card">
          <h2>General</h2>

          <.setting_group>
            <.setting_field
              :for={{field, label, type, required} <- general_fields()}
              label={label}
              required={required}
            >
              <input
                type={type}
                name={"tournament[#{field}]"}
                value={Map.get(@tournament, String.to_existing_atom(field))}
              />
            </.setting_field>

            <.setting_field label="Tournament format">
              <select name="tournament[type]">
                <option
                  :for={type <- Tournament.types()}
                  value={type}
                  selected={@tournament.type == type}
                >
                  {Tournament.type_label(type)}
                </option>
              </select>
            </.setting_field>

            <.setting_field label="Number of rounds" required>
              <input
                type="number"
                name="tournament[rounds_count]"
                value={@tournament.rounds_count}
                min="1"
                max="30"
              />
            </.setting_field>
          </.setting_group>
        </div>

        <div class="card">
          <h2>Tiebreaks</h2>

          <p class="hint" style="margin-top: 0">
            Applied in order, following the FIDE Tie-Break Regulations. Higher in the list = decided first.
          </p>

          <%!-- A div, not <.setting_field>: that renders a <label>, which would
                make the "Preset" text toggle whichever radio it wrapped. --%>
          <div class="set-field solo">
            <span class="set-label">Preset</span>
            <div class="radio-row">
              <label>
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key="personel"
                  checked={tb_preset_match(@tiebreaks) == "personel"}
                /> Custom
              </label>

              <label :for={{key, label, _methods} <- tb_presets()}>
                <input
                  type="radio"
                  name="tb_preset_display"
                  phx-click="tb_preset"
                  phx-value-key={key}
                  checked={tb_preset_match(@tiebreaks) == key}
                /> {label}
              </label>
            </div>
          </div>

          <ol class="tb-list">
            <li :for={{code, i} <- Enum.with_index(@tiebreaks)}>
              <span class="tb-order">{i + 1}.</span>
              <div>
                <div class="tb-name">{tb_name(code)}</div>
                <div class="tb-desc">{tb_desc(code)}</div>
              </div>

              <div class="tb-buttons">
                <button
                  type="button"
                  class="pe-btn"
                  title="Move up"
                  disabled={i == 0}
                  phx-click="tb_up"
                  phx-value-index={i}
                >
                  ↑
                </button>

                <button
                  type="button"
                  class="pe-btn"
                  title="Move down"
                  disabled={i == length(@tiebreaks) - 1}
                  phx-click="tb_down"
                  phx-value-index={i}
                >
                  ↓
                </button>

                <button
                  type="button"
                  class="pe-btn"
                  title="Remove"
                  phx-click="tb_remove"
                  phx-value-code={code}
                >
                  ✕
                </button>
              </div>
            </li>
          </ol>

          <p :if={@tiebreaks == []} class="hint">
            No tiebreaks selected - tied players will share a rank.
          </p>

          <div class="actions" style="flex-wrap: wrap">
            <select phx-change="tb_add" name="code" style="width: auto" class="pe-select">
              <option value="">Add a tiebreak…</option>
              <option :for={tb <- available_tiebreaks(@tiebreaks)} value={tb.code}>{tb.name}</option>
            </select>
            <button type="button" class="pe-btn" phx-click="tb_reset">Reset to FIDE default</button>
          </div>
        </div>

        <div class="actions">
          <button type="submit" class="pe-btn primary">Save settings</button>
          <span :if={@note} class="ok-note" style="align-self: center">{@note}</span>
          <span :if={@error} class="error-note" style="align-self: center">{@error}</span>
        </div>
      </form>

      <div :if={@owner?} class="card">
        <h2>Share / Team</h2>

        <p class="hint" style="margin-top: 0">
          Invite other people to this tournament by email - they can open, edit, pair, enter
          results, print and export it, exactly like you, except they can't manage collaborators or
          delete the tournament. They only get access once they explicitly accept the emailed
          invitation while signed in with their own email
          (<.link navigate={~p"/users/log-in"}>magic link</.link>) - no shared password needed.
        </p>

        <form id="add-collaborator-form" phx-submit="add_collaborator">
          <.setting_group>
            <.setting_field label="Email address">
              <input type="email" name="email" placeholder="teammate@example.com" />
            </.setting_field>
          </.setting_group>

          <p :if={@collaborator_error} class="error-note">{@collaborator_error}</p>
          <p :if={@collaborator_note} class="hint">{@collaborator_note}</p>

          <div class="actions">
            <button type="submit" class="pe-btn primary">Add collaborator</button>
          </div>
        </form>

        <div :if={@collaborators != []} class="card-table-wrap" style="margin-top: 16px">
          <table class="pe-table">
            <thead>
              <tr>
                <th>Email</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @collaborators}>
                <td>{c.email}</td>
                <td>
                  <span class={["badge", c.status != "accepted" && "muted"]}>
                    {if c.status == "accepted", do: "active", else: "invited (waiting for accept)"}
                  </span>
                </td>
                <td style="text-align: right">
                  <button
                    class="pe-btn danger-link"
                    phx-click="remove_collaborator"
                    phx-value-id={c.id}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@collaborators == []} class="hint" style="margin-bottom: 0">
          Nobody else has access to this tournament yet.
        </p>
      </div>

      <div class="card">
        <h2>Logo</h2>

        <p class="hint" style="margin-top: 0">
          Shown on printed documents (place cards, and any other print page that has a logo slot -
          see <.link navigate={~p"/t/#{@tournament.id}/print"}>Print</.link>). Only raster images
          (PNG, JPEG, GIF, WebP) are accepted - SVG is rejected, since it can carry scripts and this
          image is embedded straight back into pages the app serves. Capped at 2&nbsp;MB.
        </p>

        <div :if={@tournament.logo_data} class="set-field solo">
          <span class="set-label">Current logo</span>
          <img
            src={Tournaments.logo_data_uri(@tournament)}
            alt="Tournament logo"
            style="max-height: 80px; max-width: 240px; display: block; margin-top: 6px"
          />
          <div class="actions" style="margin-top: 8px">
            <button type="button" class="pe-btn danger-link" phx-click="clear_logo">
              Remove logo
            </button>
          </div>
        </div>

        <form id="logo-upload-form" phx-submit="upload_logo" phx-change="validate_logo">
          <div class={["dropzone", @uploads.logo.entries != [] && "has-file"]}>
            <.live_file_input upload={@uploads.logo} class="dropzone-input" />
            <div class="dropzone-label">
              <%= if @uploads.logo.entries == [] do %>
                <strong>Choose a PNG, JPEG, GIF or WebP image</strong>
                <span class="hint">or drag and drop it here</span>
              <% else %>
                <span :for={entry <- @uploads.logo.entries} class="dropzone-file">
                  {entry.client_name}
                </span>
              <% end %>
            </div>
          </div>

          <p :for={err <- upload_errors(@uploads.logo)} class="error-note">
            {upload_error_label(err)}
          </p>
          <div :for={entry <- @uploads.logo.entries}>
            <p :for={err <- upload_errors(@uploads.logo, entry)} class="error-note">
              {entry.client_name}: {upload_error_label(err)}
            </p>
          </div>

          <div class="actions">
            <button type="submit" class="pe-btn primary" disabled={@uploads.logo.entries == []}>
              Upload logo
            </button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Export / backup</h2>

        <p class="hint" style="margin-top: 0">
          A full JSON backup of this tournament - settings, officials, every player (including norm
          data), rounds, pairings/results, byes and forbidden pairings. Re-importing it (from the
          <.link navigate={~p"/"}>Tournaments</.link>
          page) always creates a brand-new tournament, never overwrites this one. For a FIDE-report-shaped
          TRF16 file instead, see <.link navigate={~p"/t/#{@tournament.id}/pairings"}>Pairings</.link>{if @tournament.manual_ranking,
            do: " - note its rank column is the computed order, not manual ranking's hand-set one"}.
        </p>

        <div class="actions">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/json"} target="_blank">
            Export full backup (JSON)
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
