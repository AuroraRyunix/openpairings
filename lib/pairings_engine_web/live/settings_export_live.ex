defmodule PairingsEngineWeb.SettingsExportLive do
  @moduledoc """
  The "Export / backup" settings page (`/t/:id/settings/export`) - the TRF
  downloads (all rounds, chosen rounds, and the file to send with its
  "finalise" tick), the full JSON backup, the experimental `.swar` export,
  and the warning that the backup carries this tournament's publishing key.

  The TRF controls lived on the Pairings page until 0.65.x. A TRF is made
  after a round or at the end, not while a round is being played, and on
  the page used during play they were in the way.

  Split out from `PairingsEngineWeb.SettingsTournamentLive` on 2026-08-29:
  the card had nothing to do with tournament identity, it was just the last
  thing on that page. It gets its own tab for the same reason Results site
  and every other subject in Settings did.
  """
  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport

  alias PairingsEngine.{
    Audit,
    Authz,
    Features,
    Publishing,
    PlayerExport,
    PostponedGames,
    Tournaments
  }

  alias PairingsEngineWeb.Postponed
  alias PairingsEngine.Federations.BEL.SwarUpload

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     assign(socket,
       tournament: tournament,
       page_title: "#{tournament.name} · Settings · Export",
       bel_swar_export?: Features.enabled?(socket.assigns.current_scope, "bel_swar_export"),
       bel_swar_publish?: Features.enabled?(socket.assigns.current_scope, "bel_swar_publish"),
       # Publishing to the federation's own public results site is gated on
       # an administrator, same as every other "this affects more than one
       # arbiter's own tournament" control - see `PairingsEngine.Authz` and
       # `PairingsEngineWeb.FideLive`. Unlike that page's controls this one
       # IS specific to one tournament, but the site it reaches is shared
       # infrastructure this app has no authentication with, so the same
       # bar applies.
       may_admin?: Authz.may_administer?(socket.assigns.current_scope.user),
       swar_publish_result: nil,
       # The CSV picker's state lives only in this socket: it is a choice
       # about one download, not a tournament setting, and persisting it
       # would put a row in the database for every arbiter who ever opened
       # this page. It survives where it matters - in the download URL,
       # which is shareable and bookmarkable.
       csv_cols: PlayerExport.default_columns(),
       csv_delimiter: "comma",
       csv_sort: "seed",
       csv_skip_absent: false,
       csv_bom: true
     )
     |> assign_trf_state()}
  end

  # What the TRF section shows beside its downloads: rounds already sent,
  # players the sent-games record cannot tell apart, and postponed games
  # still open (the file is not final while one is).
  defp assign_trf_state(socket) do
    t = socket.assigns.tournament
    rounds = PostponedGames.trf_round_states(t)
    numbers = MapSet.new(rounds, & &1.round)

    # The ticked rounds. First time: every round ready to send. After a
    # change elsewhere: what the arbiter ticked, minus rounds that are gone.
    selected =
      case socket.assigns[:trf_selected] do
        nil -> rounds |> Enum.filter(&(&1.state == :ready)) |> MapSet.new(& &1.round)
        chosen -> MapSet.intersection(chosen, numbers)
      end

    assign(socket,
      sent_rounds: PostponedGames.sent_rounds(t),
      ambiguous_players: PostponedGames.ambiguous_players(t.id),
      postponed_open: PostponedGames.open_games(t),
      trf_rounds: rounds,
      trf_selected: selected
    )
  end

  # The ticked rounds as the export routes read them, "1,2,5".
  defp trf_rounds_param(selected), do: selected |> Enum.sort() |> Enum.join(",")

  # Why "Send" cannot go ahead with this selection, or nil when it can.
  defp trf_send_blocker(rounds, selected) do
    chosen = Enum.filter(rounds, &MapSet.member?(selected, &1.round))

    cond do
      chosen == [] ->
        gettext("Tick the rounds to send.")

      Enum.any?(chosen, &(&1.state == :sent)) ->
        gettext("Round %{rounds} was already sent. Untick it to send the others.",
          rounds: chosen |> Enum.filter(&(&1.state == :sent)) |> Enum.map_join(", ", & &1.round)
        )

      Enum.any?(chosen, &(&1.state == :playing)) ->
        gettext("Round %{rounds} still has boards without a result.",
          rounds:
            chosen |> Enum.filter(&(&1.state == :playing)) |> Enum.map_join(", ", & &1.round)
        )

      true ->
        nil
    end
  end

  defp trf_summary(rounds) do
    count = fn state -> Enum.count(rounds, &(&1.state == state)) end
    waiting = Enum.count(rounds, &(&1.state == :ready and &1.postponed > 0))

    [
      count.(:sent) > 0 &&
        ngettext("%{count} round sent", "%{count} rounds sent", count.(:sent)),
      count.(:ready) > 0 &&
        ngettext("%{count} ready to send", "%{count} ready to send", count.(:ready)),
      waiting > 0 &&
        ngettext(
          "%{count} with a postponed game open",
          "%{count} with postponed games open",
          waiting
        ),
      count.(:playing) > 0 &&
        ngettext("%{count} being played", "%{count} being played", count.(:playing))
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp trf_state_label(%{state: :sent, sent_at: %DateTime{} = at}),
    do: gettext("Sent %{date}", date: Calendar.strftime(at, "%d-%m-%Y"))

  defp trf_state_label(%{state: :sent}), do: gettext("Sent")

  defp trf_state_label(%{state: :ready, postponed: p}) when p > 0,
    do:
      ngettext(
        "Ready - %{count} postponed game goes out as unknown",
        "Ready - %{count} postponed games go out as unknown",
        p
      )

  defp trf_state_label(%{state: :ready}), do: gettext("Ready to send")

  defp trf_state_label(%{state: :playing, missing: m}),
    do:
      ngettext(
        "Being played - %{count} result missing",
        "Being played - %{count} results missing",
        m
      )

  defp trf_state_class(%{state: :ready, postponed: p}) when p > 0, do: "is-waiting"
  defp trf_state_class(%{state: state}), do: "is-#{state}"

  defp trf_send_confirm(selected) do
    gettext(
      "Send round %{rounds}? The file downloads, and every result in it is marked as sent: changing one afterwards asks for confirmation, and these rounds cannot be sent a second time.",
      rounds: trf_rounds_param(selected) |> String.replace(",", ", ")
    )
  end

  @impl true
  def handle_info({:tournament_changed, _tournament_id, _hint}, socket) do
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
        {:noreply, socket |> assign(tournament: tournament) |> assign_trf_state()}
    end
  end

  ## ---------- publishing to the federation's own results site ----------
  ##
  ## See `PairingsEngine.Federations.BEL.SwarUpload`'s moduledoc. Both
  ## handlers below re-check `bel_swar_publish?` and `may_admin?` even
  ## though the buttons that fire them only render when both are true - a
  ## control absent from the page is still an event anybody can send, the
  ## same reasoning `PairingsEngineWeb.FideLive` gives for its own re-checks.

  @impl true
  def handle_event("toggle_trf_round", %{"round" => round}, socket) do
    n = String.to_integer(round)
    selected = socket.assigns.trf_selected

    selected =
      if MapSet.member?(selected, n),
        do: MapSet.delete(selected, n),
        else: MapSet.put(selected, n)

    {:noreply, assign(socket, trf_selected: selected)}
  end

  @impl true
  def handle_event("swar_publish", _params, socket) do
    if socket.assigns.bel_swar_publish? and socket.assigns.may_admin? do
      tournament = socket.assigns.tournament
      # A fresh attempt starts clean - otherwise a stale :error banner from
      # an earlier failed attempt sits on screen next to a brand-new success
      # message (they are different flash keys, so one never overwrites the
      # other on its own).
      socket = clear_flash(socket)

      case SwarUpload.publish(tournament) do
        {:ok, published} ->
          Audit.log(published.id, socket.assigns.current_scope, "swar.published", %{
            guid: published.swar_guid
          })

          {:noreply,
           socket
           |> assign(tournament: published, swar_publish_result: nil)
           |> put_flash(
             :info,
             gettext("Published to the federation's results site (frbe-kbsb.be).")
           )}

        {:error, :upload, message} ->
          Audit.log(tournament.id, socket.assigns.current_scope, "swar.publish_failed", %{
            guid: tournament.swar_guid,
            step: "upload",
            error: message
          })

          {:noreply,
           socket
           |> assign(swar_publish_result: {:error, message})
           |> put_flash(:error, gettext("Could not publish: %{message}", message: message))}

        {:error, :index, message, uploaded} ->
          Audit.log(uploaded.id, socket.assigns.current_scope, "swar.publish_failed", %{
            guid: uploaded.swar_guid,
            step: "index",
            error: message
          })

          {:noreply,
           socket
           |> assign(tournament: uploaded, swar_publish_result: {:error, message})
           |> put_flash(
             :error,
             gettext(
               "Uploaded, but the federation did not confirm it was indexed (%{message}). The file is staged - press \"Finish indexing\" to retry.",
               message: message
             )
           )}
      end
    else
      {:noreply, put_flash(socket, :error, swar_publish_restricted())}
    end
  end

  def handle_event("swar_retry_index", _params, socket) do
    if socket.assigns.bel_swar_publish? and socket.assigns.may_admin? do
      tournament = socket.assigns.tournament
      socket = clear_flash(socket)

      case SwarUpload.index(tournament) do
        {:ok, indexed} ->
          Audit.log(indexed.id, socket.assigns.current_scope, "swar.published", %{
            guid: indexed.swar_guid
          })

          {:noreply,
           socket
           |> assign(tournament: indexed, swar_publish_result: nil)
           |> put_flash(
             :info,
             gettext("Published to the federation's results site (frbe-kbsb.be).")
           )}

        {:error, message} ->
          Audit.log(tournament.id, socket.assigns.current_scope, "swar.publish_failed", %{
            guid: tournament.swar_guid,
            step: "index",
            error: message
          })

          {:noreply,
           socket
           |> assign(swar_publish_result: {:error, message})
           |> put_flash(:error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, swar_publish_restricted())}
    end
  end

  def handle_event("csv_add", %{"key" => key}, socket) do
    case known_column(key) do
      nil -> {:noreply, socket}
      k -> {:noreply, update(socket, :csv_cols, &if(k in &1, do: &1, else: &1 ++ [k]))}
    end
  end

  def handle_event("csv_remove", %{"key" => key}, socket) do
    case known_column(key) do
      nil -> {:noreply, socket}
      k -> {:noreply, update(socket, :csv_cols, &List.delete(&1, k))}
    end
  end

  def handle_event("csv_up", %{"key" => key}, socket) do
    {:noreply, update(socket, :csv_cols, &move(&1, known_column(key), -1))}
  end

  def handle_event("csv_down", %{"key" => key}, socket) do
    {:noreply, update(socket, :csv_cols, &move(&1, known_column(key), 1))}
  end

  def handle_event("csv_opts", params, socket) do
    {:noreply,
     assign(socket,
       csv_delimiter:
         pick(params["delimiter"], PlayerExport.delimiter_names(), socket.assigns.csv_delimiter),
       csv_sort: pick(params["sort"], PlayerExport.sort_orders(), socket.assigns.csv_sort),
       csv_skip_absent: params["skip_absent"] == "true",
       csv_bom: params["bom"] == "true"
     )}
  end

  defp pick(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  # A phx-value can say anything, so the key is resolved against the
  # export's own vocabulary rather than through String.to_atom - which on a
  # crafted event would grow the atom table for as long as somebody kept
  # sending them.
  defp known_column(key) when is_binary(key) do
    case PlayerExport.parse_columns(key) do
      [k] -> if Atom.to_string(k) == key, do: k
      _ -> nil
    end
  end

  defp known_column(_), do: nil

  defp move(list, nil, _offset), do: list

  defp move(list, key, offset) do
    case Enum.find_index(list, &(&1 == key)) do
      nil ->
        list

      index ->
        target = index + offset

        if target < 0 or target >= length(list) do
          list
        else
          moved = Enum.at(list, index)
          displaced = Enum.at(list, target)
          list |> List.replace_at(index, displaced) |> List.replace_at(target, moved)
        end
    end
  end

  defp available_columns(chosen) do
    Enum.reject(PlayerExport.columns(), fn {key, _label, _kind} -> key in chosen end)
  end

  defp delimiter_label("comma"), do: gettext("Comma  ,")

  defp delimiter_label("semicolon"),
    do: gettext("Semicolon  ;   (Excel on a Belgian/Dutch machine)")

  defp delimiter_label("tab"), do: gettext("Tab")
  defp delimiter_label("pipe"), do: gettext("Pipe  |")

  defp csv_href(assigns) do
    ~p"/t/#{assigns.tournament.id}/export/players?#{[cols: Enum.join(assigns.csv_cols, ","), delimiter: assigns.csv_delimiter, sort: assigns.csv_sort, skip_absent: if(assigns.csv_skip_absent, do: "1", else: "0"), bom: if(assigns.csv_bom, do: "1", else: "0")]}"
  end

  defp swar_publish_restricted,
    do: gettext("Publishing to the federation's results site needs an administrator.")

  defp swar_error_message({:error, message}), do: message

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="settings"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">{gettext("Settings - Export")}</p>
        </div>
        <span class={["badge", @tournament.status == "setup" && "muted"]}>{@tournament.status}</span>
      </div>

      <.settings_subnav tournament={@tournament} active={:export} />

      <div class="card" id="trf-export">
        <h2>{gettext("TRF (FIDE rating report)")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "The file for the rating officer. Tick the rounds, then download a copy (nothing is marked) or send them: sending marks their results as sent, so a round is never sent twice and a sent result asks for confirmation before it changes."
          )}
        </p>

        <p :if={@trf_rounds == []} class="hint" id="trf-no-rounds">
          {gettext("No round is paired yet.")}
        </p>

        <div :if={@trf_rounds != []}>
          <p id="trf-summary" class="trf-summary">{trf_summary(@trf_rounds)}</p>

          <div class="card-table-wrap">
            <table class="pe-table trf-rounds" id="trf-rounds">
              <thead>
                <tr>
                  <th scope="col" class="trf-tick">
                    <span class="sr-only">{gettext("Include")}</span>
                  </th>
                  <th scope="col">{gettext("Round")}</th>
                  <th scope="col">{gettext("Boards")}</th>
                  <th scope="col">{gettext("State")}</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={r <- @trf_rounds}
                  id={"trf-round-#{r.round}"}
                  class={["trf-row", trf_state_class(r)]}
                >
                  <td class="trf-tick">
                    <input
                      type="checkbox"
                      id={"trf-tick-#{r.round}"}
                      checked={MapSet.member?(@trf_selected, r.round)}
                      phx-click="toggle_trf_round"
                      phx-value-round={r.round}
                      aria-label={gettext("Include round %{n}", n: r.round)}
                    />
                  </td>
                  <td><label for={"trf-tick-#{r.round}"}>{r.round}</label></td>
                  <td>{r.boards}</td>
                  <td>
                    <span class={["trf-state", trf_state_class(r)]}>
                      <span class="trf-state-mark" aria-hidden="true"></span>
                      {trf_state_label(r)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <% blocker = trf_send_blocker(@trf_rounds, @trf_selected) %>
          <div class="actions" style="align-items: center">
            <a
              id="trf-download-copy"
              class={["pe-btn", MapSet.size(@trf_selected) == 0 && "is-disabled"]}
              href={
                if MapSet.size(@trf_selected) > 0,
                  do: ~p"/t/#{@tournament.id}/export/trf?rounds=#{trf_rounds_param(@trf_selected)}"
              }
              aria-disabled={to_string(MapSet.size(@trf_selected) == 0)}
              target="_blank"
            >
              {gettext("Download a copy")}
            </a>

            <%!-- The TRF an arbiter SENDS - to the federation's rating office.
                  POST, because it marks every exported result as sent
                  (`PostponedGames.finalise/2`), and a GET that could do that
                  would be fired by a link prefetch. --%>
            <.form
              for={%{}}
              id="trf-send-form"
              action={~p"/t/#{@tournament.id}/export/trf"}
              method="post"
              target="_blank"
              style="margin: 0"
            >
              <input type="hidden" name="rounds" value={trf_rounds_param(@trf_selected)} />
              <input type="hidden" name="finalise" value="true" />
              <button
                type="submit"
                id="trf-send"
                class="pe-btn primary"
                disabled={not is_nil(blocker)}
                data-confirm={is_nil(blocker) && trf_send_confirm(@trf_selected)}
              >
                {gettext("Send…")}
              </button>
            </.form>

            <span :if={blocker} id="trf-send-blocker" class="hint">{blocker}</span>

            <a
              class="trf-all-link"
              style="margin-left: auto"
              href={~p"/t/#{@tournament.id}/export/trf"}
              target="_blank"
            >
              {gettext("All rounds (TRF)")}
            </a>
          </div>

          <p :if={@sent_rounds != []} id="trf-sent-rounds" class="sr-only">
            {gettext("Already sent: round %{rounds}", rounds: Enum.join(@sent_rounds, ", "))}
          </p>
        </div>
        <p
          :if={@tournament.manual_ranking}
          class="hint"
          style="margin: 8px 0 0"
        >
          {gettext(
            "Manual ranking is on for this tournament, but the TRF export's rank column reflects the computed/starting-rank order, not the arbiter's hand-set display order."
          )}
        </p>

        <%!-- Beside sending (`:sent_games_ambiguous_players`): the record of
              sent games names a player with no FIDE ID by name, so two with
              one name are one player to it. It warns; sending still works. --%>
        <div
          :if={@ambiguous_players != []}
          id="sent-games-ambiguous-players"
          class="card"
          role="status"
          style="display: block; margin: 8px 0 0; border-left: 3px solid var(--warn)"
        >
          {Postponed.ambiguous_players_text(@ambiguous_players)}
        </div>

        <p
          :if={@postponed_open != []}
          id="postponed-trf-not-final"
          class="hint"
          style="margin: 8px 0 0"
        >
          {Postponed.trf_not_final_text(length(@postponed_open))}
          <span
            :if={
              @tournament.postponed_requester_outcome != "draw" or
                @tournament.postponed_opponent_outcome != "draw"
            }
            id="postponed-trf-counts-draw"
          >
            {gettext(
              "The TRF scores it as that draw, as the format says: the standings here count it as set under Settings, Scoring, so the file's points can differ from them until the game is played."
            )}
            <%!-- Checked against `TrfExport`: the TRF26 download writes `?`
                  but values it at a draw (`X` in 162), and the older spelling
                  writes the draw itself, so neither carries the provisional
                  points the rounds were paired with. --%>
            <span id="postponed-trf-outside-checkers">
              {gettext(
                "So an outside pairing program or checker (JaVaFo, a FIDE pairing checker) cannot reproduce the rounds paired since from a downloaded TRF: both downloads count the game as a draw. The TRF26 download at least marks it as unknown (?, valued by X); the older one writes a plain draw."
              )}
            </span>
          </span>
        </p>
      </div>

      <div class="card">
        <h2>{gettext("Export / backup")}</h2>

        <p class="hint" style="margin-top: 0">
          <.rich_text text={
            gettext(
              "A full JSON backup of this tournament - settings, officials, every player (including norm data), rounds, pairings/results, byes and forbidden pairings. Re-importing it (from the %[tournaments] page) always creates a brand-new tournament, never overwrites this one."
            )
          }>
            <:part name="tournaments">
              <.link navigate={~p"/"}>{gettext("Tournaments")}</.link>
            </:part>
          </.rich_text>
          <span :if={@tournament.manual_ranking}>
            {gettext(
              "Note that its rank column is the computed order, not manual ranking's hand-set one."
            )}
          </span>
        </p>

        <%!-- Shown only when the file would actually carry the key, so that
              the warning is never noise and is always true when it appears.
              It says what the key can DO rather than that the file is
              "sensitive" - a backup of a chess tournament reads as harmless,
              and the reason to guard this one is not obvious from the
              outside. --%>
        <p :if={Publishing.published?(@tournament)} class="hint" style="color: var(--danger)">
          {gettext(
            "This backup carries this tournament's publishing key. Anyone who has the file can update its page on the results site, or delete that page along with its whole history and any entries collected for it. That is deliberate - it is how a rebuilt machine recovers control of what it published - but treat the file like a password."
          )}
        </p>

        <div class="actions">
          <a class="pe-btn" href={~p"/t/#{@tournament.id}/export/json"} target="_blank">
            {gettext("Export full backup (JSON)")}
          </a>

          <%!-- Only for an account that switched the Belgian pack's SWAR
                export on. The route refuses too - a link is not a gate - but
                this is what stops the page offering a download that would
                only bounce. See `PairingsEngine.Features`; the tournament
                itself is untouched either way. --%>
          <a
            :if={@bel_swar_export?}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/export/swar"}
            target="_blank"
            title={
              gettext(
                "A .swar file SWAR itself can open - never verified against a real SWAR install, see docs/swar-import.md"
              )
            }
          >
            {gettext("Export .swar (v7, experimental)")}
          </a>

          <%!-- Same gate, same reasoning, for the SWAR-compatible HTML
                results page instead of the binary file - see
                PairingsEngine.Federations.BEL.SwarPublish. This is only
                the download; sending it to the federation itself is the
                card below, gated the same way plus an administrator. --%>
          <a
            :if={@bel_swar_publish?}
            class="pe-btn"
            href={~p"/t/#{@tournament.id}/export/swar_html"}
            target="_blank"
            title={
              gettext(
                "The standings and round results, laid out the way the federation's results site expects."
              )
            }
          >
            {gettext("Export SWAR results page (.html)")}
          </a>
        </div>
      </div>

      <%!-- Publishes PUBLICLY, to the federation's own results site, not to
            OpenResults - and cannot be taken back from here (see
            PairingsEngine.Federations.BEL.SwarUpload's moduledoc). Gated
            on the same feature as the download above, plus an
            administrator - see `may_admin?` in mount/3. --%>
      <div :if={@bel_swar_publish?} class="card">
        <h2>{gettext("Publish to the federation's results site")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Sends the results page above to frbe-kbsb.be and asks the federation to index it - the same two steps SWAR itself performs. This is the federation's own public site, not OpenResults: the standings and results become visible there to anyone, immediately, and this machine cannot take that back down."
          )}
        </p>

        <p :if={!@may_admin?} class="hint">
          {gettext("Publishing to the federation needs an administrator.")}
        </p>

        <p :if={@tournament.swar_published_at} class="hint">
          {gettext("Last published: %{when} UTC.",
            when: Calendar.strftime(@tournament.swar_published_at, "%Y-%m-%d %H:%M")
          )}
        </p>

        <%!-- A PUT that lands followed by a GET that fails is a normal,
              recoverable outcome, not a dead end - see SwarUpload's
              moduledoc. This is derived from the two persisted
              timestamps, so it survives a page reload rather than only
              living in this socket's memory. --%>
        <p
          :if={SwarUpload.staged_but_not_indexed?(@tournament)}
          class="hint"
          style="color: var(--danger)"
        >
          {gettext(
            "The file was uploaded but the federation has not confirmed it is indexed yet. Press \"Finish indexing\" to retry just that step - no need to upload again."
          )}
        </p>

        <p :if={@swar_publish_result} class="hint">
          <strong style="color: var(--danger)">{swar_error_message(@swar_publish_result)}</strong>
        </p>

        <div class="actions">
          <button
            type="button"
            class="pe-btn primary"
            phx-click="swar_publish"
            disabled={!@may_admin?}
            data-confirm={
              gettext(
                "Publish \"%{name}\" to the federation's public results site (frbe-kbsb.be)? Its standings and results become visible to anyone there, immediately, and this cannot be undone from here.",
                name: @tournament.name
              )
            }
          >
            {gettext("Publish to frbe-kbsb.be")}
          </button>

          <button
            :if={SwarUpload.staged_but_not_indexed?(@tournament)}
            type="button"
            class="pe-btn"
            phx-click="swar_retry_index"
            disabled={!@may_admin?}
          >
            {gettext("Finish indexing")}
          </button>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("Export players (CSV)")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Choose the fields, put them in the order you want them, and pick what separates the columns. Excel splits on the list separator of the machine's locale - on a Belgian or Dutch Windows that is a semicolon, not a comma, and a comma-separated file opens as one column of text."
          )}
        </p>

        <div class="set-group">
          <span class="set-label">{gettext("Columns, in this order")}</span>

          <p :if={@csv_cols == []} class="hint">
            {gettext("Nothing chosen - the download falls back to the standard set.")}
          </p>

          <div
            :for={{key, index} <- Enum.with_index(@csv_cols)}
            class="actions"
            style="justify-content: space-between; align-items: center; padding: 2px 0"
          >
            <span>{index + 1}. {PlayerExport.label(key)}</span>
            <span class="actions">
              <button
                type="button"
                class="pe-btn"
                phx-click="csv_up"
                phx-value-key={key}
                disabled={index == 0}
                title={gettext("Move up")}
              >
                &uarr;
              </button>
              <button
                type="button"
                class="pe-btn"
                phx-click="csv_down"
                phx-value-key={key}
                disabled={index == length(@csv_cols) - 1}
                title={gettext("Move down")}
              >
                &darr;
              </button>
              <button type="button" class="pe-btn" phx-click="csv_remove" phx-value-key={key}>
                {gettext("Remove")}
              </button>
            </span>
          </div>
        </div>

        <div class="set-group">
          <span class="set-label">{gettext("Add a field")}</span>
          <div class="round-picker" style="flex-wrap: wrap">
            <button
              :for={{key, label, _kind} <- available_columns(@csv_cols)}
              type="button"
              class="pe-btn filter-picker"
              phx-click="csv_add"
              phx-value-key={key}
            >
              + {label}
            </button>
          </div>
        </div>

        <%!-- The id is not decoration: without one LiveView cannot recover
              the form after a reconnect, and says so loudly. --%>
        <form id="csv-options" phx-change="csv_opts">
          <.setting_group>
            <.setting_field label={gettext("Column separator")}>
              <select name="delimiter">
                <option
                  :for={name <- PlayerExport.delimiter_names()}
                  value={name}
                  selected={name == @csv_delimiter}
                >
                  {delimiter_label(name)}
                </option>
              </select>
            </.setting_field>

            <.setting_field label={gettext("Row order")}>
              <select name="sort">
                <option value="seed" selected={@csv_sort == "seed"}>
                  {gettext("Seed - starting rank, then rating")}
                </option>
                <option value="name" selected={@csv_sort == "name"}>
                  {gettext("Name - A to Z")}
                </option>
              </select>
            </.setting_field>

            <.setting_toggle
              name="skip_absent"
              label={gettext("Leave out players marked absent")}
              checked={@csv_skip_absent}
              hint={
                gettext(
                  "The permanent Absent checkbox only. Somebody who is just missing one round still appears."
                )
              }
            />

            <.setting_toggle
              name="bom"
              label={gettext("Excel-friendly (UTF-8 marker)")}
              checked={@csv_bom}
              hint={
                gettext(
                  "Without it Excel reads an accented name as mojibake. Switch it off if a script refuses the leading bytes."
                )
              }
            />
          </.setting_group>
        </form>

        <div class="actions">
          <a class="pe-btn primary" href={csv_href(assigns)}>
            {gettext("Download players (CSV)")}
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
