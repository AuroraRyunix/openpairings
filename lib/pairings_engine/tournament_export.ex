defmodule PairingsEngine.TournamentExport do
  @moduledoc """
  Full-fidelity JSON backup of one or more tournaments - everything
  OpenPairings models for a tournament (settings incl. officials/norm
  metadata, teams, players incl. `norm_data`, rounds, pairings/results,
  byes, forbidden pairings), as opposed to `PairingsEngine.TrfExport`'s
  FIDE-report-shaped TRF16 output. See `docs/import-export.md` for the
  envelope format and `PairingsEngine.TournamentImport` for the inverse.

  One thing in the envelope is not tournament data but a credential: the
  `"openresults"` block carries the key that lets a machine publish to and
  delete this tournament's copy on the results site. See
  `openresults_block/1` for why it travels and what stops an import from
  quietly adopting it. A file containing one should be handled like a
  password.

  The owning user is deliberately never included - an import always creates
  brand-new tournaments owned by whoever imports the file. Every other id
  (tournament, team, player, round) is carried along verbatim as `"id"`
  purely so sibling records within the *same* envelope (pairings under a
  round, byes, forbidden pairings) can reference the right team/player; the
  importer discards these ids and remaps everything to fresh ones.

  ## Hand-off blocks (opt in)

  Two more blocks - `"audit_log"` and `"collaborators"` - travel only when
  the caller passes `include_handoff: true`. They exist for the hand-off
  case: an arbiter moving a tournament between the hosted copy and a local
  one, where the event itself changes machines and everything about it
  should follow, including who did what and who was on the team.

  They are opt-in because this same `export_tournament/1` builds two things
  that are NOT hand-offs, and both would be harmed by carrying them:

    * a restore point (`PairingsEngine.Snapshots.capture/4`) - taken before
      every destructive action, so embedding the whole audit trail in each
      one would grow every snapshot by the log that produced it; and a
      restore is this tournament's own past, where the trail and the team
      never left in the first place.
    * "Duplicate tournament" (`PairingsEngineWeb.TournamentsLive`) - a copy
      is a NEW event. The original's audit trail describes actions nobody
      took in the copy, and the original's collaborator list would turn into
      a fresh round of invitations for people who were never asked about it.

  So the default stays exactly what those two already get, and a hand-off
  asks for more. See `@excluded_tables` for what does not travel under any
  option.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Round, Tournament}

  @format "openpairings-export"
  @version 1

  @doc "The envelope's `\"format\"` tag."
  def format, do: @format

  @doc "The envelope's `\"version\"` number."
  def version, do: @version

  # Every tournament field that is actual tournament *content*. Kept in sync
  # with the schema by `tournament_export_test.exs`, which fails if a new
  # schema field is neither listed here nor deliberately excluded below -
  # this list had silently rotted behind the schema for a long time, most
  # damagingly missing `pairing_system` itself, so a backup of a Keizer or
  # round-robin tournament restored as a Swiss one.
  @tournament_fields ~w(
    name type venue city federation start_date end_date organizer
    chief_arbiter deputy_arbiter time_control rounds_count
    points_win points_draw points_loss bye_value presence_value abs_value
    abs_jusque abs_nbfois absent_counts_as_vur
    presence_on_allocated_bye tiebreaks acceleration
    status standard rate_of_play organizer_club_number round_dates
    categories category_rules categories_enabled event_code
    fide_tournament_id fide_homologated fide_id_ranges officials
    pairing_system pairing_engine rr_cycles rr_match_format swiss_match_format
    keizer_top_value pair_by_category
    club_exclusion club_exclusion_list fed_exclusion fed_exclusion_list
    count_extra_points extra_points_bands
    publish_mode publish_delay_minutes
    manual_ranking manual_ranking_stale
    public_listed public_display public_hidden_tiebreaks
  )a

  # Deliberately NOT in the tournament map, with the reason for each -
  # asserted by the same test, so adding a schema field forces a conscious
  # choice rather than a silent omission.
  #
  # "Not in the map" is not always "not in the file": `openresults_key` at the
  # bottom does leave, in the entry's own block, and says so. Everything else
  # here stays on this machine.
  #
  #   id, user_id, inserted_at, updated_at
  #     Identity/ownership. An import always mints a new row owned by
  #     whoever imports it (see this module's moduledoc).
  #   public_slug
  #     The imported copy must get its own unguessable link, not share the
  #     original's - otherwise one leaked link exposes both.
  #   registration_open, publish_to_openresults
  #     Sharing must be an explicit opt-in per tournament, never inherited
  #     from a file someone was handed. Both default off on the new row.
  #
  #     `public_listed`, `public_display` and `public_hidden_tiebreaks` are
  #     exported rather than excluded, and the line between them is what the
  #     field can DO on its own. These three are inert until somebody
  #     publishes - they describe how a page should look, not whether there
  #     is one - so carrying them cannot leak anything, and they are a real
  #     judgement about this event ("no clubs on the open web", "Buchholz
  #     decides it but we do not print the column") that an importer would
  #     otherwise have to guess at and re-tick.
  #     `publish_to_openresults` is the sharpest of them: importing a file
  #     must not cause this machine to start sending a copy of it to whatever
  #     server this machine happens to be configured for - which is not the
  #     one the exporter was pointing at, and may not be one the exporter
  #     knows exists.
  #   deleted_at, archived_at
  #     Lifecycle state of *that* row. An import is always a live,
  #     editable tournament.
  #   handed_off_at, handed_off_to, handoff_token
  #     The hand-off lock, and for the same reason as the two above: an
  #     imported tournament is live here. Carrying the timestamp would
  #     restore a copy that is read-only with nothing on screen explaining
  #     why, and carrying the token would put the key that unlocks the
  #     original into every copy of the file - which is exactly the one
  #     thing the token exists to stop. The hand-off flow moves the token
  #     itself, deliberately and once, outside this field list.
  #   swar_guid
  #     SWAR's own per-tournament GUID, used for re-upload duplicate
  #     detection. Carrying it would make the imported copy look like a
  #     duplicate of the original it was exported from.
  #   logo_data, logo_content_type
  #     Known gap: binary, would need base64 in the envelope. Documented in
  #     docs/import-export.md rather than silently dropped.
  #   head_snapshot_id
  #     Points at a `tournament_snapshots` row - restore-point bookkeeping,
  #     and snapshots aren't part of the envelope. Carrying the id would
  #     dangle against another tournament's snapshot table. An imported copy
  #     legitimately starts with no history behind it.
  #   openresults_key
  #     Not in THIS map, but the one field on this list that does leave the
  #     machine: it travels in the entry's own `"openresults"` block instead
  #     (see `openresults_block/1` below). It is not tournament content, it is
  #     authority over a copy of the tournament sitting on a server, and it is
  #     useless without the address it is authority over - so it is grouped
  #     with that address rather than filed among the venue and the tiebreaks.
  #   openresults_claim
  #     Genuinely never exported. This is a key some OTHER file offered and
  #     this machine has not accepted. Passing it on would propagate an
  #     unadopted claim down a chain of backups, so that a file three copies
  #     removed still carried an offer to take over a tournament nobody in the
  #     chain ever owned.
  @excluded_tournament_fields ~w(
    id user_id inserted_at updated_at public_slug
    registration_open publish_to_openresults deleted_at archived_at swar_guid
    logo_data logo_content_type head_snapshot_id
    openresults_key openresults_claim
    handed_off_at handed_off_to handoff_token
  )a

  @doc false
  def tournament_fields, do: @tournament_fields

  @doc false
  def excluded_tournament_fields, do: @excluded_tournament_fields

  @team_fields ~w(name captain)a

  @player_fields ~w(
    name sex title fide_id fide_rating national_id national_rating
    federation birth_year birth_date club status start_round board_order
    pairing_number paid affiliated absent forfeit special_table
    absent_rounds extra_points category club_number norm_data team_id
    fixed_board manual_rank
  )a

  @round_fields ~w(number date status published_at)a

  # Schema fields NOT exported, each with the reason. Paired with a test
  # (`tournament_export_test.exs`) that asserts every field on the Round and
  # Pairing schemas is either exported or listed here, so the next field
  # added to either schema cannot go missing in silence.
  #
  # That guard exists because two already had. `pairings.hidden` and
  # `rounds.explanation` were dropped by nothing more than not being on the
  # list, and a backup/restore lost both without a word. `hidden` is fixed
  # below; `explanation` is a deliberate drop, for the reason beside it.
  @round_excluded [
    # Carried outside the field list: `round_map/1` merges `"id"` in
    # explicitly, because the import needs it to attach pairings, and
    # `tournament_id` is implied by the envelope's nesting - a round inside
    # a tournament's payload belongs to that tournament by construction, and
    # carrying the old id across would point at the wrong row.
    :id,
    :tournament_id,
    # Holds DB PLAYER IDS - `mdps`, `residents`, `floats`, `pairs` and
    # `edges` are all `player_ids/2` output (see `Pairing.bracket_json/2`).
    # Import re-inserts players with fresh ids, so carrying the blob across
    # verbatim would attribute every bracket to the wrong people while
    # looking entirely plausible. Remapping it needs a walker that knows the
    # blob's shape, which is what its own `"version" => 1` field is for;
    # until that exists, dropping it is the honest option. It is a
    # diagnostic panel, not tournament state, so losing it costs an
    # explanation and not a result.
    :explanation
  ]

  @pairing_excluded [
    # Same as the round's: the id is not needed (nothing references a
    # pairing) and `round_id` is implied by the nesting.
    :id,
    :round_id,
    # A foreign key into the unexported `matches` table - see
    # `pairing_map/1`.
    :match_id
  ]

  # ---------- the audit trail (hand-off only) ----------

  # One audit row's content. `inserted_at` is on the list because WHEN a
  # thing happened is half of the record - a trail with no times settles no
  # dispute - and `audit_map/1` writes it as an ISO8601 string rather than
  # letting a `NaiveDateTime` struct leak into what has to be plain JSON.
  @audit_fields ~w(action details inserted_at)a

  # And the reason for each column that stays behind. Guarded by the same
  # coverage test as the lists above, so a new `audit_logs` column has to be
  # given a decision rather than being dropped in silence.
  #
  #   id
  #     Fresh on the far side, like every other id in the envelope. Nothing
  #     references an audit row, so there is not even an internal reference
  #     to keep.
  #   tournament_id
  #     Implied by the envelope's nesting, exactly as a round's is. Carrying
  #     the old value would point the row at whatever tournament happens to
  #     hold that id on the importing machine.
  #   user_id
  #     The one that matters. A user id is meaningless off its own
  #     installation: at best it dangles, at worst it lands on a real
  #     stranger and the trail then says THEY deleted the player. So the
  #     acting user travels as a display string instead - the `"actor"` key
  #     `audit_map/1` merges in, which is their email or nil for a system
  #     row - and `PairingsEngine.TournamentImport` files it in `details`
  #     and leaves `user_id` nil. A name that cannot be clicked is worth
  #     more than a link to the wrong person.
  @audit_excluded [:id, :tournament_id, :user_id]

  @doc false
  def audit_fields, do: @audit_fields

  @doc false
  def audit_excluded, do: @audit_excluded

  # ---------- collaborators (hand-off only) ----------

  # A collaborator row is a link to a `users` row, and that row does not
  # exist on the other instance. What travels is the two things an
  # invitation is made of - who was invited, and to do what - so the team
  # can be re-established there. `PairingsEngine.TournamentImport` files
  # them as PENDING invitations that still have to be accepted; see
  # `import_collaborators!/2` for why an import must never be a grant.
  @collaborator_fields ~w(email role)a

  # Everything else, and why:
  #
  #   id, tournament_id
  #     Fresh row, and the tournament is implied by the nesting - same as
  #     everywhere else in the envelope.
  #   user_id
  #     The link that cannot survive the trip. An id from the source
  #     instance either dangles or names a completely different person here,
  #     and that person would then appear on the tournament's collaborator
  #     list. The email is the only identity the two machines share, which
  #     is exactly what the invite flow itself matches on
  #     (`PairingsEngine.Tournaments.link_pending_collaborators/1`), so the
  #     link is re-made there - by that person logging in, or accepting -
  #     rather than guessed at here.
  #   invite_token
  #     A bearer link: whoever holds it can open `/invites/<token>`. It is
  #     also single-use and unique across the table, so re-using the
  #     source's would put the same live token on two machines. The import
  #     mints its own.
  #   status
  #     Deliberately not carried, and this is the crux of the decision.
  #     "Accepted" is a statement about a grant made on ANOTHER machine, to
  #     an account this machine cannot see. Carrying it would put a value in
  #     the file that the import must refuse to honour - and the next person
  #     to find `"status": "accepted"` sitting unused in the JSON would
  #     reasonably wire it up, which is the bug. Every imported row starts
  #     pending; acceptance is the invitee's act, not the file's.
  #   inserted_at, updated_at
  #     An invitation is not a record of a past event the way an audit row
  #     is - it is a live offer, and the one created on import genuinely was
  #     created then. Carrying the source's timestamps would age an
  #     invitation nobody has seen yet.
  @collaborator_excluded [
    :id,
    :tournament_id,
    :user_id,
    :invite_token,
    :status,
    :inserted_at,
    :updated_at
  ]

  @doc false
  def collaborator_fields, do: @collaborator_fields

  @doc false
  def collaborator_excluded, do: @collaborator_excluded

  # ---------- whole tables that never travel, under any option ----------
  #
  # The lists above decide columns. This one decides tables: per-tournament
  # data that exists in the database and is deliberately absent from the
  # envelope, so that noticing a gap leads to the reason instead of to a
  # "fix".
  #
  #   mobile_enrollments
  #     LIVE ACCESS TOKENS, and the sharpest thing on this list. Each row is
  #     an 8-digit code plus a session token that let a phone with no
  #     account enter results for this tournament
  #     (`PairingsEngine.Mobile`). A code minted on the hosted copy must not
  #     begin working on somebody's laptop because a JSON file moved between
  #     them - the helper holding that phone was given access to an event on
  #     one machine, not to every copy of it that will ever exist. Handing
  #     the tournament over means the new machine mints new codes and hands
  #     out new phones; the old ones stop mattering when the old copy does.
  #     Nothing is lost that an arbiter cannot recreate in one click, and
  #     what is avoided is a credential that outlives the machine it was
  #     issued on.
  #   tournament_snapshots
  #     Restore points, whose payloads are themselves export envelopes -
  #     carrying them would nest the format inside itself and multiply the
  #     file size by the length of the history. `head_snapshot_id` is
  #     excluded on the tournament for the same reason.
  #   openresults_registrations, publish_queue
  #     Both belong to a publishing connection this machine may not have.
  #     Entries are collected by a form on a server the importer does not
  #     necessarily reach, and queued publishes are in-flight work for that
  #     same server - neither is content of the event.
  #   matches
  #     Team-tournament scaffolding that nothing currently writes; see
  #     `pairing_map/1`'s note on `match_id` and TODO.md.
  @excluded_tables [
    :mobile_enrollments,
    :tournament_snapshots,
    :openresults_registrations,
    :publish_queue,
    :matches
  ]

  @doc false
  def excluded_tables, do: @excluded_tables

  @doc false
  def round_excluded, do: @round_excluded

  @doc false
  def pairing_excluded, do: @pairing_excluded

  @doc false
  def round_fields, do: @round_fields

  @doc """
  Envelope wrapping a single tournament (caller is responsible for
  owner-scoping it).

  `include_handoff: true` adds the `"audit_log"` and `"collaborators"`
  blocks - see the moduledoc for why they are opt-in and which two callers
  must not get them.
  """
  def export_tournament(%Tournament{} = tournament, opts \\ []),
    do: envelope([tournament], opts)

  @doc """
  Envelope wrapping every tournament `scope`'s user owns or collaborates on.
  Takes the same `:include_handoff` option as `export_tournament/2`.
  """
  def export_all(%Scope{} = scope, opts \\ []) do
    tournaments =
      scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _count, _owner?} -> t end)

    envelope(tournaments, opts)
  end

  defp envelope(tournaments, opts) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "tournaments" => Enum.map(tournaments, &tournament_map(&1, opts))
    }
  end

  defp tournament_map(t, opts) do
    %{
      "tournament" => struct_fields(t, @tournament_fields),
      "openresults" => openresults_block(t),
      "teams" => Enum.map(Tournaments.list_teams(t.id), &team_map/1),
      "players" => Enum.map(Tournaments.list_players(t.id), &player_map/1),
      "rounds" => Enum.map(rounds_with_pairings(t.id), &round_map/1),
      "byes" => byes(t.id),
      "forbidden_pairings" => forbidden_pairings(t.id)
    }
    |> put_handoff_blocks(t, Keyword.get(opts, :include_handoff, false))
  end

  # Absent rather than empty when this is not a hand-off. An `[]` would read
  # as "this event had no audit trail and no collaborators", which is a
  # claim, and a false one - a snapshot payload is not evidence that the log
  # was empty when it was taken.
  defp put_handoff_blocks(map, _t, false), do: map

  defp put_handoff_blocks(map, t, true) do
    Map.merge(map, %{
      "audit_log" => Enum.map(audit_rows(t.id), &audit_map/1),
      "collaborators" => Enum.map(Tournaments.list_collaborators(t), &collaborator_map/1)
    })
  end

  @doc """
  The tournament's publishing identity, or nil for a tournament that has
  never published.

  **This block is a credential.** The key in it lets whoever holds the file
  publish to, and delete, the copy of this tournament on the results site -
  its public page, every earlier snapshot in its history, and any entries its
  form collected. Every surface offering an export says so; treat the file
  like a password.

  Carried on purpose, and it is the one deliberate exception to this module's
  rule that sharing state stays behind. The rule is about an imported copy
  inheriting the original's reach: a slug the importer did not earn, a
  publish switch they did not throw. This is the opposite case. Rebuilding a
  laptop from a backup has to recover the ability to manage what that laptop
  published, and a key that stayed on the dead disk would strand a tournament
  full of player names and ratings in public with nobody able to take it down.

  `public_slug` and `publish_to_openresults` keep their exclusions exactly as
  they were, which is why the address is repeated here rather than the slug
  field being un-excluded: the imported copy still gets its own fresh public
  link, and this is inert data describing where somebody ELSE'S copy lives
  until an arbiter deliberately takes it over. `PairingsEngine.TournamentImport`
  files it away dormant; `PairingsEngine.Publishing.adopt_claim/1` is the only
  thing that ever makes it live.

  `endpoint` is the machine-wide server address rather than anything on the
  tournament row, and it is here so the choice offered on import can name a
  real address. Without it the prompt would have to say "somewhere", and an
  arbiter cannot weigh a takeover of a server they cannot see.
  """
  def openresults_block(%Tournament{openresults_key: key} = t)
      when is_binary(key) and key != "" do
    %{
      "key" => key,
      "slug" => t.public_slug,
      "endpoint" => PairingsEngine.Publishing.endpoint() || ""
    }
  end

  def openresults_block(%Tournament{}), do: nil

  defp team_map(team), do: Map.put(struct_fields(team, @team_fields), "id", team.id)

  defp player_map(player), do: Map.put(struct_fields(player, @player_fields), "id", player.id)

  defp round_map(round) do
    round
    |> struct_fields(@round_fields)
    |> Map.merge(%{"id" => round.id, "pairings" => Enum.map(round.pairings, &pairing_map/1)})
  end

  # `pairings.match_id` is deliberately NOT exported. The Pairing schema
  # declares it as a plain `field :match_id, :integer`, but the migration
  # makes it a real foreign key into the `matches` table - team-tournament
  # scaffolding that is not exported (and that nothing currently writes;
  # see TODO.md's team-tournaments entry). Carrying the raw integer across
  # would point the imported pairing at another tournament's match row, or
  # at nothing. Revisit together with team-tournament export.
  defp pairing_map(p) do
    %{
      "board" => p.board,
      "result" => p.result,
      # The per-pairing hide, which an arbiter sets to keep one board off
      # the public page. It was not on this list and a restore silently
      # un-hid every hidden board - a disclosure, not just a lost setting.
      "hidden" => p.hidden,
      # The frozen board label and its special/ordinary classification.
      # These were excluded on the reasoning that recomputing them on import
      # from the round-tripped `fixed_board` values is "more correct than
      # carrying a stale label across". It isn't: a frozen label is not
      # stale, it is the RECORD of what the sheets on the tables said, and
      # the recompute reads each player's fixed table as it stands at
      # RESTORE time. Restoring a backup taken after a mid-tournament pin
      # therefore renumbered rounds people had already sat down at - the one
      # thing `PairingsEngine.PairingDisplay`'s moduledoc says must never
      # happen. `TournamentImport` uses these when they are here and falls
      # back to the recompute only for a payload written before they were.
      "display_board" => p.display_board,
      "display_special" => p.display_special,
      "white_player_id" => p.white_player_id,
      "black_player_id" => p.black_player_id
    }
  end

  # Read forward. `PairingsEngine.Audit.list_for_tournament/2` orders newest
  # first because that is what a screen wants; a file is read from the top,
  # and a record of an event reads in the order the event happened. `id`
  # breaks the tie, because `inserted_at` has second precision and a burst
  # of rows (pairing a round, importing results) lands inside one second.
  #
  # Scoped to this tournament, which leaves out the machine-wide rows
  # (`tournament_id IS NULL`) on purpose: a role granted or a backup taken
  # is a fact about the installation, not about this event, and it stays
  # with the installation. Unbounded, unlike the paginated screen query - a
  # partial trail would be worse than none, because it looks complete.
  defp audit_rows(tournament_id) do
    Repo.all(
      from a in AuditLog,
        where: a.tournament_id == ^tournament_id,
        order_by: [asc: a.inserted_at, asc: a.id],
        preload: [:user]
    )
  end

  defp audit_map(row) do
    row
    |> struct_fields(@audit_fields)
    |> Map.merge(%{
      # A JSON file is the transport, so the timestamp leaves as a string
      # rather than as a `NaiveDateTime` struct that only survives because
      # something downstream happens to encode it.
      "inserted_at" => NaiveDateTime.to_iso8601(row.inserted_at),
      "actor" => actor_label(row)
    })
  end

  # The acting user as a NAME, never as an id - see `@audit_excluded`.
  #
  # The second clause is what keeps a name across more than one trip. A row
  # that arrived by an earlier hand-off has no local user either, and
  # `PairingsEngine.TournamentImport` parked its actor in `details`; reading
  # it back means handing the tournament on again does not quietly degrade
  # every one of those rows to "System" the second time.
  defp actor_label(%AuditLog{user: %{email: email}}) when is_binary(email), do: email

  defp actor_label(%AuditLog{details: %{"imported_actor" => label}})
       when is_binary(label) and label != "",
       do: label

  defp actor_label(%AuditLog{}), do: nil

  defp collaborator_map(collaborator), do: struct_fields(collaborator, @collaborator_fields)

  defp rounds_with_pairings(tournament_id) do
    Repo.all(
      from r in Round,
        where: r.tournament_id == ^tournament_id,
        order_by: r.number,
        preload: [:pairings]
    )
  end

  defp byes(tournament_id) do
    Repo.all(
      from b in "byes",
        where: b.tournament_id == ^tournament_id,
        select: %{player_id: b.player_id, round: b.round, type: b.type}
    )
    |> Enum.map(&stringify_keys/1)
  end

  defp forbidden_pairings(tournament_id) do
    Repo.all(
      from f in "forbidden_pairings",
        where: f.tournament_id == ^tournament_id,
        select: %{player_a_id: f.player_a_id, player_b_id: f.player_b_id}
    )
    |> Enum.map(&stringify_keys/1)
  end

  defp struct_fields(struct, fields) do
    struct |> Map.from_struct() |> Map.take(fields) |> stringify_keys()
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
end
