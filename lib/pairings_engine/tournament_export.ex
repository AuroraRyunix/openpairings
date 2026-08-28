defmodule PairingsEngine.TournamentExport do
  @moduledoc """
  Full-fidelity JSON backup of one or more tournaments - everything
  OpenPairings models for a tournament (settings incl. officials/norm
  metadata, teams, players incl. `norm_data`, rounds, pairings/results,
  byes, forbidden pairings), as opposed to `PairingsEngine.TrfExport`'s
  FIDE-report-shaped TRF16 output. See `docs/import-export.md` for the
  envelope format and `PairingsEngine.TournamentImport` for the inverse.

  The owning user is deliberately never included - an import always creates
  brand-new tournaments owned by whoever imports the file. Every other id
  (tournament, team, player, round) is carried along verbatim as `"id"`
  purely so sibling records within the *same* envelope (pairings under a
  round, byes, forbidden pairings) can reference the right team/player; the
  importer discards these ids and remaps everything to fresh ones.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
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
  )a

  # Deliberately NOT exported, with the reason for each - asserted by the
  # same test, so adding a schema field forces a conscious choice rather
  # than a silent omission.
  #
  #   id, user_id, inserted_at, updated_at
  #     Identity/ownership. An import always mints a new row owned by
  #     whoever imports it (see this module's moduledoc).
  #   public_slug
  #     The imported copy must get its own unguessable link, not share the
  #     original's - otherwise one leaked link exposes both.
  #   public_pages_enabled, registration_open, publish_to_openresults
  #     Sharing must be an explicit opt-in per tournament, never inherited
  #     from a file someone was handed. All three default off on the new row.
  #     `publish_to_openresults` is the sharpest of them: importing a file
  #     must not cause this machine to start sending a copy of it to whatever
  #     server this machine happens to be configured for - which is not the
  #     one the exporter was pointing at, and may not be one the exporter
  #     knows exists.
  #   deleted_at, archived_at
  #     Lifecycle state of *that* row. An import is always a live,
  #     editable tournament.
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
  @excluded_tournament_fields ~w(
    id user_id inserted_at updated_at public_slug public_pages_enabled
    registration_open publish_to_openresults deleted_at archived_at swar_guid
    logo_data logo_content_type head_snapshot_id
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

  @doc false
  def round_excluded, do: @round_excluded

  @doc false
  def pairing_excluded, do: @pairing_excluded

  @doc false
  def round_fields, do: @round_fields

  @doc "Envelope wrapping a single tournament (caller is responsible for owner-scoping it)."
  def export_tournament(%Tournament{} = tournament), do: envelope([tournament])

  @doc "Envelope wrapping every tournament `scope`'s user owns or collaborates on."
  def export_all(%Scope{} = scope) do
    tournaments =
      scope |> Tournaments.list_tournaments() |> Enum.map(fn {t, _count, _owner?} -> t end)

    envelope(tournaments)
  end

  defp envelope(tournaments) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "tournaments" => Enum.map(tournaments, &tournament_map/1)
    }
  end

  defp tournament_map(t) do
    %{
      "tournament" => struct_fields(t, @tournament_fields),
      "teams" => Enum.map(Tournaments.list_teams(t.id), &team_map/1),
      "players" => Enum.map(Tournaments.list_players(t.id), &player_map/1),
      "rounds" => Enum.map(rounds_with_pairings(t.id), &round_map/1),
      "byes" => byes(t.id),
      "forbidden_pairings" => forbidden_pairings(t.id)
    }
  end

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
