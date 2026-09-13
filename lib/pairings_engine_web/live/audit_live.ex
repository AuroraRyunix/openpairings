defmodule PairingsEngineWeb.AuditLive do
  @moduledoc """
  The per-tournament audit trail (see `PairingsEngine.Audit`): a paginated,
  newest-first list of every state-changing action, each rendered into a
  human-readable sentence by `describe/1`, filterable by action category.

  Access control is the same as every other tournament page -
  `Tournaments.get_authorized_tournament!/2` (owner or accepted
  collaborator); a non-collaborator 404s exactly like anywhere else.

  `describe/1` and its helpers below also render the OTHER kind of audit
  row - machine-wide acts with no tournament, written by
  `PairingsEngine.Audit.log_system/3` and shown on
  `PairingsEngineWeb.AdminLive` rather than here. See the "machine-wide
  rows" section further down for why this page's own queries never surface
  them.

  ## Language

  A row stores an action code and structured `details`, never a sentence,
  so every row - including ones written long before this page was
  translated - is worded at render time, in the reader's language. The
  action code itself is an identifier and is never translated (it is what
  an unknown action falls back to).

  A few `details` values are prose that was already a finished string when
  the row was written, and they are shown verbatim, framed by a translated
  sentence: a restore point's name (`snapshot.restored`'s `restored_to` is
  the snapshot's own summary, which the History page shows as-is too), the
  federation upload's error message (`swar.publish_failed`'s `error`), and
  the confirmation line a hand edit of a paired round stored as its
  `summary` - the only record of which players that edit moved. Rewording
  them here would mean pattern-matching English, and rewriting them in the
  table would be rewriting the record.

  Field names in a settings or player diff stay the schema's own
  identifiers (`rounds_count`, `swiss_match_format`) in every language - see
  `PairingsEngineWeb.SettingsSupport.compliance_setting_label/1` for why the
  trail says `swiss_match_format` rather than a label. Words that are
  values rather than identifiers - on/off, a role, a phone's access level -
  go through the same msgids the arbiter sees for them elsewhere.
  """
  use PairingsEngineWeb, :live_view

  alias PairingsEngine.{Audit, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  @per_page 50

  # Action-code buckets for the category filter. `:all` means "no filter";
  # every other bucket passes its explicit list of codes to
  # `Audit.list_for_tournament/2`. Novel codes not listed here still appear
  # under "All". The button labels are in `category_label/1`: this is a
  # module attribute, evaluated at compile time, so it cannot hold anything
  # translated.
  @categories [
    {"all", :all},
    {"players", ~w(player.created player.updated player.deleted player.ratings_refreshed
        registration.accepted registration.discarded)},
    {"pairings", ~w(pairing.round_paired pairing.result_entered pairing.result_changed
        pairing.round_deleted pairing.results_imported)},
    {"settings", ~w(tournament.settings_updated tournament.locked_field_changed
        tournament.fide_compliance_lost
        logo.uploaded logo.cleared
        forbidden_pairing.added forbidden_pairing.removed
        category.created category.removed)},
    {"standings", ~w(standings.manual_reorder standings.manual_ranking_enabled
        standings.manual_ranking_disabled standings.manual_reseeded
        standings.extra_points_applied)},
    {"imports", ~w(import.swar import.trf import.json)},
    {"collaborators", ~w(collaborator.invited collaborator.accepted collaborator.declined
        collaborator.removed)},
    {"tournament",
     ~w(tournament.created tournament.deleted tournament.restored tournament.purged)}
  ]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    tournament = Tournaments.get_authorized_tournament!(socket.assigns.current_scope, id)

    socket =
      assign(socket,
        tournament: tournament,
        page_title: page_title(socket.assigns.live_action, tournament),
        category: "all",
        page: 0
      )

    socket =
      case socket.assigns.live_action do
        :explain -> assign(socket, paired_rounds: Engine.paired_rounds_count(tournament.id))
        _ -> load_entries(socket)
      end

    {:ok, socket}
  end

  defp page_title(:explain, tournament),
    do: gettext("%{name} · Pairing rationale", name: tournament.name)

  defp page_title(_, tournament), do: gettext("%{name} · Audit trail", name: tournament.name)

  @impl true
  def handle_event("filter", %{"category" => category}, socket) do
    {:noreply, socket |> assign(category: category, page: 0) |> load_entries()}
  end

  def handle_event("page", %{"delta" => delta}, socket) do
    page = max(socket.assigns.page + String.to_integer(delta), 0)
    {:noreply, socket |> assign(page: page) |> load_entries()}
  end

  defp load_entries(socket) do
    %{tournament: t, category: category, page: page} = socket.assigns
    actions = category_actions(category)

    opts =
      [limit: @per_page, offset: page * @per_page]
      |> maybe_actions(actions)

    entries = Audit.list_for_tournament(t.id, opts)
    total = Audit.count_for_tournament(t.id, count_opts(actions))

    assign(socket, entries: entries, total: total)
  end

  defp maybe_actions(opts, :all), do: opts
  defp maybe_actions(opts, actions), do: Keyword.put(opts, :actions, actions)

  defp count_opts(:all), do: []
  defp count_opts(actions), do: [actions: actions]

  defp category_actions(key) do
    case Enum.find(@categories, fn {k, _codes} -> k == key end) do
      {_k, :all} -> :all
      {_k, codes} -> codes
      nil -> :all
    end
  end

  defp categories, do: @categories

  defp category_label("all"), do: gettext("All")
  defp category_label("players"), do: gettext("Players")
  defp category_label("pairings"), do: gettext("Pairings")
  defp category_label("settings"), do: gettext("Settings")
  defp category_label("standings"), do: gettext("Standings")
  defp category_label("imports"), do: gettext("Imports")
  defp category_label("collaborators"), do: gettext("Collaborators")
  defp category_label("tournament"), do: gettext("Tournament")

  ## ---------- rendering the log ----------
  #
  # Every clause below returns one or more WHOLE sentences, each its own
  # msgid, with the row's values as bindings. Where a value is a word rather
  # than data (on/off, up/down, which pairing system, which failed step),
  # the clause picks between complete sentences instead of interpolating the
  # word - Dutch does not put a clause's pieces where English does. Two
  # sentences in one row (a result and the phone it came from, a round and
  # its bye) are joined by `sentences/1`, never by gluing a fragment on.
  #
  # `test/pairings_engine_web/live/audit_describe_test.exs` reads this file
  # and fails for a `describe/2` clause it has no Dutch rendering of.

  @doc """
  Renders one audit row's `action` + `details` into a readable sentence, in
  the current Gettext locale. `details` maps come back from the JSON column
  with string keys.
  """
  def describe(%{action: action, details: details}), do: describe(action, details || %{})

  def describe(action, details) when not is_map(details), do: describe(action, %{})

  def describe("player.created", d) do
    case d["rating"] do
      rating when is_integer(rating) and rating > 0 ->
        gettext("Registered player %{name} (rating %{rating}).",
          name: name(d, "player_name"),
          rating: rating
        )

      _ ->
        gettext("Registered player %{name}.", name: name(d, "player_name"))
    end
  end

  def describe("player.updated", d) do
    case changes(d) do
      nil ->
        gettext("Updated player %{name}, but no tracked field changed.",
          name: name(d, "player_name")
        )

      changes ->
        gettext("Updated player %{name}: %{changes}.",
          name: name(d, "player_name"),
          changes: changes
        )
    end
  end

  def describe("player.deleted", d),
    do: gettext("Deleted player %{name}.", name: name(d, "player_name"))

  def describe("registration.accepted", d),
    do: gettext("Accepted an entry from the results site: %{name}.", name: name(d, "player_name"))

  def describe("registration.discarded", d),
    do:
      gettext("Turned down an entry from the results site: %{name}.",
        name: name(d, "player_name")
      )

  def describe("player.ratings_refreshed", d),
    do:
      ngettext(
        "Refreshed ratings for %{count} player.",
        "Refreshed ratings for %{count} players.",
        count(d, "players_updated")
      )

  def describe("player.clubs_refreshed", d),
    do:
      ngettext(
        "Refreshed clubs for %{count} player.",
        "Refreshed clubs for %{count} players.",
        count(d, "players_updated")
      )

  # The three right-click actions on a Players column header. Each writes the
  # whole roster, so `player_count` is every player in the tournament, not
  # the ones whose value happened to change.
  def describe("player.bulk_absent_set", d) do
    count = count(d, "player_count")

    if truthy?(d["absent"]),
      do:
        ngettext(
          "Marked every player absent for the whole tournament (%{count} player).",
          "Marked every player absent for the whole tournament (%{count} players).",
          count
        ),
      else:
        ngettext(
          "Marked every player present for the whole tournament (%{count} player).",
          "Marked every player present for the whole tournament (%{count} players).",
          count
        )
  end

  def describe("player.bulk_paid_set", d) do
    count = count(d, "player_count")

    case d["paid"] do
      "paid" ->
        ngettext(
          "Marked every player as paid (%{count} player).",
          "Marked every player as paid (%{count} players).",
          count
        )

      "nopaid" ->
        ngettext(
          "Marked every player as not paid (%{count} player).",
          "Marked every player as not paid (%{count} players).",
          count
        )

      "gratis" ->
        ngettext(
          "Marked every player as gratis (%{count} player).",
          "Marked every player as gratis (%{count} players).",
          count
        )

      # `Tournaments.set_all_players_paid/2` refuses anything else, so only a
      # hand-edited backup gets here - shown as the stored code.
      other ->
        ngettext(
          "Set every player's registration fee status to %{status} (%{count} player).",
          "Set every player's registration fee status to %{status} (%{count} players).",
          count,
          status: shown(other)
        )
    end
  end

  def describe("player.bulk_category_set", d) do
    count = count(d, "player_count")
    category = name(d, "category")

    if truthy?(d["added"]),
      do:
        ngettext(
          "Added category %{category} to every player (%{count} player).",
          "Added category %{category} to every player (%{count} players).",
          count,
          category: category
        ),
      else:
        ngettext(
          "Removed category %{category} from every player (%{count} player).",
          "Removed category %{category} from every player (%{count} players).",
          count,
          category: category
        )
  end

  def describe("pairing.round_paired", d), do: describe_round_paired(d)

  def describe("pairing.result_entered", d),
    do: sentences([result_sentence(:entered, d), phone_sentence(d)])

  # Before 2026-08-03 there was no `pairing.result_cleared`: blanking a board
  # was logged as a change TO nothing. Those rows are still in every older
  # database, and "changed from 1-0 to -" is a worse description of what the
  # arbiter did than the one the app gives the same act today.
  def describe("pairing.result_changed", d) do
    kind = if blank?(d["to"]), do: :cleared, else: :changed
    sentences([result_sentence(kind, d), phone_sentence(d)])
  end

  def describe("pairing.result_cleared", d),
    do: sentences([result_sentence(:cleared, d), phone_sentence(d)])

  def describe("pairing.round_deleted", d),
    do: gettext("Unpaired round %{round}.", round: value(d, "round"))

  def describe("pairing.results_imported", d),
    do:
      ngettext(
        "Imported %{count} result for round %{round} (CSV).",
        "Imported %{count} results for round %{round} (CSV).",
        count(d, "results_set"),
        round: value(d, "round")
      )

  # ---------- a paired round, edited by hand ----------
  #
  # `PairingsLive.apply_confirm/2` stores two things for every one of these:
  # the round, and `summary` - the subtitle of the confirmation the arbiter
  # pressed, built in English from the players' names at that moment ("Chris
  # Maes takes Bram Claes's place"). Nothing else about who moved where, or on
  # which board, was ever stored. So the sentence says which kind of edit it
  # was and in which round, in the reader's language, and the summary follows
  # it quoted as recorded (`recorded_summary/1`) - the treatment a restore
  # point's name gets in `snapshot.restored`, and for the same reason.
  def describe("pairing.players_swapped", d),
    do:
      hand_edit(
        gettext("Edited round %{round} by hand: swapped two players' seats.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.player_substituted", d),
    do:
      hand_edit(
        gettext(
          "Edited round %{round} by hand: replaced a seated player with one who was not playing.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.seat_vacated", d),
    do:
      hand_edit(
        gettext(
          "Edited round %{round} by hand: marked a seated player absent for this round and left their seat empty.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.bye_awarded", d),
    do:
      hand_edit(
        gettext(
          "Edited round %{round} by hand: awarded a bye to the player left without an opponent.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.seat_filled", d),
    do:
      hand_edit(
        gettext(
          "Edited round %{round} by hand: put a player who was not playing into an empty seat.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.pool_paired", d),
    do:
      hand_edit(
        gettext(
          "Edited round %{round} by hand: paired two players who were not playing on a new board.",
          round: value(d, "round")
        ),
        d
      )

  def describe("pairing.deleted", d),
    do:
      hand_edit(
        gettext("Edited round %{round} by hand: deleted an empty board.",
          round: value(d, "round")
        ),
        d
      )

  # Only a board with both seats empty can be hidden or shown again
  # (`Tournaments.set_pairing_hidden/3`), so "empty" is true of every row.
  def describe("pairing.hidden", d),
    do:
      gettext("Hid empty board %{board} of round %{round} from the pairings.",
        board: value(d, "board"),
        round: value(d, "round")
      )

  def describe("pairing.unhidden", d),
    do:
      gettext("Showed empty board %{board} of round %{round} on the pairings again.",
        board: value(d, "board"),
        round: value(d, "round")
      )

  # ---------- publishing pairings and standings ----------
  #
  # The four controls of the 2026-09-11 publishing model - see "Publishing
  # pairings and standings" in `PairingsEngine.Tournaments`, whose rules
  # these sentences restate. Pairings are published through round N (every
  # round up to it); taking round N's pairings down takes every later round
  # with it and caps public standings at after round N-1. Standings are
  # published as they stood after round N; taking those down drops them back
  # to after round N-1 and takes the pairings of every round after N with
  # them.
  # Round 0 is the field before a game is played, which the page calls
  # "Initial standings", so it is never "after round 0" here either.
  #
  # The two "go no further than" sentences state a ceiling rather than a
  # before-and-after, because the row does not record where public standings
  # stood before the click - and the ceiling is true whatever they were.
  def describe("pairing.pairings_published", d),
    do:
      gettext("Published the pairings up to and including round %{round}.",
        round: value(d, "through_round")
      )

  def describe("pairing.pairings_unpublished", d) do
    case d["from_round"] do
      # 0 is refused before anything is written. Were it ever stored it would
      # mean what 1 means: every round, with the standings ceiling floored at
      # the initial standings (`maybe_lower_standings_through/2`).
      round when round in [0, 1] ->
        sentences([
          gettext("Took the pairings of every round off the public page."),
          gettext("Public standings now go no further than the initial standings.")
        ])

      round when is_integer(round) and round > 1 ->
        sentences([
          pairings_taken_down(round),
          gettext("Public standings now go no further than after round %{round}.",
            round: round - 1
          )
        ])

      _ ->
        pairings_taken_down(value(d, "from_round"))
    end
  end

  # How far the rationale page has worked out a round's account. Neither ever
  # touches a board - `Pairing.reexplain_round/2` and `deepen_round/2` write
  # the account and nothing else - which is the fact the sentences end on.
  def describe("pairing.account_recomputed", d) do
    recomputed =
      ngettext(
        "Recomputed the pairing rationale of %{count} round from the boards as played. No pairing was changed.",
        "Recomputed the pairing rationale of %{count} rounds from the boards as played. No pairing was changed.",
        count(d, "recomputed")
      )

    left =
      case skipped_count(d) do
        0 ->
          nil

        skipped ->
          ngettext(
            "%{count} other round was left unchanged.",
            "%{count} other rounds were left unchanged.",
            skipped
          )
      end

    sentences([recomputed, left])
  end

  def describe("pairing.account_deepened", d),
    do:
      gettext(
        "Worked out every alternative in the pairing rationale of round %{round}. No pairing was changed.",
        round: value(d, "round")
      )

  def describe("tournament.settings_updated", d) do
    case changes(d) do
      nil -> gettext("Updated tournament settings, but no tracked field changed.")
      changes -> gettext("Updated tournament settings: %{changes}.", changes: changes)
    end
  end

  # A locked-field change is spelled out on its own line, not left to be
  # found inside `changes/1` above - see
  # `PairingsEngineWeb.SettingsSupport.log_unlocked_field_changes/4` for why
  # this is a separate audit action rather than folded into the bulk
  # settings diff.
  def describe("tournament.locked_field_changed", d),
    do:
      gettext("Overrode the round-1 freeze on %{field}: %{from} → %{to}.",
        field: value(d, "field"),
        from: shown(d["from"]),
        to: shown(d["to"])
      )

  # Its own line for the same reason as the one above, and one more: the
  # round is the fact VCL4THP asks for by name, and a `###` TRF comment is
  # eventually built from it. Buried inside a bulk settings diff it would be
  # a field name among six others.
  #
  # Round 0 is a real recorded value - a tournament can be non-compliant
  # before its first round is paired - so it gets words rather than a
  # number nobody would read as a round.
  def describe("tournament.fide_compliance_lost", d) do
    setting = value(d, "setting")
    code = value(d, "code")

    case d["round"] do
      0 ->
        gettext(
          "%{setting} took this tournament out of FIDE handling before the first round was paired (%{code}).",
          setting: setting,
          code: code
        )

      round when is_integer(round) ->
        gettext(
          "%{setting} took this tournament out of FIDE handling in round %{round} (%{code}).",
          setting: setting,
          round: round,
          code: code
        )

      _ ->
        gettext(
          "%{setting} took this tournament out of FIDE handling at an unrecorded round (%{code}).",
          setting: setting,
          code: code
        )
    end
  end

  def describe("tournament.created", d) do
    name = name(d, "name")

    case d["pairing_system"] do
      "swiss" ->
        gettext("Created tournament %{name} (Swiss).", name: name)

      "round_robin" ->
        gettext("Created tournament %{name} (round robin).", name: name)

      "keizer" ->
        gettext("Created tournament %{name} (Keizer).", name: name)

      system when system in [nil, ""] ->
        gettext("Created tournament %{name}.", name: name)

      # A system this version does not know is shown as its code - an
      # identifier, not a word to translate.
      system ->
        gettext("Created tournament %{name} (%{system}).", name: name, system: text(system))
    end
  end

  def describe("tournament.deleted", d),
    do: gettext("Moved tournament %{name} to the recycle bin.", name: name(d, "name"))

  def describe("tournament.restored", d),
    do: gettext("Restored tournament %{name} from the recycle bin.", name: name(d, "name"))

  def describe("tournament.purged", d),
    do: gettext("Permanently deleted tournament %{name}.", name: name(d, "name"))

  def describe("import.swar", d),
    do: gettext("Imported tournament %{name} from a SWAR file.", name: name(d, "name"))

  def describe("import.trf", d),
    do: gettext("Imported tournament %{name} from a TRF file.", name: name(d, "name"))

  def describe("import.json", d),
    do: gettext("Imported tournament %{name} from a JSON backup.", name: name(d, "name"))

  def describe("collaborator.invited", d),
    do: gettext("Invited %{email} as a collaborator.", email: value(d, "email"))

  def describe("collaborator.accepted", d),
    do: gettext("Accepted the collaboration invite (%{email}).", email: value(d, "email"))

  def describe("collaborator.declined", d),
    do: gettext("Declined the collaboration invite (%{email}).", email: value(d, "email"))

  def describe("collaborator.removed", d),
    do: gettext("Removed collaborator %{email}.", email: value(d, "email"))

  def describe("forbidden_pairing.added", d),
    do:
      gettext("Added a forbidden pairing (players #%{a} and #%{b}).",
        a: value(d, "player_a_id"),
        b: value(d, "player_b_id")
      )

  def describe("forbidden_pairing.removed", d),
    do:
      gettext("Removed a forbidden pairing (players #%{a} and #%{b}).",
        a: value(d, "player_a_id"),
        b: value(d, "player_b_id")
      )

  def describe("category.created", d),
    do: gettext("Added category %{name}.", name: name(d, "name"))

  def describe("category.removed", d),
    do: gettext("Removed category %{name}.", name: name(d, "name"))

  # One save for the whole rules table, prize counts included; the row
  # records that it happened and nothing about what it said.
  def describe("category.rules_updated", _d),
    do: gettext("Saved the category rules and prize counts.")

  # `matched` counts the players who landed in at least one ruled category,
  # `total` every player the rules were run over.
  def describe("category.auto_assigned", d),
    do:
      ngettext(
        "Assigned categories by rule to %{matched} of %{count} player.",
        "Assigned categories by rule to %{matched} of %{count} players.",
        count(d, "total"),
        matched: value(d, "matched")
      )

  def describe("logo.uploaded", _d), do: gettext("Uploaded a tournament logo.")
  def describe("logo.cleared", _d), do: gettext("Removed the tournament logo.")

  def describe("standings.manual_reorder", d) do
    name = name(d, "player_name")

    case d["direction"] do
      "up" -> gettext("Moved %{name} up in the manual standings order.", name: name)
      "down" -> gettext("Moved %{name} down in the manual standings order.", name: name)
      _ -> gettext("Moved %{name} in the manual standings order.", name: name)
    end
  end

  def describe("standings.manual_ranking_enabled", _d),
    do: gettext("Enabled manual standings ordering.")

  def describe("standings.manual_ranking_disabled", _d),
    do: gettext("Disabled manual standings ordering.")

  def describe("standings.manual_reseeded", _d),
    do: gettext("Re-seeded the manual standings order from the computed ranking.")

  def describe("standings.extra_points_applied", d),
    do:
      ngettext(
        "Applied extra-points bands to %{matched} of %{count} player.",
        "Applied extra-points bands to %{matched} of %{count} players.",
        count(d, "total"),
        matched: value(d, "matched")
      )

  # The standings half of the publishing controls - see the comment above
  # `pairing.pairings_published`.
  def describe("standings.published", d) do
    case d["through_round"] do
      0 ->
        gettext("Published the initial standings.")

      _ ->
        gettext("Published the standings after round %{round}.",
          round: value(d, "through_round")
        )
    end
  end

  def describe("standings.unpublished", d) do
    case d["from_round"] do
      0 ->
        sentences([
          gettext(
            "Took the initial standings off the public page, together with any public pairings."
          ),
          gettext("No standings are public now.")
        ])

      1 ->
        sentences([
          standings_taken_down(1),
          gettext("Public standings now go no further than the initial standings.")
        ])

      round when is_integer(round) and round > 1 ->
        sentences([
          standings_taken_down(round),
          gettext("Public standings now go no further than after round %{round}.",
            round: round - 1
          )
        ])

      _ ->
        standings_taken_down(value(d, "from_round"))
    end
  end

  # Nothing emits this any more: 0.60.0 replaced the Standings page's
  # "Publish the starting rank before round 1" switch with publishing the
  # initial standings (`standings.published` through round 0). Kept for the
  # rows 0.59.0 wrote, for the reason `public_pages.toggled` below is kept.
  def describe("standings.starting_rank_toggled", d) do
    if truthy?(d["enabled"]),
      do: gettext("Turned on publishing the starting rank before round 1."),
      else: gettext("Turned off publishing the starting rank before round 1.")
  end

  def describe("tournament.archived", d),
    do: gettext("Archived tournament %{name} - it is now read-only.", name: name(d, "name"))

  def describe("tournament.unarchived", d),
    do: gettext("Unarchived tournament %{name} - it is editable again.", name: name(d, "name"))

  # Spelled out rather than summarised. When two copies of one tournament
  # turn up months later disagreeing about board 4, this row is the only
  # record of which of them was abandoned, and the sentence has to say so
  # without the reader already knowing what a hand-off token is.
  def describe("tournament.handoff_forced", d) do
    case d["was_handed_off_to"] do
      to when is_binary(to) and to != "" ->
        gettext(
          "Forced the hand-off lock on %{name} open without the token. The copy handed to %{to} still exists and must not be used again.",
          name: name(d, "name"),
          to: to
        )

      _ ->
        gettext(
          "Forced the hand-off lock on %{name} open without the token. The copy it was handed to still exists and must not be used again.",
          name: name(d, "name")
        )
    end
  end

  # The four steps of `PairingsEngine.Handoff`, one row each: handed off and
  # given back lock the copy they happen on; received and brought back leave
  # the copy they happen on live. Each place is what the arbiter typed or
  # the other machine called itself, so it is shown as recorded.
  def describe("handoff.handed_off", d) do
    name = name(d, "name")

    case present(d["to"]) do
      nil ->
        gettext("Handed %{name} off to another copy. This copy became read-only.", name: name)

      to ->
        gettext("Handed %{name} off to %{to}. This copy became read-only.", name: name, to: to)
    end
  end

  def describe("handoff.received", d) do
    name = name(d, "name")

    received =
      case {present(d["from"]), present(d["address"])} do
        {nil, nil} ->
          gettext("Received %{name} as a hand-off from another copy.", name: name)

        {from, address} when is_nil(address) or is_nil(from) ->
          gettext("Received %{name} as a hand-off from %{from}.",
            name: name,
            from: from || address
          )

        {from, address} ->
          gettext("Received %{name} as a hand-off from %{from} (%{address}).",
            name: name,
            from: from,
            address: address
          )
      end

    sentences([
      received,
      gettext(
        "This copy is now the one in use, and the copy it came from stays locked until it is given back."
      )
    ])
  end

  # `to` falls back to the origin's address when it did not name itself, so
  # the address is only added when it says something `to` did not.
  def describe("handoff.returned", d) do
    name = name(d, "name")
    address = present(d["address"])

    case present(d["to"]) do
      nil ->
        gettext("Gave %{name} back to the copy it came from. This copy became read-only.",
          name: name
        )

      to when is_nil(address) or address == to ->
        gettext("Gave %{name} back to %{to}. This copy became read-only.", name: name, to: to)

      to ->
        gettext("Gave %{name} back to %{to} (%{address}). This copy became read-only.",
          name: name,
          to: to,
          address: address
        )
    end
  end

  # Every version that shipped hand-off (0.22.0 on) brings a tournament back
  # by replacing this copy's contents with the returning file's, behind a
  # restore point it refuses to go ahead without - so both sentences hold for
  # every row there is.
  def describe("handoff.released", d) do
    name = name(d, "name")

    brought =
      case present(d["from"]) do
        nil ->
          gettext(
            "Brought %{name} back from the copy it was handed to, with its returning file: this copy now holds what was played there and can be edited again.",
            name: name
          )

        from ->
          gettext(
            "Brought %{name} back from %{from} with its returning file: this copy now holds what was played there and can be edited again.",
            name: name,
            from: from
          )
      end

    sentences([brought, gettext("The state it replaced was saved as a restore point first.")])
  end

  def describe("tournament.duplicated", d),
    do: gettext("Duplicated tournament %{name} into a new copy.", name: name(d, "from_name"))

  def describe("tournament.left", d),
    do: gettext("Left tournament %{name} (gave up collaborator access).", name: name(d, "name"))

  # `restored_to` is the restore point's own summary, copied in when the
  # row was written. For a point the app took itself that summary is an
  # English sentence ("Before unpairing round 3") and no later version can
  # reword it without guessing at English; it is shown quoted, as the
  # point's name, exactly as the History page lists it.
  def describe("snapshot.restored", d) do
    case d["restored_to"] do
      label when is_binary(label) and label != "" ->
        gettext(
          ~s(Restored the tournament back to the restore point "%{label}". The state it replaced was saved first.),
          label: label
        )

      _ ->
        gettext(
          "Restored the tournament back to an earlier restore point. The state it replaced was saved first."
        )
    end
  end

  # The one restore point nobody's action forced - the arbiter asked for it
  # from the History page, optionally naming it.
  def describe("snapshot.manual", d) do
    case d["label"] do
      label when is_binary(label) and label != "" ->
        gettext(~s(Saved a restore point: "%{label}".), label: label)

      _ ->
        gettext("Saved a restore point.")
    end
  end

  def describe("categories.toggled", d) do
    if truthy?(d["enabled"]),
      do: gettext("Turned categories on."),
      else: gettext("Turned categories off.")
  end

  def describe("pair_by_category.toggled", d) do
    if truthy?(d["enabled"]),
      do: gettext("Turned per-category pairing on."),
      else: gettext("Turned per-category pairing off.")
  end

  # Nothing emits this any more - the local public pages were removed on
  # 2026-08-29 - and it stays anyway. The audit trail is a RECORD, and every
  # database that ran an earlier version still holds rows with this code.
  # Deleting the clause would not crash them (there is a fallback below), it
  # would quietly turn "Turned the public pages off." into a generic line,
  # which is losing evidence about what somebody actually did.
  #
  # Its neighbour below is still emitted, by the address rotation on the
  # OpenResults settings page.
  def describe("public_pages.toggled", d) do
    if truthy?(d["enabled"]),
      do: gettext("Turned the public pages on."),
      else: gettext("Turned the public pages off.")
  end

  def describe("public_pages.link_rotated", _d),
    do: gettext("Generated a new public link - the previous one stopped working.")

  def describe("registration.toggled", d) do
    if truthy?(d["open"]),
      do: gettext("Opened the public registration form."),
      else: gettext("Closed the public registration form.")
  end

  # ---------- the results site (Settings > Results site) ----------

  # Turning it off stops sending; it does not take down what was already
  # sent (that is `openresults.taken_down`), and the sentence says so because
  # the two are exactly what gets confused afterwards.
  def describe("openresults.toggled", d) do
    if truthy?(d["enabled"]),
      do: gettext("Turned on publishing this tournament to the results site."),
      else:
        gettext(
          "Turned off publishing this tournament to the results site. Anything already sent stays there."
        )
  end

  def describe("openresults.listed", d) do
    if truthy?(d["listed"]),
      do: gettext("Listed this tournament on the results site's front page."),
      else:
        gettext("Took this tournament off the results site's front page. Its link still works.")
  end

  # The state after the save, not a diff: the form saves every box at once.
  # `hidden` holds the public-display keys that are off (`rating`, `club`) -
  # the snapshot contract's identifiers, shown as stored for the reason a
  # settings diff shows `rounds_count` - and `hidden_tiebreaks` the tie-break
  # codes. A row from before tie-breaks could be hidden has no
  # `hidden_tiebreaks`, and says nothing about them.
  def describe("openresults.display", d) do
    hidden = as_list(d["hidden"])
    tiebreaks = as_list(d["hidden_tiebreaks"])

    sentences([
      gettext("Changed what the public page shows."),
      if(hidden == [] and tiebreaks == [], do: gettext("Nothing is hidden.")),
      if(hidden != [], do: gettext("Hidden: %{fields}.", fields: shown(hidden))),
      if(tiebreaks != [],
        do: gettext("Hidden tie-breaks: %{tiebreaks}.", tiebreaks: shown(tiebreaks))
      )
    ])
  end

  def describe("openresults.taken_down", d),
    do:
      gettext(
        "Removed this tournament from the results site (address %{slug}): its page, its history there and any entries collected for it were deleted. Nothing here was touched.",
        slug: value(d, "slug")
      )

  def describe("openresults.claim_adopted", d),
    do:
      gettext(
        "Took over publishing the tournament the imported backup came from (address %{slug}). This copy now publishes there, and can remove it.",
        slug: value(d, "slug")
      )

  def describe("openresults.claim_discarded", _d),
    do:
      gettext(
        "Threw away the publishing key the imported backup carried. This copy publishes to its own address, and can neither update nor remove the tournament the backup came from."
      )

  # Public publishing's consent dialog, answered from this tournament's
  # settings; `publishing.public_consent_given` below is the same answer
  # given on Connections. Declining is only recorded here, because only this
  # page switches publishing back off when the answer is no.
  def describe("openresults.public_consent_given", d), do: consent_given(d)

  def describe("openresults.public_consent_declined", d),
    do:
      gettext(
        "Declined to publish on %{host}: nothing was sent, and publishing was switched off for this tournament.",
        host: value(d, "host")
      )

  def describe("pairing.result_clear_attempted", d),
    do:
      gettext("Attempted to clear the result on board %{board} (round %{round}) - refused.",
        board: value(d, "board"),
        round: value(d, "round")
      )

  def describe("swar.published", d),
    do:
      gettext(
        "Published the SWAR results page to the federation's results site (guid %{guid}).",
        guid: value(d, "guid")
      )

  # `error` is the message the upload returned, already a finished string
  # when it was recorded - often the federation server's own words - so it
  # is quoted as it was, after a sentence that says which step failed.
  def describe("swar.publish_failed", d) do
    error = value(d, "error")

    case d["step"] do
      "upload" ->
        gettext(
          "Could not upload the SWAR results page to the federation's results site: %{error}",
          error: error
        )

      "index" ->
        gettext(
          "Uploaded the SWAR results page, but the federation's results site did not confirm it was indexed: %{error}",
          error: error
        )

      _ ->
        gettext("Could not publish the SWAR results page: %{error}", error: error)
    end
  end

  # ---------- machine-wide rows (PairingsEngine.Audit.log_system/3) ----------
  #
  # These never carry a tournament_id, so they never reach this page's own
  # `load_entries/1` (every query there filters `tournament_id == ^id`, and
  # SQL's `NULL = x` is never true) - only `PairingsEngineWeb.AdminLive`
  # queries `Audit.list_machine_wide/1` and renders them, through this same
  # `describe/1`. They are deliberately absent from `@categories`: a filter
  # bucket for rows that can never appear on this page would be dead weight
  # here, not a feature.
  def describe("admin.role_changed", d) do
    email = value(d, "email")

    case d["changed_fields"] do
      %{"role" => [from, to]} ->
        gettext("Changed the role of %{email} from %{from} to %{to}.",
          email: email,
          from: role_name(from),
          to: role_name(to)
        )

      _ ->
        case changes(d) do
          nil ->
            gettext("Changed the role of %{email}.", email: email)

          changes ->
            gettext("Changed the role of %{email}: %{changes}.", email: email, changes: changes)
        end
    end
  end

  def describe("backup.downloaded", d),
    do: gettext("Downloaded a backup (%{filename}).", filename: value(d, "filename"))

  def describe("publishing.endpoint_changed", d) do
    case {d["changed_fields"], changes(d)} do
      {%{"endpoint" => [from, to]}, _} ->
        gettext("Changed the publishing address from %{from} to %{to}.",
          from: shown(from),
          to: shown(to)
        )

      {_, nil} ->
        gettext("Changed the publishing address.")

      {_, changes} ->
        gettext("Changed the publishing address: %{changes}.", changes: changes)
    end
  end

  def describe("publishing.public_base_changed", d) do
    case {d["changed_fields"], changes(d)} do
      {%{"public_base" => [from, to]}, _} ->
        gettext("Changed the address given to spectators from %{from} to %{to}.",
          from: shown(from),
          to: shown(to)
        )

      {_, nil} ->
        gettext("Changed the address given to spectators.")

      {_, changes} ->
        gettext("Changed the address given to spectators: %{changes}.", changes: changes)
    end
  end

  def describe("publishing.token_replaced", _d), do: gettext("Replaced the publishing token.")
  def describe("publishing.token_cleared", _d), do: gettext("Cleared the publishing token.")
  def describe("publishing.public_consent_given", d), do: consent_given(d)

  def describe("fide.sync_started", _d), do: gettext("Started a FIDE rating list sync.")

  # Fallback for any code not explicitly handled: the code itself, which is
  # an identifier and reads the same in every language.
  def describe(action, _details), do: text(action)

  defp describe_round_paired(d) do
    round = value(d, "round")
    bye_count = count(d, "bye_count")
    floater_count = count(d, "floater_count")

    boards = ngettext("%{count} board", "%{count} boards", count(d, "board_count"))
    byes = ngettext("%{count} bye", "%{count} byes", bye_count)
    floaters = ngettext("%{count} floater", "%{count} floaters", floater_count)

    paired =
      cond do
        bye_count > 0 and floater_count > 0 ->
          gettext("Paired round %{round}: %{boards}, %{byes}, %{floaters}.",
            round: round,
            boards: boards,
            byes: byes,
            floaters: floaters
          )

        bye_count > 0 ->
          gettext("Paired round %{round}: %{boards}, %{byes}.",
            round: round,
            boards: boards,
            byes: byes
          )

        floater_count > 0 ->
          gettext("Paired round %{round}: %{boards}, %{floaters}.",
            round: round,
            boards: boards,
            floaters: floaters
          )

        true ->
          gettext("Paired round %{round}: %{boards}.", round: round, boards: boards)
      end

    bye_note =
      case d["allocated_bye"] do
        %{"player" => player} when is_binary(player) ->
          gettext("Bye awarded to %{player}.", player: player)

        _ ->
          nil
      end

    sentences([paired, bye_note])
  end

  # A board with no Black player is a bye board, and says so instead of
  # inventing an opponent.
  defp result_sentence(kind, d) do
    board = value(d, "board")
    round = value(d, "round")
    white = value(d, "white")

    case {kind, d["black"]} do
      {:entered, black} when black in [nil, ""] ->
        gettext(
          "Entered result %{result} on board %{board} (round %{round}): %{player} (bye).",
          result: shown(d["to"]),
          board: board,
          round: round,
          player: white
        )

      {:entered, black} ->
        gettext(
          "Entered result %{result} on board %{board} (round %{round}): %{white} vs %{black}.",
          result: shown(d["to"]),
          board: board,
          round: round,
          white: white,
          black: text(black)
        )

      {:changed, black} when black in [nil, ""] ->
        gettext(
          "Changed result on board %{board} (round %{round}) from %{from} to %{to}: %{player} (bye).",
          board: board,
          round: round,
          from: shown(d["from"]),
          to: shown(d["to"]),
          player: white
        )

      {:changed, black} ->
        gettext(
          "Changed result on board %{board} (round %{round}) from %{from} to %{to}: %{white} vs %{black}.",
          board: board,
          round: round,
          from: shown(d["from"]),
          to: shown(d["to"]),
          white: white,
          black: text(black)
        )

      {:cleared, black} when black in [nil, ""] ->
        gettext(
          "Cleared the result on board %{board} (round %{round}) (was %{from}): %{player} (bye).",
          board: board,
          round: round,
          from: shown(d["from"]),
          player: white
        )

      {:cleared, black} ->
        gettext(
          "Cleared the result on board %{board} (round %{round}) (was %{from}): %{white} vs %{black}.",
          board: board,
          round: round,
          from: shown(d["from"]),
          white: white,
          black: text(black)
        )
    end
  end

  # Mobile result entry has no user account to attribute to (`Audit.log/4`'s
  # `nil` case, rendered as "System" elsewhere on this page) - this is the
  # one place that still says WHICH phone, using whatever label the arbiter
  # gave the enrollment (see `MobileResultsLive.log_mobile_result/4`).
  #
  # A row logged before `level` existed has nothing true to say about it -
  # the enrollment it came from has SINCE been backfilled to "deputy" (see
  # the migration), but that is a fact about the row today, not about what
  # the phone was actually allowed to do at the moment this line was
  # written, which is what this sentence claims. Left off rather than
  # guessed at.
  defp phone_sentence(%{"via" => "mobile"} = d) do
    label = d["enrollment_label"]
    level = level_name(d["enrollment_level"])
    labelled? = is_binary(label) and label != ""

    case {labelled?, level} do
      {true, nil} ->
        gettext(~s(Via the phone "%{label}".), label: label)

      {true, level} ->
        gettext(~s[Via the phone "%{label}" (%{level}).], label: label, level: level)

      {false, nil} ->
        gettext("Via phone enrollment #%{id}.", id: value(d, "enrollment_id"))

      {false, level} ->
        gettext("Via phone enrollment #%{id} (%{level}).",
          id: value(d, "enrollment_id"),
          level: level
        )
    end
  end

  defp phone_sentence(_d), do: nil

  # The same two words the Live round page shows when the phone is enrolled
  # (`LiveRoundLive.enrollment_level_label/1`), so the trail names a level
  # exactly as the arbiter chose it.
  defp level_name("deputy"), do: gettext("Deputy")
  defp level_name("helper"), do: gettext("Helper")
  defp level_name(level) when level in [nil, ""], do: nil
  defp level_name(level), do: text(level)

  # The labels `AdminLive` shows for the same three roles.
  defp role_name("admin"), do: gettext("Administrator")
  defp role_name("support"), do: gettext("Support")
  defp role_name("owner"), do: gettext("Account owner")
  defp role_name(role), do: shown(role)

  # A hand edit's sentence, then the line its confirmation showed - see the
  # comment above `describe("pairing.players_swapped", _)`. Quoted, and only
  # ever after a sentence of the reader's own: it was written in whatever
  # language the confirmation had, which so far has always been English.
  defp hand_edit(sentence, d), do: sentences([sentence, recorded_summary(d)])

  defp recorded_summary(%{"summary" => summary}) when is_binary(summary) and summary != "",
    do: gettext(~s(Recorded as "%{summary}".), summary: summary)

  defp recorded_summary(_d), do: nil

  defp pairings_taken_down(round),
    do:
      gettext("Took the pairings of round %{round} and every later round off the public page.",
        round: round
      )

  defp standings_taken_down(round),
    do:
      gettext(
        "Took the standings after round %{round} and every later round off the public page, together with any public pairings of later rounds.",
        round: round
      )

  # `skipped` counts rounds per reason (already current, edited by hand, not
  # a Swiss round...); the reasons are `inspect/1`ed atoms, so the sentence
  # gives the total and leaves the codes out.
  defp skipped_count(%{"skipped" => skipped}) when is_map(skipped),
    do: Enum.reduce(Map.keys(skipped), 0, &(count(skipped, &1) + &2))

  defp skipped_count(_d), do: 0

  # `operator` is whoever the results site says runs it, and nil when it does
  # not say - the dialog then names the host alone, and so does this.
  # "Register again" discards the old key before asking for a new one
  # (`Installation.start_over/1`), which is what the second sentence records.
  defp consent_given(d) do
    host = value(d, "host")

    agreed =
      case present(d["operator"]) do
        nil ->
          gettext("Agreed to publish on %{host}.", host: host)

        operator ->
          gettext("Agreed to publish on %{host}, the results site run by %{operator}.",
            host: host,
            operator: operator
          )
      end

    next =
      if truthy?(d["register_again"]),
        do:
          gettext(
            "This computer's old key was thrown away, so it registers there again for a new one."
          ),
        else:
          gettext(
            "This computer may now register there for a key of its own, for every tournament it publishes."
          )

    sentences([agreed, next])
  end

  ## ---------- detail helpers (details use string keys after JSON round-trip) ----------

  defp sentences(list), do: list |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  # `field before → after; field before → after`. The field is the schema's
  # identifier and the glue is punctuation, so nothing in here is a word to
  # translate except the values `shown/1` gives words to.
  defp changes(d) do
    case d["changed_fields"] do
      map when is_map(map) and map_size(map) > 0 ->
        Enum.map_join(map, "; ", fn {field, pair} -> "#{field} #{format_pair(pair)}" end)

      _ ->
        nil
    end
  end

  defp format_pair([before, after_value]), do: "#{shown(before)} → #{shown(after_value)}"
  defp format_pair(other), do: shown(other)

  # One recorded value, as the reader should see it. Booleans read as the
  # On/Off the settings screens use (and the History page's diff); a list is
  # its items; a map - the officials, the category rules - is shown whole, as
  # the JSON it was stored as, rather than crashing the page, which
  # `to_string/1` on it did.
  defp shown(v) when v in [nil, "", [], %{}], do: "-"
  defp shown(true), do: gettext("On")
  defp shown(false), do: gettext("Off")
  defp shown(list) when is_list(list), do: Enum.map_join(list, ", ", &shown/1)
  defp shown(map) when is_map(map), do: Jason.encode!(map)
  defp shown(v), do: text(v)

  defp name(d, key) do
    case d[key] do
      blank when blank in [nil, ""] -> gettext("(unnamed)")
      other -> text(other)
    end
  end

  defp value(d, key) do
    case d[key] do
      nil -> "?"
      other -> text(other)
    end
  end

  # A count that arrived as anything but a non-negative integer - a string
  # from a hand-edited backup, a null - counts as none rather than raising
  # inside `ngettext/3`, which only takes integers.
  defp count(d, key) do
    case d[key] do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp text(v) when is_binary(v), do: v
  defp text(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp text(v), do: inspect(v)

  defp blank?(v), do: v in [nil, ""]

  # A value worth naming in a sentence, or nil for one that says nothing.
  defp present(v) when v in [nil, ""], do: nil
  defp present(v), do: text(v)

  defp as_list(v) when is_list(v), do: v
  defp as_list(_v), do: []

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  @doc """
  The acting user's email for one audit row's `:user` preload.

  A row that arrived on a hand-off has no `user_id` - the account it named
  lives on the machine it came from, and inventing a local link there would
  attribute somebody else's action to whoever happens to hold that address
  here. `TournamentExport` keeps the original address in
  `details["imported_actor"]` instead, and this reads it back: without that
  fallback every imported row renders as "System", which says an automated
  process did something an arbiter did.
  """
  def actor(%{user: %{email: email}}), do: email

  def actor(%{details: %{"imported_actor" => actor}}) when is_binary(actor) and actor != "",
    do: actor

  def actor(_), do: gettext("System")

  @doc "Formats an audit row's `inserted_at` for display."
  def format_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_time(other), do: to_string(other)

  @doc """
  Sub-nav across the pages in the top bar's "Advanced" menu, so the strip on
  the page matches that menu one-for-one - Norms was previously missing here,
  leaving four entries in the menu but only three boxes on the page.
  `active` is `:norms`, `:history`, `:index` or `:explain`.
  """
  attr :tournament, :map, required: true
  attr :active, :atom, required: true

  def subnav(assigns) do
    ~H"""
    <div class="round-picker" style="flex-wrap: wrap; margin-bottom: 12px">
      <.link
        navigate={~p"/t/#{@tournament.id}/norms"}
        class={["pe-btn", "filter-picker", @active == :norms && "active"]}
      >
        {gettext("Norms")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/history"}
        class={["pe-btn", "filter-picker", @active == :history && "active"]}
      >
        {gettext("History")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/audit"}
        class={["pe-btn", "filter-picker", @active == :index && "active"]}
      >
        {gettext("Audit trail")}
      </.link>
      <.link
        navigate={~p"/t/#{@tournament.id}/audit/explain"}
        class={["pe-btn", "filter-picker", @active == :explain && "active"]}
      >
        {gettext("Pairing rationale")}
      </.link>
    </div>
    """
  end

  @impl true
  def render(%{live_action: :explain} = assigns) do
    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="audit"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext("Pick a paired round to see its pairing rationale")}
          </p>
        </div>
      </div>

      <.subnav tournament={@tournament} active={:explain} />

      <div :if={@paired_rounds == 0} class="card error-note" style="display: block; margin: 12px 0">
        {gettext("No rounds have been paired yet, so there is nothing to explain.")}
      </div>

      <div :if={@paired_rounds > 0} class="round-picker">
        <.link
          :for={n <- 1..@paired_rounds}
          navigate={~p"/t/#{@tournament.id}/pairings/#{n}/explain"}
          class="pe-btn"
        >
          {n}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, per_page: @per_page)

    ~H"""
    <Layouts.app
      publish_status={assigns[:publish_status]}
      update_notice={assigns[:update_notice]}
      flash={@flash}
      current_path={assigns[:current_path]}
      current_scope={@current_scope}
      tournament={@tournament}
      active="audit"
    >
      <div class="page-header">
        <div>
          <h1>{@tournament.name}</h1>
          <p class="subtitle" style="margin: 0">
            {gettext("Audit trail - every change, who made it, and when")}
          </p>
        </div>
      </div>

      <.subnav tournament={@tournament} active={:index} />

      <div class="round-picker" style="flex-wrap: wrap">
        <button
          :for={{key, _codes} <- categories()}
          class={["pe-btn", "filter-picker", key == @category && "active"]}
          phx-click="filter"
          phx-value-category={key}
        >
          {category_label(key)}
        </button>
      </div>

      <p class="hint" style="margin: 8px 0">
        {if @category == "all",
          do: ngettext("%{count} event total.", "%{count} events total.", @total),
          else:
            ngettext(
              "%{count} event total in this category.",
              "%{count} events total in this category.",
              @total
            )}
      </p>

      <div class="card table-card">
        <table class="pe-table">
          <thead>
            <tr>
              <th style="width: 150px">{gettext("When")}</th>
              <th style="width: 220px">{gettext("Who")}</th>
              <th>{gettext("What")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@entries == []}>
              <td colspan="3">
                <div class="empty">
                  <p class="hint">{gettext("No audit events recorded yet.")}</p>
                </div>
              </td>
            </tr>

            <tr :for={entry <- @entries}>
              <td style="white-space: nowrap">{format_time(entry.inserted_at)}</td>
              <td>{actor(entry)}</td>
              <td>{describe(entry)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="actions" style="margin-top: 12px; justify-content: space-between">
        <button
          class="pe-btn"
          phx-click="page"
          phx-value-delta="-1"
          disabled={@page == 0}
        >
          {gettext("← Newer")}
        </button>

        <span class="hint">{gettext("Page %{n}", n: @page + 1)}</span>

        <button
          class="pe-btn"
          phx-click="page"
          phx-value-delta="1"
          disabled={(@page + 1) * @per_page >= @total}
        >
          {gettext("Older →")}
        </button>
      </div>
    </Layouts.app>
    """
  end
end
