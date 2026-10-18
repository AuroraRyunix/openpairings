defmodule PairingsEngineWeb.NormsLive do
  @moduledoc """
  The "Norms" tab: lets the tournament's owner download the official FIDE
  report/norm `.xlsx` forms (IT3, FA1, IA1, IT4), generated on demand from
  the tournament's data by `PairingsEngine.Norms.Forms`, and shows each
  player's automatic title-norm judgment. The officials those forms name and
  the event type the judgment uses are settings
  (`PairingsEngineWeb.SettingsNormsLive`); this page only reads them.

  The actual `.xlsx` bytes are produced by `PairingsEngineWeb.NormsController`
  (plain `GET` downloads, not LiveView) - this page is just the picker UI:

    * IT3 needs no extra input, so it's a single download link.
    * FA1/IA1 need an arbiter norm candidate's name/FIDE ID/federation, which
      isn't tracked anywhere else in the app (the candidate needn't even be
      a tournament player) - collected via a plain `GET` form, submitted
      straight to the controller with no LiveView round-trip.
    * IT4 lists every player, with a small modal to set that player's
      title-norm judgment (`norm_data` on `PairingsEngine.Tournaments.Player`)
      - only players with a non-blank claimed title are included when IT4 is
      generated.
    * "Combined report (festival)" lets a Belgian-federation arbiter running
      several category groups as one festival (each its own `Tournament`
      row) pick other tournaments to merge into one IT3/FA1/IA1, plus a
      "master" tournament supplying the shared header/schedule fields (see
      `PairingsEngine.Norms.Combine`). This card only *builds the link* -
      the selection lives in `@combine_selected`/`@combine_master` and is
      passed to `PairingsEngineWeb.NormsController` as `combine`/`master`
      query params; nothing here is saved.
  """

  use PairingsEngineWeb, :live_view

  import PairingsEngineWeb.SettingsSupport
  import PairingsEngineWeb.Components.It3CountsExplain

  alias PairingsEngineWeb.Components.It3CountsExplain

  alias PairingsEngine.{Fide, Tournaments}
  alias PairingsEngine.Norms.Forms
  alias PairingsEngine.Tournaments.Player

  @norm_titles ~w(GM IM FM CM WGM WIM WFM WCM)

  # The two ranked deputy slots the officials settings offer (see
  # `PairingsEngineWeb.SettingsNormsLive`); read here for the report
  # blockers and the FA1 candidate picker.
  @deputy_fields [
    {1, "1st deputy arbiter"},
    {2, "2nd deputy arbiter"}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
    end

    {:ok,
     socket
     |> assign(
       tournament: tournament,
       page_title: "#{tournament.name} · Norms",
       editing_norm_player: nil,
       norm_form: %{},
       norm_error: nil,
       norm_titles: @norm_titles,
       other_tournaments: other_tournaments(socket.assigns.current_scope, tournament.id),
       combine_selected: MapSet.new(),
       combine_master: to_string(tournament.id),
       # FA1/IA1 candidate fields, prefilled by the "Pick an arbiter" select
       # below. Kept in assigns (rather than left as uncontrolled inputs) so
       # picking someone can populate all four at once; still editable by hand,
       # and still submitted as a plain GET like before.
       fa1_candidate: empty_fa1_candidate()
     )
     |> assign_players()}
  end

  # Every *other* tournament the current user can access (owner or accepted
  # collaborator - same scoping `Tournaments.list_tournaments/1` already
  # gives the tournament list page), for the "Combined report (festival)"
  # card's checkbox picker. The current tournament itself is excluded here
  # since it's always implicitly part of the combined set (see
  # `combine_ids/3`).
  defp other_tournaments(scope, tournament_id) do
    scope
    |> Tournaments.list_tournaments()
    |> Enum.reject(fn {t, _player_count, _owner?} -> t.id == tournament_id end)
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
        {:noreply, socket |> assign(tournament: tournament) |> assign_players()}
    end
  end

  defp assign_players(socket) do
    players = Tournaments.list_players(socket.assigns.tournament.id)

    judgments = PairingsEngine.Norms.TitleNorms.evaluate(socket.assigns.tournament)

    socket
    |> assign(:players, players)
    |> assign(:norm_judgments, judgments)
    # Both of these walk the whole roster; memoised here rather than in the
    # template, which re-runs on every keystroke in the FA1 candidate form.
    |> assign(
      :it3_counts,
      It3CountsExplain.precompute(players, socket.assigns.tournament.federation)
    )
    |> assign(:players_by_relevance, players_by_norm_relevance(players, judgments))
  end

  @impl true
  def handle_event("edit_norm", %{"id" => id}, socket) do
    player = Tournaments.get_player!(socket.assigns.tournament.id, id)

    {:noreply,
     assign(socket, editing_norm_player: player, norm_form: norm_form(player), norm_error: nil)}
  end

  def handle_event("close_norm", _params, socket) do
    {:noreply, assign(socket, editing_norm_player: nil, norm_form: %{}, norm_error: nil)}
  end

  def handle_event("save_norm", %{"player" => params}, socket) do
    case Tournaments.update_player(socket.assigns.editing_norm_player, params) do
      {:ok, _player} ->
        {:noreply,
         socket
         |> assign(editing_norm_player: nil, norm_form: %{}, norm_error: nil)
         |> assign_players()}

      {:error, changeset} ->
        {:noreply, assign(socket, norm_error: error_text(changeset), norm_form: params)}
    end
  end

  ## ---------- Combined report (festival) picker ----------

  def handle_event("toggle_combine_tournament", %{"id" => id}, socket) do
    selected = socket.assigns.combine_selected

    {selected, master} =
      if MapSet.member?(selected, id) do
        deselected = MapSet.delete(selected, id)
        # Deselecting the current master falls back to the tournament
        # itself, which is always part of the combined set.
        master =
          if socket.assigns.combine_master == id,
            do: to_string(socket.assigns.tournament.id),
            else: socket.assigns.combine_master

        {deselected, master}
      else
        {MapSet.put(selected, id), socket.assigns.combine_master}
      end

    {:noreply, assign(socket, combine_selected: selected, combine_master: master)}
  end

  def handle_event("set_combine_master", %{"master" => id}, socket) do
    {:noreply, assign(socket, :combine_master, id)}
  end

  # Typing in the FA1/IA1 fields writes straight back into the assign that
  # renders them. Without this the inputs are controlled by `@fa1_candidate`
  # but nothing updates it, so any re-render (a PubSub tournament change, a
  # second pick) would silently revert what was typed - and the form would
  # then submit the reverted values.
  def handle_event("fa1_change", %{"candidate" => candidate}, socket) do
    merged = Map.merge(socket.assigns.fa1_candidate, Map.take(candidate, fa1_candidate_keys()))
    {:noreply, assign(socket, fa1_candidate: merged)}
  end

  def handle_event("fa1_change", _params, socket), do: {:noreply, socket}

  def handle_event("pick_fa1_candidate", %{"fa1_candidate" => ""}, socket) do
    {:noreply, assign(socket, fa1_candidate: empty_fa1_candidate())}
  end

  def handle_event("pick_fa1_candidate", %{"fa1_candidate" => key}, socket) do
    {:noreply, assign(socket, fa1_candidate: fa1_candidate_for(socket.assigns.tournament, key))}
  end

  # A standalone select can serialise as `%{"value" => ...}` rather than by
  # name, and an unexpected shape must never take the LiveView down - see the
  # `arbiter_search` comment above for what that costs the user.
  def handle_event("pick_fa1_candidate", %{"value" => ""}, socket) do
    {:noreply, assign(socket, fa1_candidate: empty_fa1_candidate())}
  end

  def handle_event("pick_fa1_candidate", %{"value" => key}, socket) when is_binary(key) do
    {:noreply, assign(socket, fa1_candidate: fa1_candidate_for(socket.assigns.tournament, key))}
  end

  def handle_event("pick_fa1_candidate", _params, socket), do: {:noreply, socket}

  defp norm_form(%Player{norm_data: data}) do
    d = data || %{}

    %{
      "norm_data" => %{
        "title_claimed" => Map.get(d, "title_claimed", ""),
        "norm_description" => Map.get(d, "norm_description", ""),
        "medal_percent" => Map.get(d, "medal_percent", ""),
        "event_group" => Map.get(d, "event_group", ""),
        "fed_participating" => Map.get(d, "fed_participating", ""),
        "fed_members" => Map.get(d, "fed_members", ""),
        "remarks" => Map.get(d, "remarks", "")
      }
    }
  end

  ## ---------- FA1/IA1 arbiter norm candidate ----------

  defp fa1_candidate_keys, do: ~w(last_name first_name fide_id federation)

  defp empty_fa1_candidate, do: Map.new(fa1_candidate_keys(), &{&1, ""})

  # The event's own officials, as pickable norm candidates - an arbiter earning
  # a norm here is nearly always one of them, and retyping a name and FIDE ID
  # that the tournament already knows is both tedious and a chance to fat-finger
  # the id onto the wrong person.
  defp fa1_candidate_options(tournament) do
    chief = [{"chief_arbiter", tournament.chief_arbiter}]
    deputies = for n <- 1..2, do: {"deputy#{n}", o_get(tournament, "deputy#{n}_name")}

    extras =
      for n <- extra_arbiter_range(o_get(tournament, "extra_arbiters_count")),
          do: {"arbiter#{n}", o_get(tournament, "arbiter#{n}_name")}

    (chief ++ deputies ++ extras)
    |> Enum.reject(fn {_key, name} -> blank?(name) end)
    |> Enum.map(fn {key, name} -> {name, key} end)
  end

  defp fa1_candidate_for(tournament, "chief_arbiter"),
    do: build_fa1_candidate(tournament.chief_arbiter, o_get(tournament, "chief_arbiter_fide_id"))

  defp fa1_candidate_for(tournament, "deputy" <> _ = key),
    do:
      build_fa1_candidate(
        o_get(tournament, "#{key}_name"),
        o_get(tournament, "#{key}_fide_id")
      )

  defp fa1_candidate_for(tournament, "arbiter" <> _ = key),
    do:
      build_fa1_candidate(
        o_get(tournament, "#{key}_name"),
        o_get(tournament, "#{key}_fide_id")
      )

  defp fa1_candidate_for(_tournament, _key), do: empty_fa1_candidate()

  # Prefer the FIDE record when there's an id: it's authoritative on the
  # first/last split ("De Vet, Sylvin") and carries the federation, neither of
  # which can be inferred reliably from SWAR's "Sylvin De Vet" ordering - a
  # multi-word surname makes any positional guess wrong as often as right.
  defp build_fa1_candidate(name, fide_id) do
    case Fide.get_player(fide_id) do
      nil ->
        {last, first} = split_plain_name(name)
        %{"last_name" => last, "first_name" => first, "fide_id" => "", "federation" => ""}

      fp ->
        {last, first} = split_fide_name(fp.name)

        %{
          "last_name" => last,
          "first_name" => first,
          "fide_id" => to_string(fp.fide_id),
          "federation" => fp.federation || ""
        }
    end
  end

  defp split_fide_name(name) do
    case String.split(to_string(name), ",", parts: 2) do
      [last, first] -> {String.trim(last), String.trim(first)}
      [only] -> {String.trim(only), ""}
    end
  end

  # No FIDE record to lean on: SWAR's order is "First Last", so the first word
  # is the given name and everything after it the surname. A guess, but the
  # fields stay editable.
  defp split_plain_name(name) do
    case String.split(to_string(name), ~r/\s+/, trim: true) do
      [] -> {"", ""}
      [only] -> {only, ""}
      [first | rest] -> {Enum.join(rest, " "), first}
    end
  end

  defp o_get(tournament, key), do: Map.get(tournament.officials || %{}, key, "")

  # 1..count is a *descending* range (iterating count..1) when count is 0 -
  # an easy footgun elsewhere in this codebase - so 0 (the common case: no
  # extra arbiters) has to short-circuit to an empty range explicitly.
  defp extra_arbiter_range(count) do
    case parse_extra_count(count) do
      n when n > 0 -> 1..n
      _ -> 1..0//1
    end
  end

  # The red bar above a blocked download. Names exactly what's missing and
  # where to fix it, rather than just greying the button out and leaving the
  # arbiter to guess.
  attr :blockers, :list, required: true

  defp report_blockers_bar(assigns) do
    ~H"""
    <div :if={@blockers != []} class="report-blocked">
      <strong>{gettext("Not ready to submit to FIDE.")}</strong> {gettext(
        "FIDE identifies every official by FIDE ID, so a report missing one gets bounced. Fill these in under Settings, Officials & norms:"
      )}
      <ul>
        <li :for={blocker <- @blockers}>{blocker}</li>
      </ul>
    </div>
    """
  end

  ## ---------- FIDE report readiness ----------

  # FIDE won't accept an IT3 with an arbiter it can't identify, so a report
  # missing an official's FIDE ID is a wasted submission - better to say so
  # here than to hand over a file that gets bounced. Returns the human-readable
  # list of what's missing; `[]` means good to go.
  #
  # A deputy slot left empty is fine (not every event has two); a deputy that
  # has been *named* without an ID is not, since that's the half-filled state
  # the SWAR import leaves behind whenever a name is ambiguous.
  #
  # Chief arbiter's and organizer's e-mail are ALSO required - not a made-up
  # rule, FIDE's own template prints "PRIVACY NOTICE: Chief Organizer's and
  # Chief Arbiter's e-mail address is required only for institutional
  # purposes and will be displayed on FIDE website" right on the
  # Certificaat sheet, so a report missing either is exactly as much a
  # wasted submission as a missing FIDE ID.
  def report_blockers(tournament) do
    fide_id =
      if Tournaments.Tournament.fide_id_present?(tournament) do
        []
      else
        ["FIDE tournament ID (set it on Settings → FIDE)"]
      end

    chief =
      cond do
        blank?(tournament.chief_arbiter) -> ["Chief arbiter name"]
        blank?(o_get(tournament, "chief_arbiter_fide_id")) -> ["Chief arbiter FIDE ID"]
        true -> []
      end

    deputies =
      for {n, label} <- @deputy_fields,
          not blank?(o_get(tournament, "deputy#{n}_name")),
          blank?(o_get(tournament, "deputy#{n}_fide_id")),
          do: "#{label} FIDE ID"

    extras =
      for n <- extra_arbiter_range(o_get(tournament, "extra_arbiters_count")),
          not blank?(o_get(tournament, "arbiter#{n}_name")),
          blank?(o_get(tournament, "arbiter#{n}_fide_id")),
          do: "Arbiter #{n} FIDE ID"

    emails =
      [
        blank?(o_get(tournament, "chief_arbiter_email")) && "Chief arbiter e-mail",
        blank?(o_get(tournament, "organizer_email")) && "Organizer e-mail"
      ]
      |> Enum.filter(& &1)

    fide_id ++ chief ++ deputies ++ extras ++ emails
  end

  # Clamped, same as the public tools page - the count drives IT3 template
  # growth at download time (see
  # `PairingsEngine.Norms.Forms.max_extra_arbiters/0`).
  defp parse_extra_count(nil), do: 0
  defp parse_extra_count(n) when is_integer(n), do: clamp_extra_count(n)

  defp parse_extra_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> clamp_extra_count(n)
      :error -> 0
    end
  end

  defp parse_extra_count(_), do: 0

  defp clamp_extra_count(n), do: n |> max(0) |> min(Forms.max_extra_arbiters())

  defp it4_candidates(players) do
    Enum.filter(players, fn p -> not blank?(Map.get(p.norm_data || %{}, "title_claimed")) end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp claimed_title(player), do: Map.get(player.norm_data || %{}, "title_claimed", "")

  ## ---------- Players - title-norm judgment table sort order ----------

  # Puts the rows worth an arbiter's attention first: a player who's
  # actually achieved a norm, then whoever's closest to one (fewest failing
  # B.01 requirements on their nearest-miss title), then everyone else -
  # rather than the roster's incidental pairing-number order, which has no
  # relationship to who's interesting on this specific page.
  defp players_by_norm_relevance(players, judgments) do
    Enum.sort_by(players, &{norm_relevance_key(judgments[&1.id]), &1.name})
  end

  # Same clause order/precedence as `norm_judgment_label/1` below -
  # `evaluate/1` always returns all three keys, so `games: 0` has to be
  # checked before `best`/`verdicts`, the same way the label does, rather
  # than incidentally matching whichever clause happens to come first.
  defp norm_relevance_key(%{games: 0}), do: 1_000_000
  defp norm_relevance_key(%{best: %{}}), do: 0

  defp norm_relevance_key(%{verdicts: verdicts}) do
    nearest = Enum.min_by(verdicts, fn v -> Enum.count(v.checks, &(not &1.ok?)) end)
    1 + Enum.count(nearest.checks, &(not &1.ok?))
  end

  # nil (no judgment at all - a player `evaluate/1` never returned an entry
  # for) also lands at the very bottom.
  defp norm_relevance_key(_), do: 1_000_000

  ## ---------- automatic B.01 norm judgment display ----------

  # One-line verdict for the players table: the best achieved norm, or the
  # closest miss (fewest failing checks among the evaluated titles), or a
  # plain "no games yet". Full per-check breakdown goes in the cell's
  # `title` tooltip via norm_judgment_details/1.
  defp norm_judgment_label(nil), do: "-"
  defp norm_judgment_label(%{games: 0}), do: "- no counted games"

  defp norm_judgment_label(%{best: %{title: title, performance: perf}}),
    do: "#{title} norm ✓ (Rp #{perf})"

  defp norm_judgment_label(%{verdicts: verdicts}) do
    nearest = Enum.min_by(verdicts, fn v -> Enum.count(v.checks, &(not &1.ok?)) end)
    failing = Enum.count(nearest.checks, &(not &1.ok?))

    "no norm - best #{nearest.title}: #{failing} requirement#{if failing == 1, do: "", else: "s"} short"
  end

  defp norm_judgment_details(nil), do: nil

  defp norm_judgment_details(%{verdicts: verdicts}) do
    Enum.map_join(verdicts, "\n\n", fn v ->
      head = "#{v.title} norm: #{if v.achieved?, do: "ACHIEVED", else: "not achieved"}"

      lines =
        Enum.map_join(v.checks, "\n", fn c ->
          "#{if c.ok?, do: "✓", else: "✗"} #{c.detail}"
        end)

      head <> "\n" <> lines
    end)
  end

  ## ---------- Combined report (festival) helpers (render-only; the two
  ## handle_event clauses that drive @combine_selected/@combine_master live
  ## up by save_norm, grouped with the rest of handle_event/3) ----------

  # `[current tournament id | selected companion ids]`, always leading with
  # the current tournament - the order used both for the master picker's
  # options and for the `combine=` query param, since `NormsController`
  # resolves `master` to an index into this same order.
  defp combine_ids(tournament, other_tournaments, combine_selected) do
    companions =
      other_tournaments
      |> Enum.map(fn {t, _count, _owner?} -> to_string(t.id) end)
      |> Enum.filter(&MapSet.member?(combine_selected, &1))

    [to_string(tournament.id) | companions]
  end

  # `{id, name}` pairs for the master picker: the current tournament plus
  # whichever companions are currently checked (a tournament can only be
  # picked as master once it's part of the combined set).
  defp combine_master_options(tournament, other_tournaments, combine_selected) do
    companions =
      other_tournaments
      |> Enum.filter(fn {t, _count, _owner?} ->
        MapSet.member?(combine_selected, to_string(t.id))
      end)
      |> Enum.map(fn {t, _count, _owner?} -> {to_string(t.id), t.name} end)

    [{to_string(tournament.id), tournament.name} | companions]
  end

  defp combine_href(base_path, ids, master) do
    base_path <> "?" <> URI.encode_query(%{"combine" => Enum.join(ids, ","), "master" => master})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      fide_notice={assigns[:fide_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="norms"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>

          <p class="subtitle" style="margin: 0">{gettext("Norms & FIDE reports")}</p>
        </div>
      </div>
      <PairingsEngineWeb.AuditLive.subnav tournament={@tournament} active={:norms} />
      <p class="hint">
        <.rich_text text={
          gettext(
            "Every report below is generated from the %[officials], the FIDE identifiers on the %[fide] page, and the player list."
          )
        }>
          <:part name="officials">
            <.link navigate={~p"/t/#{@tournament.id}/settings/norms"}>
              {gettext("officials")}
            </.link>
          </:part>

          <:part name="fide">
            <.link navigate={~p"/t/#{@tournament.id}/settings/fide"}>
              {gettext("FIDE settings")}
            </.link>
          </:part>
        </.rich_text>
      </p>

      <div class="card">
        <h2>{gettext("IT3 - Tournament Report Form")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "The whole-tournament report: identity, officials, pairing system, and rated/titled player counts by federation. Always available."
          )}
        </p>
        <.report_blockers_bar blockers={report_blockers(@tournament)} />
        <div class="actions">
          <a
            :if={report_blockers(@tournament) == []}
            class="pe-btn tonal"
            href={~p"/t/#{@tournament.id}/norms/it3"}
          >
            {gettext("Download IT3")}
          </a>

          <button :if={report_blockers(@tournament) != []} class="pe-btn" disabled>
            {gettext("Download IT3")}
          </button>
        </div>
        <.it3_counts_explain counts={@it3_counts} />
      </div>

      <div class="card">
        <h2>{gettext("FA1 / IA1 - Arbiter norm report")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "For an arbiter earning a norm at this tournament. The candidate needn't be a registered player, so fill in their details below - nothing here is saved."
          )}
        </p>

        <%!-- On the form, not on the select - see the comment on the same fix
              in `PairingsEngineWeb.StandingsLive`: LiveView never fires a
              change from a select that has no enclosing form. --%>
        <form
          :if={fa1_candidate_options(@tournament) != []}
          id="fa1-candidate-picker"
          phx-change="pick_fa1_candidate"
          style="display: contents"
        >
          <label class="field">
            <span>{gettext("Pick an arbiter")}</span>
            <select name="fa1_candidate">
              <option value="">{gettext("- type the details by hand -")}</option>

              <option
                :for={{label, key} <- fa1_candidate_options(@tournament)}
                value={key}
                selected={false}
              >
                {label}
              </option>
            </select>
          </label>
        </form>

        <form
          id="fa1-candidate-form"
          method="get"
          action={~p"/t/#{@tournament.id}/norms/fa1"}
          phx-change="fa1_change"
        >
          <div class="form-grid">
            <label class="field">
              <span>{gettext("Last name")}</span>
              <input name="candidate[last_name]" value={@fa1_candidate["last_name"]} />
            </label>

            <label class="field">
              <span>{gettext("First name")}</span>
              <input name="candidate[first_name]" value={@fa1_candidate["first_name"]} />
            </label>

            <label class="field">
              <span>FIDE ID</span>
              <input name="candidate[fide_id]" value={@fa1_candidate["fide_id"]} />
            </label>

            <label class="field">
              <span>{gettext("Federation")}</span>
              <input
                name="candidate[federation]"
                value={@fa1_candidate["federation"]}
                placeholder="BEL"
              />
            </label>
          </div>
          <.report_blockers_bar blockers={report_blockers(@tournament)} />
          <div class="actions">
            <button
              type="submit"
              formaction={~p"/t/#{@tournament.id}/norms/fa1"}
              class="pe-btn tonal"
              disabled={report_blockers(@tournament) != []}
            >
              {gettext("Download FA1 (FIDE Arbiter)")}
            </button>

            <button
              type="submit"
              formaction={~p"/t/#{@tournament.id}/norms/ia1"}
              class="pe-btn tonal"
              disabled={report_blockers(@tournament) != []}
            >
              {gettext("Download IA1 (International Arbiter)")}
            </button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>{gettext("Combined report (festival)")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Running several category groups as separate tournaments? Pick the others below to generate one combined IT3/FA1/IA1 for the whole festival - the master tournament supplies the shared header/schedule fields, and gives the combined report its name."
          )}
        </p>

        <p :if={@other_tournaments == []} class="hint">
          {gettext("You have no other tournaments to combine this one with.")}
        </p>

        <div :if={@other_tournaments != []}>
          <div style="display: flex; flex-direction: column; gap: .4rem; margin-bottom: 1rem">
            <%!-- The current tournament is ALWAYS part of the combined set
                  (combine_ids/3 leads with it) - it used to be silently
                  omitted from this list, which read as "my own tournament
                  is missing from its own festival" (user-reported). Shown
                  checked + disabled so the list matches what actually gets
                  combined. --%>
            <label class="opt-row">
              <input type="checkbox" checked disabled style="width: auto" />
              <span>{@tournament.name}
              <span class="hint">{gettext("- this tournament, always included")}</span></span>
            </label>

            <label :for={{t, _count, _owner?} <- @other_tournaments} class="opt-row">
              <input
                type="checkbox"
                checked={MapSet.member?(@combine_selected, to_string(t.id))}
                phx-click="toggle_combine_tournament"
                phx-value-id={t.id}
                style="width: auto"
              /> <span>{t.name}</span>
            </label>
          </div>

          <p :if={MapSet.size(@combine_selected) == 0} class="hint">
            {gettext("Select at least one tournament above to enable the combined downloads.")}
          </p>

          <div :if={MapSet.size(@combine_selected) > 0}>
            <form id="combine-master-form" phx-change="set_combine_master">
              <label class="field" style="max-width: 360px">
                <span>{gettext("Master tournament (header/schedule/name)")}</span>
                <select name="master">
                  <option
                    :for={
                      {id, name} <-
                        combine_master_options(@tournament, @other_tournaments, @combine_selected)
                    }
                    value={id}
                    selected={id == @combine_master}
                  >
                    {name}
                  </option>
                </select>
              </label>
            </form>

            <div class="actions">
              <a
                class="pe-btn tonal"
                href={
                  combine_href(
                    ~p"/t/#{@tournament.id}/norms/it3",
                    combine_ids(@tournament, @other_tournaments, @combine_selected),
                    @combine_master
                  )
                }
              >
                {gettext("Download combined IT3")}
              </a>
            </div>

            <form method="get" action={~p"/t/#{@tournament.id}/norms/fa1"}>
              <input
                type="hidden"
                name="combine"
                value={
                  Enum.join(combine_ids(@tournament, @other_tournaments, @combine_selected), ",")
                }
              /> <input type="hidden" name="master" value={@combine_master} />
              <div class="form-grid">
                <label class="field">
                  <span>{gettext("Last name")}</span> <input name="candidate[last_name]" />
                </label>

                <label class="field">
                  <span>{gettext("First name")}</span> <input name="candidate[first_name]" />
                </label>

                <label class="field">
                  <span>FIDE ID</span> <input name="candidate[fide_id]" />
                </label>

                <label class="field">
                  <span>{gettext("Federation")}</span>
                  <input name="candidate[federation]" placeholder="BEL" />
                </label>
              </div>

              <div class="actions">
                <button
                  type="submit"
                  formaction={~p"/t/#{@tournament.id}/norms/fa1"}
                  class="pe-btn tonal"
                >
                  {gettext("Download combined FA1 (FIDE Arbiter)")}
                </button>

                <button
                  type="submit"
                  formaction={~p"/t/#{@tournament.id}/norms/ia1"}
                  class="pe-btn tonal"
                >
                  {gettext("Download combined IA1 (International Arbiter)")}
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>

      <div class="card">
        <h2>{gettext("IT4 - Title/Norm report")}</h2>

        <p class="hint" style="margin-top: 0">
          {gettext(
            "Lists every player with a claimed title norm (set below). Up to 40 candidates per file - a tournament with more needs a second IT4 download for the rest."
          )}
        </p>

        <p :if={it4_candidates(@players) == []} class="hint">
          {gettext("No players have a claimed title yet - set one below to include a player.")}
        </p>

        <div :if={it4_candidates(@players) != []} class="card-table-wrap">
          <table class="pe-table">
            <thead>
              <tr>
                <th>{gettext("Candidate")}</th>

                <th>{gettext("Claiming")}</th>

                <th>{gettext("Norm")}</th>
              </tr>
            </thead>

            <tbody>
              <tr :for={p <- it4_candidates(@players)}>
                <td>{p.name}</td>

                <td>{claimed_title(p)}</td>

                <td>{Map.get(p.norm_data || %{}, "norm_description", "")}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="actions">
          <a class="pe-btn tonal" href={~p"/t/#{@tournament.id}/norms/it4"}>{gettext("Download IT4")}</a>
        </div>
      </div>

      <div class="card table-card">
        <h2 style="padding: 16px 16px 0">{gettext("Players - title-norm judgment")}</h2>

        <p class="hint" style="padding: 0 16px">
          {gettext(
            "The \"computed\" column judges each player's games against the FIDE Title Regulations (B.01: game count, score %, titled opponents, federation mix, opponent-rating average, performance) automatically - hover it for the requirement-by-requirement breakdown. The claimed title and the IT4-only fields (norm text, medal/%, event group, federation counts, remarks) stay yours to set."
          )}
        </p>

        <p id="norm-event-type-note" class="hint" style="padding: 0 16px">
          <.rich_text text={
            gettext("Judged as: %{type}. Set under %[settings].",
              type:
                PairingsEngineWeb.SettingsSupport.norm_event_type_label(
                  PairingsEngine.Tournaments.Tournament.effective_norm_event_type(@tournament)
                )
            )
          }>
            <:part name="settings">
              <.link navigate={~p"/t/#{@tournament.id}/settings/norms"}>
                {gettext("Settings, Officials & norms")}
              </.link>
            </:part>
          </.rich_text>
        </p>

        <table class="pe-table">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>

              <th>{gettext("Federation")}</th>

              <th>{gettext("Computed (B.01)")}</th>

              <th>{gettext("Claimed title")}</th>

              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr :for={p <- @players_by_relevance}>
              <td>{p.name}</td>

              <td>{p.federation}</td>

              <td title={norm_judgment_details(@norm_judgments[p.id])}>
                {norm_judgment_label(@norm_judgments[p.id])}
              </td>

              <td>{if claimed_title(p) == "", do: "-", else: claimed_title(p)}</td>

              <td style="text-align: right">
                <button class="pe-btn" phx-click="edit_norm" phx-value-id={p.id}>{gettext(
                  "Edit norm data"
                )}</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.norm_edit_modal
        :if={@editing_norm_player}
        player={@editing_norm_player}
        form={@norm_form}
        error={@norm_error}
        norm_titles={@norm_titles}
      />
    </Layouts.app>
    """
  end

  attr :player, :map, required: true
  attr :form, :map, required: true
  attr :error, :string, default: nil
  attr :norm_titles, :list, required: true

  defp norm_edit_modal(assigns) do
    ~H"""
    <div class="modal-overlay" phx-window-keydown="close_norm" phx-key="escape">
      <form
        id="norm-edit-form"
        class="modal-card"
        phx-submit="save_norm"
        phx-click-away="close_norm"
        role="dialog"
        aria-modal="true"
        aria-labelledby="norm-edit-title"
        tabindex="-1"
        phx-hook="DialogFocus"
        data-dialog
      >
        <h2 id="norm-edit-title">{gettext("Title-norm judgment - %{name}", name: @player.name)}</h2>

        <div class="form-grid">
          <label class="field">
            <span>{gettext("Title claimed")}</span>
            <select name="player[norm_data][title_claimed]">
              <option value="" selected={@form["norm_data"]["title_claimed"] == ""}>
                {gettext("- none -")}
              </option>

              <option
                :for={t <- @norm_titles}
                value={t}
                selected={@form["norm_data"]["title_claimed"] == t}
              >
                {t}
              </option>
            </select>
          </label>

          <label class="field">
            <span>{gettext("Norm (e.g. \"IM norm\")")}</span>
            <input
              name="player[norm_data][norm_description]"
              value={@form["norm_data"]["norm_description"]}
            />
          </label>

          <label class="field">
            <span>{gettext("Medal / %")}</span>
            <input
              name="player[norm_data][medal_percent]"
              value={@form["norm_data"]["medal_percent"]}
            />
          </label>

          <label class="field">
            <span>{gettext("Event / group (e.g. \"U20, Women\")")}</span>
            <input name="player[norm_data][event_group]" value={@form["norm_data"]["event_group"]} />
          </label>

          <label class="field">
            <span>{gettext("Federations participating")}</span>
            <input
              type="number"
              name="player[norm_data][fed_participating]"
              value={@form["norm_data"]["fed_participating"]}
            />
          </label>

          <label class="field">
            <span>{gettext("Federations eligible (members)")}</span>
            <input
              type="number"
              name="player[norm_data][fed_members]"
              value={@form["norm_data"]["fed_members"]}
            />
          </label>

          <label class="field" style="grid-column: 1 / -1">
            <span>{gettext("Remarks")}</span>
            <input name="player[norm_data][remarks]" value={@form["norm_data"]["remarks"]} />
          </label>
        </div>

        <p :if={@error} class="error-note">{@error}</p>

        <div class="actions">
          <button type="submit" class="pe-btn primary">{gettext("Save")}</button>
          <button type="button" class="pe-btn" phx-click="close_norm">{gettext("Cancel")}</button>
        </div>
      </form>
    </div>
    """
  end
end
