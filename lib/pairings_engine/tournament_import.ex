defmodule PairingsEngine.TournamentImport do
  @moduledoc """
  Imports a `PairingsEngine.TournamentExport` envelope (already JSON-decoded
  to a string-keyed map), recreating every tournament it describes as a
  brand-new tournament owned by the importing user - fresh ids throughout,
  every internal foreign key (team ids referenced by players; player ids
  referenced by pairings, byes, forbidden pairings) remapped inside a single
  transaction via an old-id -> new-id map built as each record is inserted.

  One thing in the envelope is deliberately NOT applied: the `"openresults"`
  block's publishing key. It is stored dormant on the new row and does
  nothing until an arbiter explicitly takes the published tournament over -
  see `dormant_claim/1` for why importing must never be a takeover.

  ## The hand-off blocks

  A file written with `PairingsEngine.TournamentExport`'s
  `include_handoff: true` carries two more blocks, and both are applied
  under the same rule as everything else - nothing from the other instance
  is trusted to mean the same thing here:

    * `"audit_log"` - the tournament's own trail, re-inserted with fresh
      ids, the original timestamps, and every DB id inside `details`
      remapped or dropped (`sanitize_details/2`). The acting user lands as a
      name, never as a link; see `import_audit_row!/3`.
    * `"collaborators"` - filed as PENDING invitations that still have to be
      accepted. An import must never be a grant; see
      `import_collaborators!/2`.

  See `docs/import-export.md` for the envelope format and
  `PairingsEngine.TournamentExport` for the inverse.
  """

  import Ecto.Query
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{CategoryRules, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Collaborator, Tournament, Team, Player, Round, Pairing}

  # Kept as literals (rather than referencing PairingsEngine.TournamentExport
  # here) so the two modules have no compile-time dependency on each other;
  # `PairingsEngine.TournamentExport.format/0` and `.version/0` return the
  # same values and both are covered by round-trip tests.
  @format "openpairings-export"
  @version 1

  # Where `legacy_publish_mode/1` keeps a pre-2026-09-28 `publish_mode` for
  # `apply_legacy_immediate!/2`. Not a tournament field, so nothing casts it.
  @legacy_mode_key "__legacy_publish_mode"

  @doc """
  Imports every tournament in `data` (a JSON-decoded export envelope) as new
  tournaments owned by `scope`'s user. Returns `{:ok, [%Tournament{}, ...]}`
  on success (broadcasting the user's tournament-list change once, after
  commit) or `{:error, reason}` - `reason` is a human-readable string safe
  to show directly in a flash. Never raises: a malformed envelope, a bad
  format/version tag, or an invalid record anywhere inside it rolls the
  whole import back and comes back as `{:error, _}`, not a crash.
  """
  def import(data, %Scope{} = scope, opts \\ []) do
    case import_with_notes(data, scope, opts) do
      {:ok, tournaments, _notes} -> {:ok, tournaments}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `import/2`, with the notes an organiser should read about what the import
  changed: `{:ok, tournaments, notes}`. Today the one note is a SWAR
  identity left behind because another tournament here already has it
  (`unique_swar_guid/1`).
  """
  def import_with_notes(data, scope, opts \\ [])

  def import_with_notes(data, %Scope{} = scope, opts) when is_map(data) do
    cond do
      Map.get(data, "format") != @format ->
        {:error, "This file is not an OpenPairings export (unrecognized format)."}

      Map.get(data, "version") != @version ->
        {:error, "Unsupported export version #{inspect(Map.get(data, "version"))}."}

      not valid_tournaments_list?(data) ->
        {:error, "This export file contains no tournaments to import."}

      true ->
        do_import(Map.fetch!(data, "tournaments"), scope, opts)
    end
  end

  def import_with_notes(_invalid, %Scope{}, _opts),
    do: {:error, "This file is not a valid OpenPairings export."}

  ## ---------- reading the file ----------

  ## Why the size is checked before the JSON is decoded
  #
  # `import/2` takes an already-decoded map, and everything it validates -
  # the format tag, the version, whether there are tournaments at all -
  # happens after `Jason.decode/1` has built the whole term. That ordering
  # is the defect: a JSON document costs several times its own length once
  # it is a term, so the decode is where the memory goes and the checks
  # afterwards are too late to matter.
  #
  # Measured on this machine, decoding one megabyte of JSON produces
  # between 5.3 and 11.4 megabytes of term depending on shape - lists of
  # empty containers at the low end, small objects at the high end. The
  # 25 MB the upload inputs used to allow was therefore up to ~285 MB of
  # heap, on a two-core production box, before a single field had been
  # looked at.
  #
  # So the file is measured on disk and refused there, before it is even
  # read, and the number below is derived rather than picked.

  # 10 MB, from what an export actually weighs. A 400-player, 13-round
  # tournament with a 2,000-row audit trail measures 220 KB as a plain
  # export and 512 KB with the hand-off blocks attached; scaled to the
  # largest Swiss ever played - about 2,500 players, every round played -
  # that is roughly 5 MB. Ten is twice the largest single tournament that
  # can exist, and caps the worst-case decode at ~115 MB instead of ~285.
  #
  # What it refuses is a single file holding a dozen such events at once.
  # That is what the machine backup is for (`PairingsEngine.Backup`, which
  # is compressed and never crosses this path); an arbiter moving
  # tournaments between machines exports them in batches.
  @max_bytes 10_000_000

  @doc """
  The largest export file this app will read, in bytes.

  Public because the upload inputs in `PairingsEngineWeb.TournamentsLive`
  set their `:max_file_size` from it - a browser that refuses the file
  early gives a better message than a server that refuses it late, and two
  numbers that had to be kept in step by hand would not stay in step.
  """
  def max_bytes, do: @max_bytes

  @doc """
  Reads and decodes an export envelope from `path`, refusing anything past
  `max_bytes/0` without reading it.

  Returns `{:ok, decoded}` for `import/2` or `PairingsEngine.Handoff`, or
  `{:error, :too_large}` / `{:error, :unreadable}` - the caller words both,
  since the same file is "a backup" on one screen and "a hand-off" on
  another.
  """
  def decode_file(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= @max_bytes,
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      false -> {:error, :too_large}
      _unreadable -> {:error, :unreadable}
    end
  end

  defp valid_tournaments_list?(data) do
    case Map.get(data, "tournaments") do
      [_ | _] -> true
      _ -> false
    end
  end

  # Same after-commit, outside-suppression pattern as `PairingsEngine.Federations.BEL.SwarImport`:
  # imported rounds/results already carry whatever status the export
  # snapshotted, but the round-trip should stand on its own - re-derive
  # each tournament's status from what actually landed in the database
  # (after the transaction commits, so the query sees the imported data;
  # outside `with_broadcast_suppressed`, so a real status change still
  # broadcasts) rather than trust the imported `status` field.
  defp do_import(tournaments, scope, opts) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn -> Enum.map(tournaments, &import_tournament!(&1, scope, opts)) end)
      end)

    case result do
      {:ok, imported_with_notes} ->
        {imported, notes} = Enum.unzip(imported_with_notes)
        Enum.each(imported, &Tournaments.broadcast_tournament_change(&1.id, :tournament))
        Tournaments.broadcast_user_tournaments(scope.user.id)
        refreshed = Enum.map(imported, &Tournaments.refresh_status!(&1.id))
        {:ok, refreshed, List.flatten(notes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rebuilds an **existing** tournament's contents from one tournament entry of
  an export envelope - the restore half of `PairingsEngine.Snapshots`.

  Differs from `import/2` in that it writes into `tournament` rather than
  creating a new row: the settings on the entry are applied to it, and its
  teams/players/rounds/byes/forbidden pairings are recreated with fresh ids
  and internally remapped, exactly as an import does. The caller is
  responsible for having already deleted the old contents and for wrapping
  this in a transaction - see `Snapshots.restore/3`, the only caller.

  Raises (via `Repo.rollback/1`) rather than returning an error tuple, for the
  same reason the private import helpers do: it only runs inside a
  transaction that must abort wholesale on any bad record.

  Unlike `import/2`, this does not even file the entry's `"openresults"` block
  away as a claim. A restore point is this tournament's own past, so its key
  is this tournament's own key - already on the row, and never cast, so the
  restore cannot disturb it. Turning it into a "claim" would offer the arbiter
  a takeover of themselves.

  The hand-off blocks are skipped for the same reason, and a snapshot payload
  does not carry them in the first place (`export_tournament/1` only adds
  them on request). The audit trail and the collaborator list never left this
  tournament: `PairingsEngine.Snapshots.restore/3` does not wipe them, so
  re-inserting a copy would double the trail and try to invite the team a
  second time - which the collaborator table's unique index would refuse
  anyway. A restore is also itself an audited action, which is how the trail
  records that it happened, and rewinding the record of what was done is not
  something a restore should be able to do.
  """
  def restore_into!(%Tournament{} = tournament, entry) when is_map(entry) do
    t_attrs =
      entry
      |> fetch_map!("tournament")
      |> migrate_legacy_category_rules()
      |> legacy_publish_mode()
      |> keep_live_swar_guid(tournament)

    tournament =
      tournament
      |> Tournament.changeset(t_attrs)
      |> Ecto.Changeset.change(swar_settings: swar_settings(t_attrs, tournament.swar_settings))
      |> Ecto.Changeset.change(
        manual_ranking_stale: truthy(Map.get(t_attrs, "manual_ranking_stale")),
        # The seed of the one drawing of lots (not cast): a restored
        # tournament repeats a draw the way the original did.
        lots_seed: coerce_int(Map.get(t_attrs, "lots_seed")),
        # The round FIDE-mode compliance was first lost in, and the ONLY
        # field here that is not simply taken from the file.
        #
        # `docs/design-fide-mode.md` section 3.3b called a plain restore "the
        # sharpest hole in the whole design" and prescribed re-asserting the
        # live value here. Measured against the real code, that premise is
        # wrong in both halves, and the second half matters:
        #
        #   * A restore CANNOT clear it on its own. The changeset above is
        #     built on `tournament`, the live row, and the field is not cast -
        #     so an uncast field simply keeps the value it already had. The
        #     danger the section describes only appears if somebody later adds
        #     it to the cast list, and `compliance_test.exs` fails on that
        #     combination.
        #   * The direction that IS broken is the opposite one, and re-asserting
        #     the live value would have caused it. `Handoff.release/3` returns
        #     a tournament through this same function, and the returning
        #     payload is the only record of what happened on the other
        #     machine. This copy was locked for the whole trip and knows
        #     nothing; taking the live value would throw away a loss that
        #     really happened, on the copy where the rounds were actually
        #     played.
        #
        # One rule covers both, and it is the rule the fact itself implies:
        # the record is a watermark on the FIRST loss, so it only ever moves
        # earlier - never later, and never back to nil. Rolling back past an
        # event that has already been reported must not un-report it (the
        # argument `snapshots.ex` makes for `openresults_key`), and coming
        # home must not lose what the other copy recorded.
        fide_compliance_lost_round:
          earliest_compliance_loss(
            tournament.fide_compliance_lost_round,
            Map.get(t_attrs, "fide_compliance_lost_round")
          ),
        # A logged PIBE is never un-logged by a restore: an entry that
        # predates the field keeps the live record.
        import_findings:
          map_or_nil(Map.get(t_attrs, "import_findings")) || tournament.import_findings
      )
      # Same reasoning, and the same three fields, as `import_tournament!/2`
      # - see the comment there. A restore point taken before this shipped
      # carries none of them and this tournament comes back with the
      # column's own default, same as a fresh import of the same old file
      # would; there is no "live value" to prefer here either, since a
      # restore's whole point is to replace what is live with what the
      # entry says.
      |> Ecto.Changeset.change(
        public_listed: truthy(Map.get(t_attrs, "public_listed")),
        public_display: public_display_or_nil(Map.get(t_attrs, "public_display")),
        public_hall: public_display_or_nil(Map.get(t_attrs, "public_hall")),
        public_live_boards: truthy(Map.get(t_attrs, "public_live_boards")),
        public_hidden_tiebreaks: hidden_tiebreaks(Map.get(t_attrs, "public_hidden_tiebreaks"))
      )
      |> Ecto.Changeset.change(
        pairing_state(t_attrs, tournament.initial_colour_drawn, records!(entry, "teams") != [])
      )
      |> Ecto.Changeset.change(
        round_one_absentees_late:
          round_one_absentees_late(t_attrs, tournament.round_one_absentees_late),
        pairing_numbers_origin:
          pairing_numbers_origin(t_attrs, tournament.pairing_numbers_origin),
        # The entry's players are new rows with new ids, so an answer given
        # about the old ones is about nobody.
        tpn_order_accepted: nil
      )
      |> update!()

    team_map = import_teams!(tournament, records!(entry, "teams"))
    player_map = import_players!(tournament, records!(entry, "players"), team_map)
    remap_team_withdrawals!(records!(entry, "teams"), team_map, player_map)
    import_rounds!(tournament, records!(entry, "rounds"), player_map, team_map)
    import_byes!(tournament, records!(entry, "byes"), player_map)
    import_forbidden_pairings!(tournament, records!(entry, "forbidden_pairings"), player_map)
    import_pairing_rules!(tournament, entry, t_attrs, player_map)
    tournament = import_prohibition_changes!(tournament, t_attrs, player_map)

    tournament
    |> PairingsEngine.TeamSwiss.settle_mode()
    |> apply_standings_through!(t_attrs)
    |> apply_legacy_immediate!(t_attrs)
  end

  # The drawn initial colour, a team Swiss's pairing mode and a Baku Group A
  # are written by the pairing code, never cast, so both import paths carry
  # them by hand.
  #
  # A file without `initial_colour_drawn` predates the draw; `fallback` is
  # what to keep then - nil for a new row, the live value for a restore (a
  # draw that happened after the restore point was taken still happened,
  # and C.04.3 5.1 draws once). A file without `team_pairing_mode` predates
  # team Swiss pairing; nil is written and `TeamSwiss.settle_mode/1` decides
  # it from the rounds once they have landed - rounds without matches were
  # paired player by player.
  #
  # `teams_ordered_by_hand` is written by `Tournaments.move_team/3` only. A
  # file without it predates automatic seeding: its teams' order, whatever
  # made it, is kept (true when it has teams), as the migration did for the
  # rows already in the database.
  defp pairing_state(t_attrs, fallback, has_teams?) do
    drawn =
      case Map.fetch(t_attrs, "initial_colour_drawn") do
        {:ok, colour} when colour in ~w(white black) -> colour
        {:ok, _other} -> nil
        :error -> fallback
      end

    mode =
      case Map.get(t_attrs, "team_pairing_mode") do
        mode when mode in ~w(teams players) -> mode
        _ -> nil
      end

    # A Baku Group A fixed at round 1 belongs to the rounds the file
    # carries, so it comes with them. A file older than the column has none,
    # and the pairing works it out from those rounds' round 1
    # (`Pairing.baku_group_a_last/2`).
    group_a_last = coerce_int(Map.get(t_attrs, "baku_group_a_last"))

    ordered_by_hand =
      case Map.fetch(t_attrs, "teams_ordered_by_hand") do
        {:ok, value} -> truthy(value)
        :error -> has_teams?
      end

    [
      initial_colour_drawn: drawn,
      team_pairing_mode: mode,
      baku_group_a_last: group_a_last,
      teams_ordered_by_hand: ordered_by_hand
    ]
  end

  # A file written before extra points had a mode carries no
  # `extra_points_mode`. The migration that added the column decided the
  # rows already in the database by one rule (a SWAR tournament using extra
  # points, with no bands of this app's own, is an acceleration), and a file
  # from the same era gets the same answer here - otherwise the backup of an
  # imported SWAR event would come back pairing without its acceleration.
  # A restore needs none of this: its changeset is built on the live row,
  # and a key the file lacks leaves the live value alone.
  defp legacy_extra_points_mode(t_attrs, t_data) do
    if Map.has_key?(t_attrs, "extra_points_mode") do
      t_attrs
    else
      swar? =
        Map.get(t_attrs, "swar_guid") not in [nil, ""] or
          Map.get(t_attrs, "swar_settings") not in [nil, %{}]

      uses? =
        truthy(Map.get(t_attrs, "count_extra_points")) or
          Enum.any?(
            list(t_data, "players"),
            &(is_map(&1) and Map.get(&1, "extra_points") not in [nil, 0, 0.0])
          )

      if swar? and uses? and Map.get(t_attrs, "extra_points_bands") in [nil, ""],
        do: Map.put(t_attrs, "extra_points_mode", "acceleration"),
        else: t_attrs
    end
  end

  # A file written before `late_entry_absences` existed carries none. The
  # migration that added the column left it off for a finished tournament,
  # so an upgrade would not rewrite final standings, and a file of a
  # finished tournament from the same era gets the same answer - otherwise
  # restoring an old backup would rescore the event the upgrade left alone.
  defp legacy_late_entry_absences(t_attrs) do
    if Map.has_key?(t_attrs, "late_entry_absences") or Map.get(t_attrs, "status") != "finished",
      do: t_attrs,
      else: Map.put(t_attrs, "late_entry_absences", false)
  end

  # Not cast - it is when the tournament was made, not a choice - so it is
  # carried by hand. A file from before it travelled describes a tournament
  # that numbered its round-1 absentees with the field: a new row gets
  # false, the value the migration gave every row of that era; a restore
  # keeps the live row's (`fallback`).
  defp round_one_absentees_late(t_attrs, fallback) do
    case Map.fetch(t_attrs, "round_one_absentees_late") do
      {:ok, value} -> truthy(value)
      :error -> fallback
    end
  end

  # Whose the pairing numbers are (`Tournament`'s `pairing_numbers_origin`),
  # not cast, so carried by hand. A file without the key predates it:
  # `fallback` then - the live row's value for a restore, and for a new row
  # what the migration decided for the rows it found (`file_origin/1`).
  defp pairing_numbers_origin(t_attrs, fallback) do
    case Map.fetch(t_attrs, "pairing_numbers_origin") do
      {:ok, origin} when origin in ~w(import exchange) -> origin
      {:ok, _other} -> nil
      :error -> fallback
    end
  end

  # A tournament that carries a TRF import record or a SWAR guid came from a
  # file, numbers included.
  defp file_origin(t_attrs) do
    if is_map(Map.get(t_attrs, "import_findings")) or
         Map.get(t_attrs, "swar_guid") not in [nil, ""],
       do: "import"
  end

  # A file written before `late_entry_numbering` travelled carries none, and
  # its tournament numbered late entrants after the field - the only thing
  # this app did then. Left alone, the schema's "rating" default would quietly
  # renumber the next one to join. It gets the grandfathered "end", the same
  # value the migration gave the rows already in the database, so a restored
  # old event neither changes how it pairs nor leaves FIDE mode for a choice
  # nobody made. A restore point (`restore_into!/2`) needs none of this: a
  # missing key there keeps the live row's value.
  defp legacy_late_entry_numbering(t_attrs) do
    if Map.has_key?(t_attrs, "late_entry_numbering"),
      do: t_attrs,
      else: Map.put(t_attrs, "late_entry_numbering", "end")
  end

  # A file written before `absent_counts_as_vur` existed carries none, and
  # its tournament counted an absence at its awarded value in the opponents'
  # tie-breaks: the column arrived as `false` for every row already there
  # (`AddAbsentCountsAsVur`), and the schema default became `true` later.
  # Without this the same event broke ties one way where it stood and
  # another way out of its own backup. Same cure as the two above; a restore
  # point keeps the live row's value and never gets here.
  defp legacy_absent_counts_as_vur(t_attrs) do
    if Map.has_key?(t_attrs, "absent_counts_as_vur"),
      do: t_attrs,
      else: Map.put(t_attrs, "absent_counts_as_vur", false)
  end

  # SWAR bookkeeping (`TournamentExport`'s `@tournament_fields`: the guid,
  # `swar_settings` and the two-axis category columns), so a restored copy
  # writes the `.swar` file the original did. `swar_guid` and the category
  # columns are cast and come through the changeset; `swar_settings` is not
  # cast - no form may write it - so it is carried here, like the other
  # uncast fields. A file from before these travelled has no key: a new row
  # gets the empty default, a restore keeps what the live row has.
  defp swar_settings(t_attrs, fallback) do
    case Map.get(t_attrs, "swar_settings") do
      settings when is_map(settings) -> settings
      _ -> fallback || %{}
    end
  end

  # A restore point taken before the tournament first went to SWAR carries
  # no guid. Restoring it must not take the one minted since away: the guid
  # is the tournament's lasting identity in SWAR and on the federation's
  # results site, and losing it would make the next export a different
  # tournament there.
  defp keep_live_swar_guid(t_attrs, %Tournament{swar_guid: live}) when live not in [nil, ""] do
    if Map.get(t_attrs, "swar_guid") in [nil, ""],
      do: Map.delete(t_attrs, "swar_guid"),
      else: t_attrs
  end

  defp keep_live_swar_guid(t_attrs, _tournament), do: t_attrs

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        Repo.rollback("Could not restore: " <> changeset_error_text(changeset))
    end
  end

  ## ---------- per-tournament import (runs inside the transaction) ----------

  defp import_tournament!(t_data, _scope, _opts) when not is_map(t_data) do
    Repo.rollback("Malformed tournament entry in export file.")
  end

  defp import_tournament!(t_data, scope, opts) do
    {t_attrs, notes} =
      t_data
      |> fetch_map!("tournament")
      |> migrate_legacy_category_rules()
      |> legacy_publish_mode()
      |> legacy_extra_points_mode(t_data)
      |> legacy_late_entry_absences()
      |> legacy_late_entry_numbering()
      |> legacy_absent_counts_as_vur()
      |> unique_swar_guid()

    tournament =
      %Tournament{user_id: scope.user.id}
      |> Tournament.changeset(t_attrs)
      |> Ecto.Changeset.change(swar_settings: swar_settings(t_attrs, %{}))
      # `manual_ranking_stale` is deliberately outside `changeset/2`'s cast
      # list (only the manual-ranking writers in `Tournaments` set it), so it
      # has to be carried across explicitly or an imported tournament with a
      # stale hand-set order would come back claiming to be fresh.
      |> Ecto.Changeset.change(
        manual_ranking_stale: truthy(Map.get(t_attrs, "manual_ranking_stale")),
        lots_seed: coerce_int(Map.get(t_attrs, "lots_seed")),
        # A brand-new row, so there is no live value to weigh against: the
        # file's is the only record there is. A backup of a tournament that
        # lost FIDE-mode compliance in round 4 has to come back as one that
        # lost it in round 4, because the rounds it carries are the rounds
        # that were played after it happened. Outside the cast list for the
        # same reason as `manual_ranking_stale` above.
        fide_compliance_lost_round: coerce_int(Map.get(t_attrs, "fide_compliance_lost_round")),
        # The TRF import's record (`TrfImport.findings/1`), as the file has it.
        import_findings: map_or_nil(Map.get(t_attrs, "import_findings")),
        # The file's publishing key, filed away DORMANT - see
        # `dormant_claim/1`. Note where it comes from: `t_data`, the envelope
        # entry, not `t_attrs`. It is not a tournament field and is not cast,
        # which is what makes "an import never adopts a key" a property of
        # the schema rather than a rule this function has to remember.
        openresults_claim: dormant_claim(t_data)
      )
      # `public_listed`/`public_display`/`public_hidden_tiebreaks` are
      # display preferences `TournamentExport` writes (see its own doc for
      # why they travel) but, like `manual_ranking_stale` above, are outside
      # `Tournament.changeset/2`'s cast list on purpose - so a fresh import
      # has to carry them across by hand too, or an arbiter's public-page
      # picks would silently reset to "show everything" on every restore.
      # A brand-new row, so a file that predates the field simply gets that
      # field's own default - there is no live value to fall back to.
      |> Ecto.Changeset.change(
        public_listed: truthy(Map.get(t_attrs, "public_listed")),
        public_display: public_display_or_nil(Map.get(t_attrs, "public_display")),
        public_hall: public_display_or_nil(Map.get(t_attrs, "public_hall")),
        public_live_boards: truthy(Map.get(t_attrs, "public_live_boards")),
        public_hidden_tiebreaks: hidden_tiebreaks(Map.get(t_attrs, "public_hidden_tiebreaks"))
      )
      |> Ecto.Changeset.change(pairing_state(t_attrs, nil, records!(t_data, "teams") != []))
      |> Ecto.Changeset.change(
        round_one_absentees_late: round_one_absentees_late(t_attrs, false),
        pairing_numbers_origin: pairing_numbers_origin(t_attrs, file_origin(t_attrs))
      )
      |> insert!("the \"tournament\" block")

    team_map = import_teams!(tournament, records!(t_data, "teams"))
    player_map = import_players!(tournament, records!(t_data, "players"), team_map)
    remap_team_withdrawals!(records!(t_data, "teams"), team_map, player_map)
    import_rounds!(tournament, records!(t_data, "rounds"), player_map, team_map)
    import_byes!(tournament, records!(t_data, "byes"), player_map)
    import_forbidden_pairings!(tournament, records!(t_data, "forbidden_pairings"), player_map)
    import_pairing_rules!(tournament, t_data, t_attrs, player_map)
    tournament = import_prohibition_changes!(tournament, t_attrs, player_map)
    # What the file says was sent to the rating officer goes on this copy's
    # sent-games record: the file's own record of it (`"sent_games"`, audit
    # 2026-10-01 F5), and the sent marks on its boards. So neither this copy
    # nor a restore here can send those games again.
    handoff? = Keyword.get(opts, :handoff, false)

    PairingsEngine.PostponedGames.merge_records(
      tournament.id,
      list(t_data, "sent_games"),
      if(handoff?, do: "handoff", else: "import")
    )

    PairingsEngine.PostponedGames.reapply_sent_marks(tournament.id)

    # And the receipts of those sends; a send the file has no receipt for
    # (a backup older than receipts) gets one marked as sent before them.
    PairingsEngine.SentReceipts.merge_receipts(
      tournament.id,
      list(t_data, "sent_receipts"),
      if(handoff?, do: "handoff", else: "import")
    )

    # A copy of an event that may have been reported from somewhere else
    # sends nothing until an arbiter confirms it is the copy that reports.
    # Not a hand-off: there the other copy is locked and this one is meant
    # to carry on (`PairingsEngine.Handoff`).
    unless handoff?,
      do: Tournaments.require_send_confirmation_if_reported(tournament.id, "json")

    tournament = PairingsEngine.TeamSwiss.settle_mode(tournament)

    # Last, and after the players, because an audit row's `details` can
    # name a player and the remap needs the finished map. Both blocks are
    # absent from an ordinary envelope, in which case `list/2` hands back
    # `[]` and neither loop does anything.
    import_audit_log!(tournament, list(t_data, "audit_log"), player_map)
    import_collaborators!(tournament, list(t_data, "collaborators"))

    tournament =
      tournament
      |> apply_standings_through!(t_attrs)
      |> apply_legacy_immediate!(t_attrs)

    {tournament, notes}
  end

  # A file written before 2026-09-28 carries a `publish_mode` from the old
  # set (immediate, timed, scheduled). It gets the conversion the migration
  # that retired those gave every tournament already in the database -
  # `Tournament.legacy_publish_mode/2`, with the file's own display ticks -
  # and the old value is kept under a private key for
  # `apply_legacy_immediate!/2`, which needs to know after the rounds land.
  defp legacy_publish_mode(%{"publish_mode" => mode} = t_attrs) when is_binary(mode) do
    if Tournament.legacy_publish_mode?(mode) do
      t_attrs
      |> Map.put("publish_mode", Tournament.legacy_publish_mode(mode, t_attrs["public_display"]))
      |> Map.put(@legacy_mode_key, mode)
    else
      t_attrs
    end
  end

  defp legacy_publish_mode(t_attrs), do: t_attrs

  # "immediate" kept nothing it showed in the rows - every round, its
  # results and the finished standings were public whatever they said - so
  # an old immediate file is written out as what it showed, the same
  # conversion `AutomaticPublishingLadder` applied in the database.
  defp apply_legacy_immediate!(tournament, %{@legacy_mode_key => "immediate"}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(r in Round, where: r.tournament_id == ^tournament.id and is_nil(r.published_at)),
      set: [published_at: now]
    )

    Repo.update_all(from(r in Round, where: r.tournament_id == ^tournament.id),
      set: [results_public: true]
    )

    finished = Tournaments.standings_through_round(tournament)

    if Tournament.auto_publish_level(tournament) < 3 and finished > 0 and
         finished > (tournament.standings_through || 0) do
      tournament |> Ecto.Changeset.change(standings_through: finished) |> update!()
    else
      tournament
    end
  end

  defp apply_legacy_immediate!(tournament, _t_attrs), do: tournament

  # A new row may only take the file's SWAR guid if no tournament on this
  # machine has it - whoever owns it, deleted or not. The guid is the
  # tournament's identity in SWAR and on the federation's results site, so
  # two rows holding it would both upload as the same event, each
  # overwriting the other's page. Moving a tournament to a new machine, or
  # receiving a hand-off, finds no other row and keeps it; importing a
  # backup beside the original (or a second time) drops it, and the copy
  # mints its own the first time it goes to SWAR. Restore points write into
  # the tournament's own row (`restore_into!/2`) and never come here.
  defp unique_swar_guid(t_attrs) do
    guid = Map.get(t_attrs, "swar_guid")

    if is_binary(guid) and guid != "" and
         Repo.exists?(from(t in Tournament, where: t.swar_guid == ^guid)) do
      name = Map.get(t_attrs, "name") || ""

      {Map.put(t_attrs, "swar_guid", nil),
       [
         gettext(
           "\"%{name}\" was imported without its SWAR identity: another tournament here already has it, and two tournaments with one identity would upload to the federation's results site as the same event. The copy gets an identity of its own the first time it is exported to SWAR or published.",
           name: name
         )
       ]}
    else
      {t_attrs, []}
    end
  end

  # `standings_through` is not cast (see `Tournament.standings_through`'s own
  # field doc, same reasoning as `manual_ranking_stale`/`openresults_claim`
  # above) and needs the rounds THIS import just (re)created, with fresh ids -
  # `Tournaments.round_published?/2` and `PairingsEngine.Pairing.round_complete?/2`
  # both read from the database, not from the file - so this runs LAST, after
  # `import_rounds!/3` has landed every round and result.
  #
  # A modern export always carries the `"standings_through"` key (possibly
  # `null`, coerced through the same `coerce_int/1` every other nullable
  # integer here uses). An older backup predates the field entirely and falls
  # back to `Tournament.legacy_standings_through/3` - the same conversion the
  # `AddStandingsThrough` migration applied to every tournament already in
  # this database - fed by the rounds this import just inserted and the
  # file's own (now-retired) `"publish_starting_rank"` key.
  defp apply_standings_through!(tournament, t_attrs) do
    value =
      case Map.fetch(t_attrs, "standings_through") do
        {:ok, value} ->
          coerce_int(value)

        :error ->
          rounds = Tournaments.list_rounds(tournament.id)

          ready =
            rounds
            |> Enum.filter(fn round ->
              Tournaments.round_published?(tournament, round) and
                PairingsEngine.Pairing.round_complete?(tournament.id, round.number)
            end)
            |> MapSet.new(& &1.number)

          contiguous = contiguous_from(ready, 0)
          any_published? = Enum.any?(rounds, &Tournaments.round_published?(tournament, &1))

          Tournament.legacy_standings_through(
            contiguous,
            any_published?,
            truthy(Map.get(t_attrs, "publish_starting_rank", true))
          )
      end

    tournament |> Ecto.Changeset.change(standings_through: value) |> update!()
  end

  defp contiguous_from(set, n) do
    if MapSet.member?(set, n + 1), do: contiguous_from(set, n + 1), else: n
  end

  # The "Results round N" switch is not cast (see `Round.results_public`'s
  # own field doc), so it is carried explicitly. A modern export always has
  # the key. A backup written before the switch existed does not, and the
  # conversion is the one `AddRoundsResultsPublic` applied to every round
  # already in this database: a round that is published keeps its results
  # public, because they were public when the backup was taken. Frozen for
  # the same reason as `apply_standings_through!/2`'s fallback - an old file
  # must come back meaning what it meant.
  defp results_public(%Tournament{} = tournament, %Ecto.Changeset{} = changeset, r) do
    case Map.fetch(r, "results_public") do
      {:ok, value} ->
        truthy(value)

      :error ->
        Tournaments.round_published?(tournament, Ecto.Changeset.apply_changes(changeset))
    end
  end

  defp import_teams!(tournament, teams) do
    Map.new(teams, fn t ->
      new_team =
        %Team{tournament_id: tournament.id}
        |> Team.changeset(t)
        # Not cast, like a player's `manual_rank`: the seeding order and the
        # frozen team number have controlled writers. A payload from before
        # they were exported has neither, and a nil seed sorts by name.
        |> Ecto.Changeset.change(
          seed: coerce_int(Map.get(t, "seed")),
          pairing_number: coerce_int(Map.get(t, "pairing_number")),
          withdrawn_from_round: coerce_int(Map.get(t, "withdrawn_from_round")),
          absent_rounds: absent_rounds(Map.get(t, "absent_rounds"))
        )
        |> insert!()

      {Map.get(t, "id"), new_team.id}
    end)
  end

  # A team's rounds out as a team: whole numbers, ascending; anything else in
  # the list (or a payload from before the field) is dropped.
  defp absent_rounds(list) when is_list(list),
    do:
      list
      |> Enum.map(&coerce_int/1)
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

  defp absent_rounds(_), do: []

  # A withdrawn team's `withdrawal_player_ids` name players by their ids in
  # the payload; they become the new rows' ids once the players exist.
  defp remap_team_withdrawals!(teams, team_map, player_map) do
    for t <- teams,
        ids = Map.get(t, "withdrawal_player_ids"),
        is_list(ids) and ids != [],
        team_id = Map.get(team_map, Map.get(t, "id")),
        team_id != nil do
      remapped = ids |> Enum.map(&Map.get(player_map, &1)) |> Enum.reject(&is_nil/1)

      Repo.update_all(from(x in Team, where: x.id == ^team_id),
        set: [withdrawal_player_ids: remapped]
      )
    end

    :ok
  end

  defp team_history(p, team_map) do
    case Map.get(p, "team_history") do
      list when is_list(list) ->
        for %{"team_id" => old, "through_round" => through} <- list,
            new = Map.get(team_map, old),
            new != nil,
            do: %{"team_id" => new, "through_round" => coerce_int(through)}

      _ ->
        []
    end
  end

  defp import_players!(tournament, players, team_map) do
    Map.new(Enum.with_index(players, 1), fn {p, n} ->
      attrs = Map.put(p, "team_id", Map.get(team_map, Map.get(p, "team_id")))

      new_player =
        %Player{tournament_id: tournament.id}
        |> Player.changeset(attrs)
        # Like `manual_ranking_stale` above, `manual_rank` is deliberately not
        # cast - only the controlled reseed/move writers in `Tournaments` set
        # it. Without carrying it here, importing a tournament that used
        # manual ranking restored the flag but none of the actual order,
        # leaving it switched on with every rank nil.
        |> Ecto.Changeset.change(manual_rank: coerce_int(Map.get(p, "manual_rank")))
        # And `special_table`, for the mirror-image reason. `Player`'s
        # `sync_special_table/1` derives it from the PRESENCE of a
        # "fixed_board" key, on the stated assumption that "other writers -
        # notably the SWAR importer, which sets `special_table` directly from
        # HandyTable without going through `fixed_board` at all - never
        # include `fixed_board` in their attrs".
        #
        # This exporter does include it, always, even when its value is nil -
        # which that assumption did not anticipate. So a SWAR-imported
        # fixed-table player came back from a JSON backup or a snapshot
        # restore with `special_table` flipped to false, losing the flag that
        # keeps them on their table.
        |> Ecto.Changeset.change(special_table: !!Map.get(p, "special_table"))
        # Not cast either; its team ids are the payload's, remapped.
        |> Ecto.Changeset.change(team_history: team_history(p, team_map))
        |> insert!(player_label(p, n))

      {Map.get(p, "id"), new_player.id}
    end)
  end

  # The virtual points a round was paired with (`rounds.virtual_points`),
  # keyed by the file's player ids - re-keyed to the new rows, and a key
  # naming no player in the file dropped. Nil (a payload written before the
  # field existed, or a round that recorded none) stays nil, which the
  # pairing reads as "use the player's current extra points".
  defp remap_virtual_points(r, player_map) do
    case Map.get(r, "virtual_points") do
      %{} = virtual ->
        for {old_id, points} <- virtual,
            new_id = Map.get(player_map, old_id) || Map.get(player_map, coerce_int(old_id)),
            new_id != nil,
            is_number(points),
            into: %{},
            do: {to_string(new_id), points / 1}

      _ ->
        nil
    end
  end

  # A round's MPA PIBE line (`Round.mpa_pibe`): starting ranks, not ids, so
  # it is carried as written. Anything but a non-empty string is no record.
  defp mpa_pibe(%{"mpa_pibe" => line}) when is_binary(line) and line != "",
    do: String.slice(line, 0, 2000)

  defp mpa_pibe(_round), do: nil

  defp import_rounds!(tournament, rounds, player_map, team_map) do
    Enum.each(Enum.with_index(rounds, 1), fn {r, n} ->
      new_round =
        %Round{tournament_id: tournament.id}
        |> Round.changeset(r)
        |> then(&Ecto.Changeset.change(&1, results_public: results_public(tournament, &1, r)))
        |> Ecto.Changeset.change(publish_cap: coerce_int(Map.get(r, "publish_cap")))
        |> Ecto.Changeset.change(chess960_position: coerce_int(Map.get(r, "chess960_position")))
        |> Ecto.Changeset.change(virtual_points: remap_virtual_points(r, player_map))
        |> Ecto.Changeset.change(mpa_pibe: mpa_pibe(r))
        |> insert!("round entry #{n}")

      pairings = records!(r, "pairings")

      # A team round's matches first, so the boards can point at the new
      # rows. A match whose id a pairing names but the payload does not carry
      # leaves that pairing without a match rather than dangling.
      match_map =
        Map.new(records!(r, "matches"), fn m ->
          new_match =
            insert!(%PairingsEngine.Tournaments.Match{
              round_id: new_round.id,
              board: coerce_int(Map.get(m, "board")) || 1,
              team_a_id: Map.get(team_map, Map.get(m, "team_a_id")),
              team_b_id: Map.get(team_map, Map.get(m, "team_b_id")),
              forfeited_to_team_id: Map.get(team_map, Map.get(m, "forfeited_to_team_id")),
              forfeit_previous_results: forfeit_previous_results(m),
              double_forfeit: truthy(Map.get(m, "double_forfeit")),
              match_score_a: coerce_float(Map.get(m, "match_score_a")),
              match_score_b: coerce_float(Map.get(m, "match_score_b"))
            })

          {Map.get(m, "id"), new_match.id}
        end)

      Enum.each(pairings, fn pr ->
        attrs = %{
          "match_id" => Map.get(match_map, Map.get(pr, "match_id")),
          "board" => Map.get(pr, "board"),
          "result" => Map.get(pr, "result"),
          "white_player_id" => Map.get(player_map, Map.get(pr, "white_player_id")),
          "black_player_id" => Map.get(player_map, Map.get(pr, "black_player_id"))
        }

        %Pairing{round_id: new_round.id}
        |> Pairing.changeset(attrs)
        # The three Pairing columns deliberately kept out of
        # `changeset/2`'s cast list, each because it has exactly one
        # legitimate writer - so each has to be carried explicitly here, the
        # same way `manual_rank` and `special_table` are above. `hidden` was
        # passed in `attrs` instead and therefore silently dropped: cast
        # ignores a key it was not given, so a restore still un-hid every
        # hidden board (a disclosure, not just a lost preference) even after
        # the export half of that was fixed.
        #
        # All three default to the safe direction for a payload written
        # before they were exported: nothing hidden, no frozen label.
        |> Ecto.Changeset.change(
          hidden: truthy(Map.get(pr, "hidden")),
          display_board: display_board(Map.get(pr, "display_board")),
          display_special: truthy(Map.get(pr, "display_special")),
          # Postponed games (see `TournamentExport.pairing_map/1`); nil and
          # false for a payload written before they were exported.
          provisional_white: outcome_or_nil(Map.get(pr, "provisional_white")),
          provisional_black: outcome_or_nil(Map.get(pr, "provisional_black")),
          postponed_by:
            if(Map.get(pr, "postponed_by") in ["white", "black"], do: Map.get(pr, "postponed_by")),
          played_on: parse_date(Map.get(pr, "played_on")),
          finalised_at: parse_datetime(Map.get(pr, "finalised_at")),
          finalised_open: truthy(Map.get(pr, "finalised_open")),
          postponed_reported_at: parse_datetime(Map.get(pr, "postponed_reported_at")),
          not_played_at: parse_datetime(Map.get(pr, "not_played_at")),
          agreed_date: parse_date(Map.get(pr, "agreed_date")),
          agreed_date_log: agreed_date_log(Map.get(pr, "agreed_date_log")),
          # The game's identity, kept (`PostponedGames`); a payload written
          # before it existed leaves it to the database, which gives a new
          # one.
          game_uid: game_uid(Map.get(pr, "game_uid")),
          # A result corrected for the rating report only; nil for a payload
          # without one, and for anything that is not a result code.
          rating_result: rating_result(Map.get(pr, "rating_result")),
          corrected_from: string_or_nil(Map.get(pr, "corrected_from"))
        )
        |> insert!("a pairing of round entry #{n}")
      end)

      # The frozen labels ARE the record of what the printed sheets said,
      # so a payload that carries them is restored verbatim and this round
      # is never renumbered. Re-freezing instead would recompute every label
      # from each player's fixed_board AS IT STANDS NOW, which is precisely
      # the retroactive renumbering PairingsEngine.PairingDisplay's
      # moduledoc forbids: restore a backup taken after a mid-tournament pin
      # and round 1 comes back numbered differently from the sheets people
      # actually sat down at.
      #
      # ANY frozen label in the round is enough to call the payload
      # label-carrying. A round can legitimately hold a mix - a row inserted
      # by a path that predates the freeze has a nil label and falls back to
      # its own real board number in `PairingDisplay` - and reproducing that
      # mix is what restoring the source database faithfully means.
      #
      # A payload with none at all predates the columns; there is nothing to
      # restore, so the recompute is the best available reconstruction and
      # stays the fallback.
      unless Enum.any?(pairings, &frozen_label?/1) do
        PairingsEngine.Tournaments.freeze_round_display_boards!(new_round.id)
      end
    end)
  end

  defp game_uid(value) when is_binary(value) and byte_size(value) in 1..64, do: value
  defp game_uid(_value), do: nil

  # A Correction PIBE's original result: a short result code, or nothing.
  defp string_or_nil(value) when is_binary(value) and byte_size(value) in 1..16, do: value
  defp string_or_nil(_value), do: nil

  # The envelope's `"openresults"` block, kept as an OFFER rather than acted
  # on. It holds the key that can publish to and delete a tournament already
  # on the results site, and adopting it here would mean two people importing
  # the same file both believing they own that tournament - both publishing to
  # the same slug, either able to delete the other's work.
  #
  # So it lands in `tournaments.openresults_claim`, which nothing in the
  # publishing path reads, and the imported copy behaves as what it is: a
  # different tournament, which on its first publish gets a new address and a
  # new key of its own. Starting fresh is not a button somebody has to press -
  # it is what happens by not pressing one. Taking over is the button, and it
  # lives on the Settings page (`PairingsEngine.Publishing.adopt_claim/1`),
  # rather than being forced into this flow: one envelope can hold dozens of
  # tournaments, and a rebuilt laptop typically imports its backups before it
  # has been told the results site's address at all, so import time is the
  # worst possible moment to demand the decision.
  #
  # Rebuilt into a fresh map rather than passed through, so a hand-edited file
  # cannot smuggle extra keys into the column, and dropped entirely unless
  # both halves are usable strings - a key with no address, or an address with
  # no key, is not an offer of anything.
  defp dormant_claim(t_data) when is_map(t_data) do
    with %{} = block <- Map.get(t_data, "openresults"),
         key when is_binary(key) and key != "" <- Map.get(block, "key"),
         slug when is_binary(slug) and slug != "" <- Map.get(block, "slug") do
      endpoint = Map.get(block, "endpoint")

      %{
        "key" => key,
        "slug" => slug,
        "endpoint" => if(is_binary(endpoint), do: endpoint, else: "")
      }
    else
      _absent_or_unusable -> nil
    end
  end

  defp frozen_label?(pairing) when is_map(pairing),
    do: not is_nil(display_board(Map.get(pairing, "display_board")))

  defp frozen_label?(_), do: false

  # A label, not a number: `PairingDisplay` writes strings, and a fixed-table
  # board can be "1001" or the slash-joined "5/6". An integer is accepted
  # (a hand-edited backup, or a JSON encoder that decided "3" was numeric)
  # and anything else becomes nil, which renders as the row's real board
  # rather than as junk on a printed sheet.
  defp display_board(label) when is_binary(label), do: label
  defp display_board(label) when is_integer(label), do: Integer.to_string(label)
  defp display_board(_), do: nil

  # Schemaless tables (no Ecto schema in the app - see PairingsEngine.Pairing
  # and PairingsEngine.Standings for the same pattern on reads). A bye or
  # forbidden pairing referencing a player id that isn't in `player_map`
  # (only possible from a hand-edited/corrupt file) is silently dropped
  # rather than failing the whole import.
  # Valid `byes.type` values (see PairingsEngine.Standings.bye_points/2). An
  # imported row carrying anything else would score in nonstandard ways, so it
  # falls back to the neutral half-point bye rather than being trusted.
  @bye_types ~w(requested-half requested-zero absent pairing-allocated full-point)

  defp import_byes!(tournament, byes, player_map) do
    rows =
      byes
      |> Enum.map(fn b ->
        with player_id when not is_nil(player_id) <-
               Map.get(player_map, Map.get(b, "player_id")),
             round when is_integer(round) <- coerce_round(Map.get(b, "round")) do
          %{
            tournament_id: tournament.id,
            player_id: player_id,
            round: round,
            type: bye_type(Map.get(b, "type"))
          }
        else
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # These bypass Ecto.Changeset, so the values are checked here: SQLite's
    # dynamic typing would otherwise store a string `round` or a bogus `type`
    # straight from a hand-edited backup.
    if rows != [], do: Repo.insert_all("byes", rows)
  end

  # These two back the `Ecto.Changeset.change/2` calls above, which bypass
  # cast entirely - so a hand-edited backup's string/garbage value would
  # otherwise land in the column as-is under SQLite's dynamic typing.
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  # `public_display` round-trips as the same sparse string-key -> boolean
  # map `PairingsEngine.TournamentExport` wrote it from (see
  # `Tournament.changeset/2`'s own doc for why it is not cast: a stray form
  # field must not be able to flip it). Anything that is not a map at all
  # - the field missing from an old backup taken before it existed, or a
  # hand-edited garbage value - becomes `nil`, the same "everything shown"
  # default `PairingsEngine.PublicDisplay.show?/2` already gives a
  # tournament that has never touched the setting. Its own values are not
  # otherwise filtered: `show?/2` already tolerates a key it does not know
  # and a value that is not a real boolean, falling back to that key's
  # default exactly as it would for one this app itself never wrote.
  #
  # `public_hall` goes through the same door for the same reason:
  # `PairingsEngine.HallDisplay.resolve/1` falls back to the default for any
  # value of the wrong type or out of range, so only a non-map needs catching.
  defp public_display_or_nil(value) when is_map(value), do: value
  defp public_display_or_nil(_), do: nil

  # `public_hidden_tiebreaks` - only strings survive, the same
  # hand-edited-file defence `agreed_date_log/1` below uses; anything else,
  # including the field missing entirely, comes back `[]` (every code
  # shown), the column's own default.
  defp hidden_tiebreaks(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp hidden_tiebreaks(_), do: []

  # A postponed game's provisional outcome, from a hand-editable payload:
  # only the three values the column can hold survive.
  defp outcome_or_nil(value) when value in ~w(win draw loss), do: value
  defp outcome_or_nil(_), do: nil

  defp rating_result(value) when is_binary(value) do
    if value in PairingsEngine.Tournaments.rating_correction_codes(), do: value
  end

  defp rating_result(_), do: nil

  # A postponed game's agreed-date history: only the four string keys it is
  # written with, each a string or nil, so a hand-edited file cannot carry
  # anything else onto the page that lists it. Anything unreadable is left
  # out; a payload written before the field existed has none.
  defp agreed_date_log(entries) when is_list(entries) do
    for %{} = entry <- entries do
      Map.new(~w(from to at by), fn key ->
        {key, if(is_binary(entry[key]), do: entry[key])}
      end)
    end
  end

  defp agreed_date_log(_), do: []

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # The watermark rule for `fide_compliance_lost_round` on a restore - see
  # the long comment at `restore_into!/2`'s changeset for why it is neither
  # "keep the live value" nor "take the file's". Only ever moves toward the
  # earlier round, and never back to nil: a tournament that has once stopped
  # being compliant cannot be made to have never stopped by restoring
  # something older, and one that never was cannot lose the other copy's
  # record by coming home.
  defp earliest_compliance_loss(live, from_file) do
    case {live, coerce_int(from_file)} do
      {nil, other} -> other
      {mine, nil} -> mine
      {mine, other} -> min(mine, other)
    end
  end

  defp map_or_nil(map) when is_map(map), do: map
  defp map_or_nil(_other), do: nil

  defp coerce_int(n) when is_integer(n), do: n

  defp coerce_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp coerce_int(_), do: nil

  defp coerce_float(n) when is_number(n), do: n * 1.0

  defp coerce_float(n) when is_binary(n) do
    case Float.parse(n) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp coerce_float(_), do: nil

  defp coerce_round(round) when is_integer(round) and round > 0, do: round

  defp coerce_round(round) when is_binary(round) do
    case Integer.parse(round) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp coerce_round(_), do: nil

  defp bye_type(type) when type in @bye_types, do: type
  defp bye_type(_), do: "requested-half"

  defp import_forbidden_pairings!(tournament, forbidden, player_map) do
    rows =
      forbidden
      |> Enum.map(fn f ->
        with a when not is_nil(a) <- Map.get(player_map, Map.get(f, "player_a_id")),
             b when not is_nil(b) <- Map.get(player_map, Map.get(f, "player_b_id")) do
          # Envelopes written before soft rules existed carry no "soft" key;
          # every row in them was a rule, which is what `false` means.
          %{
            tournament_id: tournament.id,
            player_a_id: a,
            player_b_id: b,
            soft: f["soft"] == true,
            from_round:
              if(is_integer(f["from_round"]) and f["from_round"] > 1, do: f["from_round"])
          }
        else
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Through the schema, not the bare table name the other blocks use: a
    # schemaless insert has no type for `soft`, and SQLite would store the
    # boolean as the text "true", which the schema then cannot load.
    if rows != [], do: Repo.insert_all(PairingsEngine.Tournaments.ForbiddenPairing, rows)
  end

  # The pairing rules, as the file has them - or, in a file from before
  # 0.79.0, the rules its club/federation settings meant (the same reading
  # the migration that introduced rules gave every existing tournament).
  # A group rule's members are remapped like every other player reference;
  # one left with fewer than two is dropped, as a pair naming a lost player
  # is.
  defp import_pairing_rules!(tournament, entry, t_attrs, player_map) do
    attrs =
      if Map.has_key?(entry, "pairing_rules"),
        do: entry |> records!("pairing_rules") |> Enum.map(&rule_attrs(&1, player_map)),
        else: legacy_rule_attrs(t_attrs)

    for {attrs, from_round} <- Enum.reject(attrs, &is_nil/1) do
      changeset =
        %PairingsEngine.Tournaments.PairingRule{
          tournament_id: tournament.id,
          from_round: from_round
        }
        |> PairingsEngine.Tournaments.PairingRule.changeset(attrs)

      if changeset.valid?, do: Repo.insert!(changeset)
    end

    :ok
  end

  defp rule_attrs(r, player_map) do
    ids =
      r
      |> Map.get("player_ids")
      |> List.wrap()
      |> Enum.map(&Map.get(player_map, &1))
      |> Enum.reject(&is_nil/1)

    from = coerce_int(r["from_round"])

    {%{
       "kind" => r["kind"],
       "soft" => r["soft"] == true,
       "names" => List.wrap(r["names"]),
       "player_ids" => ids,
       "window" => r["window"] || "all",
       "window_rounds" => r["window_rounds"],
       "window_from" => r["window_from"],
       "window_to" => r["window_to"]
     }, if(is_integer(from) and from > 1, do: from)}
  end

  @doc false
  def legacy_rule_attrs(t_attrs) do
    hard =
      for {kind, mode_key, list_key} <- [
            {"club", "club_exclusion", "club_exclusion_list"},
            {"federation", "fed_exclusion", "fed_exclusion_list"}
          ],
          attrs <- legacy_rule(kind, t_attrs[mode_key], t_attrs[list_key]),
          do: {attrs, nil}

    soft_rounds = coerce_int(t_attrs["soft_club_rounds"])

    soft =
      if is_integer(soft_rounds) and soft_rounds > 0 and t_attrs["club_exclusion"] != "all",
        do: [
          {%{
             "kind" => "club",
             "soft" => true,
             "window" => "first",
             "window_rounds" => soft_rounds
           }, nil}
        ],
        else: []

    hard ++ soft
  end

  defp legacy_rule(kind, "all", _list), do: [%{"kind" => kind, "window" => "all"}]

  defp legacy_rule(kind, "listed", list) when is_binary(list) do
    case PairingsEngine.Exclusions.normalize_list(list) do
      [] -> []
      names -> [%{"kind" => kind, "names" => names, "window" => "all"}]
    end
  end

  defp legacy_rule(_kind, _mode, _list), do: []

  # `prohibition_changes` names players by id; the file's ids become this
  # copy's through `player_map` (an id that maps to nobody becomes nil and
  # the `###` line shows "?"). A file without the key keeps what is on the
  # row - nothing for a new copy.
  defp import_prohibition_changes!(tournament, t_attrs, player_map) do
    case Map.get(t_attrs, "prohibition_changes") do
      changes when is_list(changes) ->
        remapped =
          changes
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn c ->
            Map.update(c, "players", [], fn ids ->
              ids |> List.wrap() |> Enum.map(&Map.get(player_map, &1))
            end)
          end)

        tournament
        |> Ecto.Changeset.change(prohibition_changes: remapped)
        |> Repo.update!()

      _ ->
        tournament
    end
  end

  ## ---------- the audit trail (hand-off envelopes only) ----------

  # Detail keys holding a DB PLAYER id. These get the same treatment as
  # every other player reference in the envelope: remapped through the
  # old -> new map, so the row still names the same human being here.
  #
  # An id that maps to nobody - a row about a player who was later deleted -
  # loses the key rather than keeping the number. The number would be a
  # different person's on this machine.
  @player_id_details ~w(player_id player_a_id player_b_id)

  # Detail keys naming a row that does NOT travel in the envelope. Pairings
  # are re-inserted with fresh ids and their old ones are not even exported;
  # snapshots, mobile enrolments and other tournaments are not in the file at
  # all. Dropped, because SQLite hands out ids per table across the whole
  # database, so a stale number here is not a dangling pointer - it is a live
  # pointer at somebody else's row.
  @foreign_row_id_details ~w(
    pairing_id snapshot_id enrollment_id from_tournament_id head_snapshot_id
  )

  # And the keys that end in `_id` but are not references to a row in this
  # database at all. A FIDE ID is FIDE's number for a person and means the
  # same thing on every machine in the world; the same goes for a national
  # federation's. These survive verbatim, and they matter: they turn up
  # inside `changed_fields`, where "the FIDE ID was changed from X to Y" is
  # exactly the kind of fact somebody later disputes.
  @external_id_details ~w(fide_id national_id fide_tournament_id)

  # Anything else ending in `_id`/`_ids` is dropped. The default has to be
  # "drop": a key nobody has classified is far more likely to be a row
  # reference than an external identifier, and a gap in the record beats a
  # false statement in it. When a new `Audit.log/4` call site starts writing
  # one, put it on whichever of the three lists above is true of it.
  defp import_audit_log!(tournament, rows, player_map),
    do: Enum.each(rows, &import_audit_row!(tournament, &1, player_map))

  # `user_id` is never set. The file carries the actor as a display string
  # instead (`PairingsEngine.TournamentExport`'s `"actor"` key), and it is
  # parked in `details` under `"imported_actor"` rather than resolved
  # against the local `users` table: matching by email would attribute the
  # action to whoever holds that address HERE, who is not the person who
  # took it. A row with no local user renders as "System" until
  # `PairingsEngineWeb.AuditLive.actor/1` learns to read the stored name -
  # a one-line change in a file this one has no business editing. The
  # evidence is kept either way, which is the part that cannot be added
  # back later.
  #
  # A row with no usable action or no readable timestamp is dropped. Both
  # only happen in a hand-edited file, and an audit row without a time
  # settles nothing - stamping it with "now" would be inventing evidence,
  # which is worse than admitting the row is unreadable.
  defp import_audit_row!(tournament, row, player_map) when is_map(row) do
    with action when is_binary(action) and action != "" <- Map.get(row, "action"),
         %NaiveDateTime{} = at <- parse_naive(Map.get(row, "inserted_at")) do
      %AuditLog{tournament_id: tournament.id}
      |> AuditLog.changeset(%{"action" => action, "details" => audit_details(row, player_map)})
      |> Ecto.Changeset.change(inserted_at: at)
      |> insert!()
    else
      _unreadable -> :dropped
    end
  end

  defp import_audit_row!(_tournament, _row, _player_map), do: :dropped

  defp audit_details(row, player_map) do
    row
    |> Map.get("details")
    |> case do
      details when is_map(details) -> details
      _ -> %{}
    end
    |> sanitize_details(player_map)
    |> put_actor(Map.get(row, "actor"))
  end

  # Walks the whole `details` payload, at every depth - `changed_fields` and
  # the bye/board sub-maps are maps too, and an id buried in one is no less
  # stale than an id at the top.
  defp sanitize_details(details, player_map) when is_map(details) and not is_struct(details) do
    details
    |> Enum.flat_map(fn {key, value} -> sanitized_detail(key, value, player_map) end)
    |> Map.new()
  end

  defp sanitize_details(values, player_map) when is_list(values),
    do: Enum.map(values, &sanitize_details(&1, player_map))

  defp sanitize_details(value, _player_map), do: value

  defp sanitized_detail(key, value, player_map) when key in @player_id_details do
    case Map.get(player_map, value) do
      nil -> []
      new_id -> [{key, new_id}]
    end
  end

  defp sanitized_detail(key, _value, _player_map) when key in @foreign_row_id_details, do: []

  defp sanitized_detail(key, value, player_map) do
    if row_reference_key?(key),
      do: [],
      else: [{key, sanitize_details(value, player_map)}]
  end

  defp row_reference_key?(key) when is_binary(key) do
    key not in @external_id_details and
      (String.ends_with?(key, "_id") or String.ends_with?(key, "_ids"))
  end

  defp row_reference_key?(_key), do: false

  defp put_actor(details, actor) when is_binary(actor) and actor != "",
    do: Map.put(details, "imported_actor", actor)

  defp put_actor(details, _actor), do: details

  # Second precision, matching the column. `Ecto.Changeset.change/2` bypasses
  # cast, so anything with microseconds left on it would be rejected at dump
  # time rather than quietly rounded.
  defp parse_naive(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, at} -> NaiveDateTime.truncate(at, :second)
      _ -> nil
    end
  end

  defp parse_naive(_value), do: nil

  ## ---------- collaborators (hand-off envelopes only) ----------

  # Filed as PENDING invitations, always, whatever the source row said - the
  # export does not even carry `status` (see its `@collaborator_excluded`).
  # An import is a file arriving on a machine, and a file must not hand
  # anybody the tournament: the invited address may belong to somebody else
  # entirely here, and "this person had accepted" was a statement about an
  # account on an instance this one cannot see. So the row lands exactly
  # where `Tournaments.add_collaborator/3` puts a new one, and the same
  # `accept_invitation/2` unlocks it.
  #
  # No email goes out. Importing a backup must not send mail to third
  # parties, and the invitee finds the invitation on their own Tournaments
  # page anyway (`Tournaments.list_pending_invitations/1` matches by email);
  # the owner can also hand over `/invites/<token>` from Settings.
  #
  # `user_id` is left nil even when this machine already has an account for
  # that address. Nil never grants anything - only `status == "accepted"`
  # does - and the link gets made properly on that person's next login by
  # `Tournaments.link_pending_collaborators/1`, which is the documented path
  # for exactly this case.
  defp import_collaborators!(tournament, collaborators),
    do: Enum.each(collaborators, &import_collaborator!(tournament, &1))

  defp import_collaborator!(tournament, collaborator) when is_map(collaborator) do
    case Map.get(collaborator, "email") do
      email when is_binary(email) and email != "" ->
        %Collaborator{tournament_id: tournament.id}
        |> Collaborator.changeset(collaborator_attrs(email, Map.get(collaborator, "role")))
        |> insert!()

      # Nobody to invite. Skipped rather than failing the whole tournament
      # import, because there is nothing here to lose - unlike the role
      # below, which we would have to guess at.
      _no_email ->
        :dropped
    end
  end

  defp import_collaborator!(_tournament, _collaborator), do: :dropped

  # A fresh token, never the file's: the source's is a live bearer link to
  # `/invites/:token` and is unique across the table, so carrying it would
  # put the same working link on two machines. Same recipe as
  # `Tournaments.add_collaborator/3`, whose generator is private to it.
  #
  # A role is an access level, so an unrecognised one is left for
  # `Collaborator.changeset/2` to reject, which rolls the import back with a
  # readable error. Guessing at it would either over- or under-grant, and
  # both are worse than refusing a file that says something this build does
  # not understand. A missing role simply takes the schema's default.
  defp collaborator_attrs(email, role) do
    attrs = %{
      "email" => email,
      "status" => "pending",
      "invite_token" => :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    }

    if is_binary(role) and role != "", do: Map.put(attrs, "role", role), else: attrs
  end

  ## ---------- helpers ----------

  # Same conversion the `MigrateLegacyCategoryRules` data migration runs
  # over every existing tournament in the database - here for a file that
  # still carries the pre-conversion `"kind"`/`"value"` shape, whether an
  # old backup being imported fresh or one being restored over a live
  # tournament. See `CategoryRules.migrate_legacy_rules/2` for what "still
  # carries" means: entries already in the new shape pass through
  # untouched, so this is a no-op on a file exported after that migration
  # shipped.
  defp migrate_legacy_category_rules(%{"category_rules" => rules} = t_attrs)
       when is_map(rules) and map_size(rules) > 0 do
    categories = t_attrs |> Map.get("categories") |> List.wrap()
    Map.put(t_attrs, "category_rules", CategoryRules.migrate_legacy_rules(rules, categories))
  end

  defp migrate_legacy_category_rules(t_attrs), do: t_attrs

  defp fetch_map!(data, key) do
    case Map.get(data, key) do
      m when is_map(m) -> m
      _ -> Repo.rollback("Malformed tournament entry in export file (missing \"#{key}\").")
    end
  end

  # A record list the import walks with `Map.get/2`: absent (or not a list)
  # is still an empty list, as `list/2` reads it, but an element that is not
  # a JSON object used to raise `BadMapError` straight out of the transaction
  # - and out of the LiveView consuming the upload with it. Refused here, by
  # key and position, so whoever wrote the file can find the line.
  defp records!(data, key) do
    records = list(data, key)

    case Enum.find_index(records, &(not is_map(&1))) do
      nil ->
        records

      index ->
        Repo.rollback("Could not import: entry #{index + 1} of \"#{key}\" is not a JSON object.")
    end
  end

  defp list(data, key) do
    case Map.get(data, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  # A forfeit decision's replaced board results: board number (as a string)
  # to a result code. Anything else in a hand-edited payload is dropped,
  # which leaves the decision in place with nothing to withdraw it to.
  defp forfeit_previous_results(m) do
    case Map.get(m, "forfeit_previous_results") do
      previous when is_map(previous) ->
        for {board, result} <- previous,
            is_binary(result) and result in PairingsEngine.Results.codes(),
            into: %{},
            do: {to_string(board), result}

      _ ->
        nil
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        Repo.rollback("Could not import: " <> changeset_error_text(changeset))
    end
  end

  # The same, saying which record of the file was refused - "birth_date is
  # invalid" alone leaves the writer of a six-player file guessing which
  # player, and of a backup with hundreds, hopeless.
  defp insert!(changeset, where) do
    case Repo.insert(changeset) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        Repo.rollback("Could not import #{where}: " <> changeset_error_text(changeset))
    end
  end

  defp player_label(p, n) do
    case Map.get(p, "id") do
      id when is_integer(id) or is_binary(id) -> "player entry #{n} (id #{id})"
      _ -> "player entry #{n}"
    end
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
