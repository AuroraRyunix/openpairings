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

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.{Collaborator, Tournament, Team, Player, Round, Pairing}

  # Kept as literals (rather than referencing PairingsEngine.TournamentExport
  # here) so the two modules have no compile-time dependency on each other;
  # `PairingsEngine.TournamentExport.format/0` and `.version/0` return the
  # same values and both are covered by round-trip tests.
  @format "openpairings-export"
  @version 1

  @doc """
  Imports every tournament in `data` (a JSON-decoded export envelope) as new
  tournaments owned by `scope`'s user. Returns `{:ok, [%Tournament{}, ...]}`
  on success (broadcasting the user's tournament-list change once, after
  commit) or `{:error, reason}` - `reason` is a human-readable string safe
  to show directly in a flash. Never raises: a malformed envelope, a bad
  format/version tag, or an invalid record anywhere inside it rolls the
  whole import back and comes back as `{:error, _}`, not a crash.
  """
  def import(data, %Scope{} = scope) when is_map(data) do
    cond do
      Map.get(data, "format") != @format ->
        {:error, "This file is not an OpenPairings export (unrecognized format)."}

      Map.get(data, "version") != @version ->
        {:error, "Unsupported export version #{inspect(Map.get(data, "version"))}."}

      not valid_tournaments_list?(data) ->
        {:error, "This export file contains no tournaments to import."}

      true ->
        do_import(Map.fetch!(data, "tournaments"), scope)
    end
  end

  def import(_invalid, %Scope{}), do: {:error, "This file is not a valid OpenPairings export."}

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
  defp do_import(tournaments, scope) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn -> Enum.map(tournaments, &import_tournament!(&1, scope)) end)
      end)

    case result do
      {:ok, imported} ->
        Enum.each(imported, &Tournaments.broadcast_tournament_change(&1.id, :tournament))
        Tournaments.broadcast_user_tournaments(scope.user.id)
        refreshed = Enum.map(imported, &Tournaments.refresh_status!(&1.id))
        {:ok, refreshed}

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
    t_attrs = fetch_map!(entry, "tournament")

    tournament =
      tournament
      |> Tournament.changeset(t_attrs)
      |> Ecto.Changeset.change(
        manual_ranking_stale: truthy(Map.get(t_attrs, "manual_ranking_stale"))
      )
      |> update!()

    team_map = import_teams!(tournament, list(entry, "teams"))
    player_map = import_players!(tournament, list(entry, "players"), team_map)
    import_rounds!(tournament, list(entry, "rounds"), player_map)
    import_byes!(tournament, list(entry, "byes"), player_map)
    import_forbidden_pairings!(tournament, list(entry, "forbidden_pairings"), player_map)

    tournament
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} ->
        record

      {:error, changeset} ->
        Repo.rollback("Could not restore: " <> changeset_error_text(changeset))
    end
  end

  ## ---------- per-tournament import (runs inside the transaction) ----------

  defp import_tournament!(t_data, _scope) when not is_map(t_data) do
    Repo.rollback("Malformed tournament entry in export file.")
  end

  defp import_tournament!(t_data, scope) do
    t_attrs = fetch_map!(t_data, "tournament")

    tournament =
      %Tournament{user_id: scope.user.id}
      |> Tournament.changeset(t_attrs)
      # `manual_ranking_stale` is deliberately outside `changeset/2`'s cast
      # list (only the manual-ranking writers in `Tournaments` set it), so it
      # has to be carried across explicitly or an imported tournament with a
      # stale hand-set order would come back claiming to be fresh.
      |> Ecto.Changeset.change(
        manual_ranking_stale: truthy(Map.get(t_attrs, "manual_ranking_stale")),
        # The file's publishing key, filed away DORMANT - see
        # `dormant_claim/1`. Note where it comes from: `t_data`, the envelope
        # entry, not `t_attrs`. It is not a tournament field and is not cast,
        # which is what makes "an import never adopts a key" a property of
        # the schema rather than a rule this function has to remember.
        openresults_claim: dormant_claim(t_data)
      )
      |> insert!()

    team_map = import_teams!(tournament, list(t_data, "teams"))
    player_map = import_players!(tournament, list(t_data, "players"), team_map)
    import_rounds!(tournament, list(t_data, "rounds"), player_map)
    import_byes!(tournament, list(t_data, "byes"), player_map)
    import_forbidden_pairings!(tournament, list(t_data, "forbidden_pairings"), player_map)

    # Last, and after the players, because an audit row's `details` can
    # name a player and the remap needs the finished map. Both blocks are
    # absent from an ordinary envelope, in which case `list/2` hands back
    # `[]` and neither loop does anything.
    import_audit_log!(tournament, list(t_data, "audit_log"), player_map)
    import_collaborators!(tournament, list(t_data, "collaborators"))

    tournament
  end

  defp import_teams!(tournament, teams) do
    Map.new(teams, fn t ->
      new_team = %Team{tournament_id: tournament.id} |> Team.changeset(t) |> insert!()
      {Map.get(t, "id"), new_team.id}
    end)
  end

  defp import_players!(tournament, players, team_map) do
    Map.new(players, fn p ->
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
        |> insert!()

      {Map.get(p, "id"), new_player.id}
    end)
  end

  defp import_rounds!(tournament, rounds, player_map) do
    Enum.each(rounds, fn r ->
      new_round = %Round{tournament_id: tournament.id} |> Round.changeset(r) |> insert!()

      pairings = list(r, "pairings")

      Enum.each(pairings, fn pr ->
        # `match_id` is deliberately not carried across - it's a foreign key
        # into the unexported `matches` table, so a raw value would dangle.
        # See PairingsEngine.TournamentExport.pairing_map/1.
        attrs = %{
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
          display_special: truthy(Map.get(pr, "display_special"))
        )
        |> insert!()
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
  @bye_types ~w(requested-half requested-zero absent pairing-allocated)

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

  defp coerce_int(n) when is_integer(n), do: n

  defp coerce_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp coerce_int(_), do: nil

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
          %{tournament_id: tournament.id, player_a_id: a, player_b_id: b}
        else
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if rows != [], do: Repo.insert_all("forbidden_pairings", rows)
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

  defp fetch_map!(data, key) do
    case Map.get(data, key) do
      m when is_map(m) -> m
      _ -> Repo.rollback("Malformed tournament entry in export file (missing \"#{key}\").")
    end
  end

  defp list(data, key) do
    case Map.get(data, key) do
      l when is_list(l) -> l
      _ -> []
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

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
