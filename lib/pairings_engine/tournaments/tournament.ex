defmodule PairingsEngine.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(swiss roundrobin team-swiss team-roundrobin)
  @accelerations ~w(none baku)
  @statuses ~w(setup running finished)
  @standards ~w(standard rapid blitz)
  # Which pairing engine PairingsEngine.Pairing.pair_next_round/1 dispatches
  # to - independent of `type` above (FIDE report classification).
  @pairing_systems ~w(swiss round_robin keizer)
  # Which Swiss engine actually pairs the round, once `pairing_system` has
  # already decided the Swiss path runs at all - round robin and Keizer never
  # reach an engine, so this setting is inert for them (see
  # `PairingsEngine.Pairing.pair_next_round/1`). "ainalrami" is the default
  # (see the field itself below); BOTH values are permitted on a
  # FIDE-homologated tournament since 2026-08-21 - the UI warns rather than
  # blocking. See `validate_pairing_engine/1` below, which now refuses
  # nothing and carries the reasoning, and docs/fide-endorsement.md.
  #
  # This comment said the opposite of both for six days: "javafo" as the
  # default, and the only value a homologated tournament permits. It is the
  # copy anyone grepping for `@pairing_engines` reads first, and it cited
  # the two sources that refute it.
  @pairing_engines ~w(javafo ainalrami)
  @rr_cycles_values [1, 2]
  # How a newly-paired round becomes visible on the public pairings page
  # (`PairingsEngineWeb.PublicPairingsLive`) - see
  # `PairingsEngine.Tournaments.compute_published_at/2` for what each one
  # actually computes, and `round_published?/2` for the visibility check
  # itself. "immediate" (the default) is today's only behaviour, unchanged:
  # a round is public the instant it's paired.
  @publish_modes ~w(immediate manual timed scheduled)
  # Club/federation pairing-exclusion rules (SWAR parity #7-10) - see
  # PairingsEngine.Exclusions and docs/forbidden-pairings.md.
  @exclusion_modes ~w(none all listed)

  schema "tournaments" do
    field :name, :string
    field :type, :string, default: "swiss"
    field :venue, :string, default: ""
    field :city, :string, default: ""
    field :federation, :string, default: ""
    # Both DERIVED, always - the earliest/latest non-blank entry in
    # `round_dates` (see `derive_dates_from_round_dates/1`), never set
    # directly. Still plain stored columns (not virtual): every reader -
    # TRF/SWAR/PGN export, the FIDE-report forms, the tournament list -
    # keeps reading these two fields exactly as before; only WRITING them
    # changed. Kept out of `cast/3`'s field list below on purpose, so
    # nothing (an import, a stale form, a future call site) can set them
    # independently even by accident - the changeset recomputes both from
    # `round_dates` unconditionally, every single save.
    field :start_date, :string, default: ""
    field :end_date, :string, default: ""
    field :organizer, :string, default: ""
    field :chief_arbiter, :string, default: ""
    field :deputy_arbiter, :string, default: ""
    field :time_control, :string, default: ""
    field :rounds_count, :integer, default: 9
    field :points_win, :float, default: 1.0
    field :points_draw, :float, default: 0.5
    field :points_loss, :float, default: 0.0
    field :bye_value, :float, default: 1.0
    # SWAR "3-2-1" custom-scoring `SW321_Pre` ("presence points") - the
    # points paid for an unpaired-but-present round, a distinct concept from
    # an ordinary configured `points_loss`. nil (the default for every
    # tournament not imported from a SWAR 3-2-1 file) means "unused": such
    # rounds keep scoring at `points_loss` exactly as before this field
    # existed. Only PairingsEngine.SwarImport writes a non-nil value.
    field :presence_value, :float
    # SWAR `AbsValue` - the points paid for a player simply marked ABSENT
    # for a round (our `byes`-table `type: "absent"` row, from SWAR's
    # per-player `Absent` status / the per-round `TABLE_ABSENT` special
    # value). It's a plain UI checkbox ("½ point" for absence) in SWAR's
    # own source, raw 0 (unchecked) or 1 (checked) - NOT the "0 or 5" an
    # earlier version of this comment (and the mapping in
    # `PairingsEngine.SwarImport`) assumed; see that module's
    # `tournament_attrs/1` for the full story of that bug and how it was
    # confirmed. Three genuinely different SWAR concepts, easy to conflate:
    # `bye_value` is what a *pairing-allocated* bye (a real opponent-less
    # `Pairing` row) is worth; `presence_value` is the 3-2-1 "presence
    # points" paid for an unpaired-but-present round (`SW321_Pre`, only
    # meaningful when `TOURNOI_TYPE == 3`); `abs_value` here is what a
    # plain absence is worth, and - unlike `presence_value` - it is a
    # GENERAL [TOURNOI] header field that applies to every SWAR import
    # regardless of tournament type. nil (the default for every tournament
    # that isn't a SWAR import) means "not set": such rounds keep scoring
    # at `points_loss` exactly as before this field existed. Only
    # PairingsEngine.SwarImport writes a non-nil value. See `abs_jusque`/
    # `abs_nbfois` below for the two caps SWAR applies on top of this.
    field :abs_value, :float
    # SWAR `AbsJusque` ("Jusque ronde") / `AbsNbFois` ("Nombre de fois") -
    # the two caps SWAR's own "Pt ABSENT" option applies on top of
    # `abs_value`, easy to miss because they're separate UCHAR fields right
    # next to `AbsValue` in the file rather than folded into it:
    #
    #   - `abs_jusque`: the last round, INCLUSIVE, a plain absence still
    #     pays `abs_value` - round `abs_jusque + 1` onward scores
    #     `points_loss` instead, same as if `abs_value` were unset.
    #   - `abs_nbfois`: how many absences, cumulative across the
    #     tournament so far (this round included), still pay `abs_value` -
    #     the `(abs_nbfois + 1)`th and any later absence scores
    #     `points_loss` instead.
    #
    # Both nil (the default for every tournament that isn't a SWAR import,
    # and for older SWAR imports predating this field) means "no cap" -
    # `PairingsEngine.Standings.bye_points/4` treats a nil cap as never
    # exceeded, so scoring is unaffected until a real value is set. Only
    # PairingsEngine.SwarImport writes non-nil values.
    field :abs_jusque, :integer
    field :abs_nbfois, :integer
    # Whether an "absent" byes-table row (a plain no-show - distinct from a
    # requested bye or a forfeit) is treated as a voluntary unplayed round
    # for tiebreak purposes (FIDE C.07 Art. 16: trailing occurrences get
    # downgraded to a draw for opponents' Buchholz/SB, and it becomes
    # eligible for the Art. 16.5.1 Cut-1 priority). FIDE's own rules have no
    # "absent" concept at all, which is why this is a setting rather than a
    # constant.
    #
    # ON by default. An absence and a requested bye are the same event under
    # two names - you only ever know somebody is out BEFORE the round is
    # paired because they told you, and an unannounced no-show gets paired
    # and forfeits on their board instead. Treating the two differently for
    # tie-break purposes split one thing in half. An arbiter can turn it off
    # from Settings for the stricter reading, where an absence always counts
    # at its configured award value like a forfeit loss.
    # See `PairingsEngine.Standings.add_bye_records/3`.
    field :absent_counts_as_vur, :boolean, default: true
    # SWAR `SW321_PreBye` (manual §5.16, "Add presence points for bye
    # games") - when true, a pairing-allocated bye pays `presence_value` ON
    # TOP of `bye_value` (SWAR pays SW321_Bye + SW321_Pre for a WIN_BYE
    # round when this club option is on). Kept as a flag rather than folded
    # into `bye_value` at import so `bye_value` keeps meaning exactly the
    # club's configured SW321_Bye. Consulted only by
    # `PairingsEngine.Standings.bye_points/2`'s "pairing-allocated" branch;
    # false (the default for every tournament that isn't a SWAR 3-2-1
    # import) leaves scoring byte-identical to before this field existed.
    # Only PairingsEngine.SwarImport sets it true (type == 3 files only).
    field :presence_on_allocated_bye, :boolean, default: false
    field :tiebreaks, {:array, :string}, default: []
    field :acceleration, :string, default: "none"
    field :status, :string, default: "setup"

    # standard | rapid | blitz (SWAR TournoiStd)
    field :standard, :string, default: "standard"
    field :rate_of_play, :string, default: ""
    field :organizer_club_number, :string, default: ""
    # SWAR's own per-tournament GUID - see docs/import-export.md's re-upload
    # section. nil for tournaments never imported from SWAR.
    field :swar_guid, :string
    # ISO dates, index = round-1
    field :round_dates, {:array, :string}, default: []
    # tournament-defined category names (SWAR CATEGORIES)
    field :categories, {:array, :string}, default: []

    # Optional threshold RULE behind a category name, keyed by that name -
    # `%{"-1100" => %{"kind" => "elo_below", "value" => 1100}}`. `kind` is
    # one of "elo_below" | "elo_above" | "age_below" | "age_above". A
    # category with no entry here stays exactly what it always was: a
    # plain name the arbiter assigns to `player.category` by hand on the
    # Players page. One with a rule can instead be filled in for every
    # player at once via `Tournaments.auto_assign_categories/1` - see
    # `PairingsEngine.PlayerStats.assign_category/4` for how a player
    # matching more than one threshold picks the tightest.
    field :category_rules, :map, default: %{}

    # FIDE "Code of event" (FA1/IA1 B6, IT4 S4 "FIDE Event code")
    field :event_code, :string, default: ""
    # FIDE "ID of Tournament" (IT3 B2) - the report's own numeric ID.
    #
    # DECISION (see `fide_id_ranges` below for the full per-round model):
    # this plain field remains the tournament-WIDE **fallback/default** ID.
    # It is what `PairingsEngine.TrfExport.applicable_fide_id/2` returns when
    # no single configured `fide_id_ranges` entry fully covers the exported
    # round range (no ranges configured at all, the range spans/partially
    # overlaps more than one entry, or matches none) - never fully
    # superseded by the per-round mechanism. Blank means "no ID at all" for
    # that fallback case (the TRF filename's FIDE-ID segment is then simply
    # omitted, e.g. a non-homologated tournament).
    field :fide_tournament_id, :string, default: ""
    # "This tournament is FIDE-rated/reportable" - an informational tickbox
    # surfaced on the FIDE settings page. Not itself read by TrfExport (the
    # export logic only cares whether an ID resolves, per
    # `applicable_fide_id/2`), but kept here as the single place an arbiter
    # marks a tournament homologated for FIDE rating purposes.
    field :fide_homologated, :boolean, default: false
    # SWAR's per-round FIDE-ID-range model ("FIDE id 89495 applies to
    # rounds 1-3, this other id applies to rounds 4-9, ...") - for splitting
    # one club's FIDE report across differently-rated sections/legs of the
    # same tournament. An ordered list of
    # `%{"fide_tournament_id" => string, "from_round" => integer, "to_round" => integer}`
    # maps (a plain `{:array, :map}`, like `officials` is a plain `:map` -
    # this project doesn't otherwise use Ecto embedded schemas for map-shaped
    # config data, so this follows that existing precedent rather than
    # introducing one). Validated by `normalize_fide_id_ranges/1` below:
    # every entry needs a non-blank `fide_tournament_id` and
    # `from_round <= to_round`, and entries may never overlap each other.
    # Canonicalized (sorted by `from_round`, round numbers coerced to
    # integers) on every write, same pattern as `extra_points_bands`.
    # Consulted by `PairingsEngine.TrfExport.applicable_fide_id/2` - see
    # `fide_tournament_id` above for the fallback behaviour when no entry
    # here unambiguously covers the exported round range.
    field :fide_id_ranges, {:array, :map}, default: []

    # Officials / pairing-system / FIDE-report metadata that doesn't
    # warrant its own column each - recognised string keys (all optional,
    # blank/missing means "not set"):
    #
    #   organizer_id, organizer_email            - IT3 B8/B10
    #   chief_arbiter_fide_id, chief_arbiter_email - IT3 B59/B61, FA1/IA1 B18
    #   deputyN_name, deputyN_fide_id, deputyN_email (N in 1..2 - FIDE only
    #     ranks 2 deputies by name) - IT3 B62-B65
    #   extra_arbiters_count, arbiterN_name, arbiterN_fide_id (N in
    #     1..extra_arbiters_count) - arbiters beyond the 2 ranked deputies,
    #     unranked on IT3 (see PairingsEngine.Norms.ItThreeExpand)
    #   pairing_mode                             - "computerized" | "manual" (IT3 B19/B21)
    #   pairing_program                          - IT3 B22
    #   swiss_variant                            - "Dutch" | "Lim" | "Dubov" | "Burstein" (IT3 B17)
    #   person_responsible_pairings              - IT3 B20
    #   remark1..remark4                         - IT3 B23-B26 (free text)
    #   it4_event_type                           - IT4 S6 "Event type"
    #   pairings_web_link                        - IT4 Y4 "Link to pairings web"
    field :officials, :map, default: %{}

    # This tournament's ADDRESS on the results site - the `:slug` in
    # OpenResults' `/t/:slug`. See docs/public-pages.md.
    #
    # Deliberately not the numeric `id`, which is sequential and easy to
    # enumerate. Always set (never nil) - see `put_public_slug/1` below,
    # applied by every creation path, including tournaments created long
    # before anything was published anywhere.
    #
    # It was an unguessable token for local read-only pages until those were
    # removed on 2026-08-29; being unguessable still earns its keep, because
    # a published tournament is world-readable and the slug is all that
    # stands between a scraper and enumerating every event on the site.
    #
    # Rotated by Tournaments.rotate_public_slug/1 - but see
    # `PairingsEngine.Publishing.rotate_address/1`, which is the operation
    # that actually revokes a leaked link.
    field :public_slug, :string

    # Whether the results site's entry form accepts entries for this
    # tournament. Toggled by Tournaments.set_registration_open/2, and NOT
    # cast by changeset/2 - an ordinary settings save must not be able to
    # open the doors by accident.
    #
    # Unlike every other flag here it is not enforced on this machine at
    # all: the form is on the results site, so this only takes effect by
    # riding along in the published snapshot. It means nothing for a
    # tournament that does not publish.
    #
    # Default false: this is the one flag that lets strangers write into an
    # arbiter's tournament, so it is opt-in per event rather than something
    # an existing tournament inherits on upgrade.
    field :registration_open, :boolean, default: false

    # Whether this tournament is published to OpenResults at all. Toggled by
    # Tournaments.set_publish_to_openresults/2, and NOT cast by changeset/2
    # for the same reason as the three fields above: an ordinary settings
    # save must not be able to start sending an event's player names,
    # ratings and clubs to a remote server by accident.
    #
    # Whether the tournament appears in the results site's index, as opposed
    # to being reachable only by its address. Default true, which is what
    # publishing has always meant.
    #
    # Not a security control, and the settings page says so in as many words.
    # The address is an unguessable token, but an unlisted tournament is
    # still world-readable to anyone holding one. This hides an event from
    # somebody browsing the site, not from somebody who was sent the link.
    field :public_listed, :boolean, default: true

    # Which columns the public page may show: a map of string key -> boolean,
    # or nil for "everything", which is what every tournament that predates
    # this field means.
    #
    # A map rather than a column per field, because the set will grow and
    # because the ABSENCE of a key has to read as "show it" on both sides. A
    # snapshot written by an older arbiter's app must not blank a column on a
    # newer results site, and an older results site must ignore a key it does
    # not know rather than guessing.
    #
    # See `PairingsEngine.PublicDisplay` for the keys and the defaults; this
    # column stores only what an arbiter has actually changed.
    field :public_display, :map

    # Default false. It used to sit beside `public_pages_enabled`, which
    # answered the separate question "may anyone with the link read this
    # HERE" - that field was dropped on 2026-08-29 with the local public
    # pages, and its intent migrated into this one. There is now a single
    # question, "is this tournament public", and this is it.
    field :publish_to_openresults, :boolean, default: false

    # This tournament's key on the OpenResults server: random, minted on this
    # machine at the FIRST publish, sent with every publish afterwards, and
    # required by the server both to publish again and to delete. Written only
    # by `PairingsEngine.Publishing` - `ensure_key/1` mints it, `take_down/1`
    # clears it, `adopt_claim/1` accepts one carried in from a backup.
    #
    # Two separate questions, and the ingest token only answers the first:
    # the token asks "may this machine talk to this server", this asks "may it
    # touch THIS tournament". One shared token meant anything holding it could
    # overwrite any tournament, and nothing could take one down.
    #
    # NOT cast by changeset/2, and that is load-bearing rather than tidy: the
    # export envelope CARRIES this key (rebuilding a laptop from a backup has
    # to recover the ability to manage what it published), and both
    # `TournamentImport` and `Snapshots.restore/3` write through
    # `changeset/2`. Keeping it out of `cast` is therefore what makes an
    # import structurally unable to adopt somebody else's key and a restore
    # structurally unable to wipe or rewrite this one, rather than something
    # each of those paths has to remember not to do.
    field :openresults_key, :string

    # A key an imported backup carried, held DORMANT:
    # `%{"key" => ..., "slug" => ..., "endpoint" => ...}`, or nil.
    #
    # Nothing in the publishing path ever reads this. If an import adopted a
    # key automatically, two people importing the same file would both believe
    # they own the tournament, both publish to the same slug, and either could
    # delete the other's work. So the file's key lands here, the imported copy
    # behaves as an entirely separate tournament, and taking the published one
    # over is a deliberate act on the Settings page
    # (`PairingsEngine.Publishing.adopt_claim/1`).
    #
    # Written only by `TournamentImport` (which stores it) and `Publishing`
    # (which adopts or discards it). Not cast, for the same reason as the key.
    field :openresults_claim, :map

    # How long a newly-paired round takes to reach the public pairings
    # page - see `@publish_modes`'s own comment above, and
    # `PairingsEngine.Tournaments.compute_published_at/2`/`round_published?/2`
    # for what these two actually drive. Unlike `publish_to_openresults`/
    # `registration_open` above, these ARE cast by the ordinary changeset -
    # this is an ordinary settings choice on the Options page, not a
    # separate toggle-action.
    field :publish_mode, :string, default: "immediate"
    field :publish_delay_minutes, :integer, default: 0

    # Pairing engine dispatch (see PairingsEngine.Pairing.pair_next_round/1):
    # "swiss" | "round_robin" | "keizer". Locked in the UI once the
    # tournament has paired its first round (see SettingsLive).
    field :pairing_system, :string, default: "swiss"
    # Swiss only: which engine pairs the round - "ainalrami" (the default,
    # the sibling from-scratch Elixir Dutch engine,
    # github.com/AuroraRyunix/Ainalrami) or "javafo" (the external Java
    # program this app shelled out to first). Both are handed the
    # byte-identical TRF16 the pipeline already builds, so the two stay
    # directly comparable; see PairingsEngine.Pairing and
    # docs/pairing-systems.md.
    #
    # Read ONLY on the Swiss path - round robin (Berger) and Keizer compute
    # their own pairings and never consult it, same "inert unless swiss"
    # tolerance as `acceleration`/`swiss_match_format`.
    #
    # Neither combination this field used to refuse is refused any more -
    # Ainalrami on a homologated tournament, and Ainalrami with Baku
    # acceleration - see `validate_pairing_engine/1` below for why each
    # went. Still locked once the tournament has paired its first round,
    # same as `pairing_system`; see
    # `PairingsEngine.Tournaments.locked_fields/1`.
    # Ainalrami by default since 2026-08-25. Not a preference: JaVaFo
    # implements C.04.3 as it stood in 2022 and has not been updated for the
    # edition effective 1 February 2026, so leaving it as the default handed
    # arbiters superseded pairings. Existing tournaments keep whatever they
    # were created with - the engine is locked once a round is paired, and
    # changing one mid-event is exactly what C.04.2 forbids.
    field :pairing_engine, :string, default: "ainalrami"
    # Round-robin only: 1 = single cycle, 2 = double.
    field :rr_cycles, :integer, default: 1
    # Round-robin only: "match format" - round N and round N+1 are the SAME
    # pairing with colours reversed, played back-to-back as an immediate
    # two-game match (PairingsEngine.RoundRobin.match_schedule/2). This is a
    # different shape from `rr_cycles == 2` ("double round robin"), which
    # repeats a pairing a full cycle apart (season-style home/away) rather
    # than immediately. Currently mutually exclusive with `rr_cycles == 2`
    # (see the changeset validation below) - composing the two (an immediate
    # rematch *and* a season-style repeat) is a documented future extension,
    # not supported by this field yet. Locked in the UI once the tournament
    # has paired its first round, same as `pairing_system`/`rr_cycles`.
    field :rr_match_format, :boolean, default: false
    # Keizer only: nil means "automatic" (2 x player count), computed by
    # PairingsEngine.Keizer.
    field :keizer_top_value, :integer
    # Swiss only: "match format" - the sibling feature to `rr_match_format`
    # above, same immediate-two-game-rematch-with-reversed-colours concept,
    # but for Swiss the first leg is a real JaVaFo decision (who plays
    # whom), not a fixed schedule; the second leg is then an exact
    # colour-reversed mirror of the first, inserted alongside it by
    # PairingsEngine.Pairing.do_pair/2 in the same transaction, with no
    # second JaVaFo call. Like `acceleration`, this is only meaningful when
    # `pairing_system == "swiss"` - inert (never read) otherwise, same
    # tolerance as that field (no changeset error for setting it on a
    # non-swiss tournament; see PairingsEngine.Pairing.accelerations/3
    # for the precedent of gating via pattern match rather than a
    # validation). Locked in the UI once the tournament has paired its
    # first round, same as `pairing_system`/`rr_match_format`.
    field :swiss_match_format, :boolean, default: false

    # Native per-category Swiss pairing (SWAR-parity #24) - when true, each
    # category in `categories` (plus a catch-all "Uncategorized" pool for
    # blank/unlisted `player.category`) is paired completely independently:
    # its own JaVaFo run and its own pairing-allocated byes, merged into ONE
    # combined Round with board numbers running continuously across
    # categories in `categories` order (see PairingsEngine.Pairing's
    # per-category pairing logic). Requires `categories_enabled` and is not
    # yet supported together with Baku acceleration - both enforced below.
    # Only meaningful when `pairing_system == "swiss"` - inert (never read)
    # otherwise, same tolerance as `acceleration`/`swiss_match_format` (no
    # changeset error for setting it on a non-swiss tournament). Locked in
    # the UI once the tournament has paired its first round, same as
    # `swiss_match_format`.
    field :pair_by_category, :boolean, default: false

    # Club/federation pairing exclusions (SWAR parity #7-10) - arbiters
    # often must avoid pairing clubmates / same-federation players
    # together. "none" | "all" | "listed" - "listed" restricts the rule to
    # the comma-separated names in the matching `_list` field. Translated
    # into forbidden pairs at pairing time by PairingsEngine.Exclusions;
    # respected by Swiss (JaVaFo XXP lines) and Keizer, ignored by round
    # robin's fixed schedule by design - see docs/forbidden-pairings.md.
    field :club_exclusion, :string, default: "none"
    field :club_exclusion_list, :string, default: ""
    field :fed_exclusion, :string, default: "none"
    field :fed_exclusion_list, :string, default: ""

    # Extra points (SWAR parity #12, "XtPts") - see docs/extra-points.md.
    # `players.extra_points` (administrative bonus points) already exists,
    # but an explicit earlier product decision keeps standings from counting
    # it by default - this flag is the opt-in, per tournament, always
    # starting off. `extra_points_bands` is the Elo-band auto-assign rule:
    # a comma-separated "threshold:bonus" string, e.g. "1400:1, 1600:0.5"
    # (rating below 1400 gets 1.0, below 1600 gets 0.5) - see
    # `parse_extra_points_bands/1` and `band_extra_points/2` below for exact
    # matching semantics. Never applied automatically; only
    # `PairingsEngine.Tournaments.apply_extra_points_bands/1`, triggered
    # explicitly from Settings, writes it into players' `extra_points`.
    field :count_extra_points, :boolean, default: false
    field :extra_points_bands, :string, default: ""

    # Whether categories are actually in use. The Categories tab itself is
    # always in the nav (see CategoriesLive/settings_subnav) - this flag
    # instead gates the category-management UI on that page (off shows a
    # single on/off control and nothing else) and whether `pair_by_category`
    # below is even selectable. Toggled from a plain button on the
    # Categories page itself, not a settings-form checkbox - flipping it
    # off also forces `pair_by_category` off in the same write, since a
    # tournament can't pair by category with categories turned off (see
    # `validate_pair_by_category_requires_categories/1` below). Off by
    # default so a tournament that never touches categories stays inert.
    field :categories_enabled, :boolean, default: false

    # Soft-delete timestamp for the recycle bin (docs: recycle bin). nil =
    # live tournament; set = in the bin, auto-purged 3 months later. Managed
    # by PairingsEngine.Tournaments.soft_delete/restore/purge - deliberately
    # NOT cast by changeset/2 so ordinary saves can't touch it.
    field :deleted_at, :utc_datetime

    # Which restore point the live data currently corresponds to - HEAD, in
    # git terms. See `PairingsEngine.Snapshots` and the branching migration.
    # Stored rather than derived because after a restore the *most recent*
    # snapshot is precisely not where the data sits, which is the whole point
    # of branching. Managed only by `Snapshots.capture/4` and
    # `Snapshots.restore/3`; deliberately not cast by `changeset/2`, so an
    # ordinary settings save can't move it.
    field :head_snapshot_id, :integer

    # Archive timestamp. nil = live and editable; set = frozen read-only,
    # listed in its own section rather than the main tournament list.
    # Distinct from `deleted_at` in intent: the recycle bin is "on its way
    # out, auto-purged after 3 months", archiving is "finished with, keep it
    # forever, just stop letting anyone change it by accident".
    #
    # NOT a `status` value: `status` is derived (see
    # `Tournaments.derive_status/1`) and would be recomputed away. NOT cast by
    # changeset/2 either, same as `deleted_at`/`publish_to_openresults` - the
    # controlled setters `Tournaments.archive_tournament/1` and
    # `unarchive_tournament/1` are the only writers, so no ordinary settings
    # save can archive or (more importantly) silently UNarchive a tournament.
    #
    # Enforcement of the read-only part lives in
    # `Tournaments.ensure_writable/1`, called by every write path - not here,
    # since a changeset can't see the writes that don't go through it
    # (pairing, round deletion, byes).
    field :archived_at, :utc_datetime

    # Manual standings override (SWAR parity #23) - when true, the arbiter's
    # hand-set `players.manual_rank` order replaces the computed tiebreak
    # order. Every surface showing a rank must display an override banner:
    # a silent override is indistinguishable from a tiebreak bug.
    field :manual_ranking, :boolean, default: false

    # Set when a result changes after the hand-set order was seeded: the order
    # is still displayed, but every banner must report it as no longer matching
    # the current results. Managed by the Tournaments manual-ranking functions.
    field :manual_ranking_stale, :boolean, default: false

    # Per-tournament print logo (SWAR parity #14-16), stored as a DB blob so
    # backups/deploys carry it. Written only by Tournaments.set_logo/2 and
    # clear_logo/1 - NOT cast by changeset/2, same reasoning as deleted_at.
    field :logo_data, :binary
    field :logo_content_type, :string

    belongs_to :user, PairingsEngine.Accounts.User
    has_many :players, PairingsEngine.Tournaments.Player
    has_many :teams, PairingsEngine.Tournaments.Team
    has_many :rounds, PairingsEngine.Tournaments.Round

    timestamps(type: :utc_datetime)
  end

  def changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [
      :name,
      :type,
      :venue,
      :city,
      :federation,
      :organizer,
      :chief_arbiter,
      :deputy_arbiter,
      :time_control,
      :rounds_count,
      :points_win,
      :points_draw,
      :points_loss,
      :bye_value,
      :presence_value,
      :abs_value,
      :abs_jusque,
      :abs_nbfois,
      :absent_counts_as_vur,
      :presence_on_allocated_bye,
      :tiebreaks,
      :acceleration,
      :status,
      :standard,
      :rate_of_play,
      :organizer_club_number,
      :swar_guid,
      :round_dates,
      :categories,
      :category_rules,
      :event_code,
      :fide_tournament_id,
      :fide_homologated,
      :fide_id_ranges,
      :officials,
      :pairing_system,
      :pairing_engine,
      :rr_cycles,
      :rr_match_format,
      :keizer_top_value,
      :swiss_match_format,
      :pair_by_category,
      :club_exclusion,
      :club_exclusion_list,
      :fed_exclusion,
      :fed_exclusion_list,
      :count_extra_points,
      :extra_points_bands,
      :categories_enabled,
      :manual_ranking,
      :publish_mode,
      :publish_delay_minutes
    ])
    |> validate_required([:name, :type, :rounds_count])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:acceleration, @accelerations)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:standard, @standards)
    |> validate_inclusion(:pairing_system, @pairing_systems)
    |> validate_inclusion(:pairing_engine, @pairing_engines)
    |> validate_inclusion(:rr_cycles, @rr_cycles_values)
    |> validate_inclusion(:publish_mode, @publish_modes)
    |> validate_number(:publish_delay_minutes, greater_than_or_equal_to: 0)
    |> validate_inclusion(:club_exclusion, @exclusion_modes)
    |> validate_inclusion(:fed_exclusion, @exclusion_modes)
    |> validate_number(:rounds_count, greater_than: 0, less_than_or_equal_to: max_rounds())
    |> validate_keizer_top_value()
    |> validate_pairing_engine()
    |> validate_abs_scoring()
    |> validate_rr_match_format()
    |> validate_swiss_match_format()
    |> validate_pair_by_category()
    |> normalize_exclusion_list(:club_exclusion_list)
    |> normalize_exclusion_list(:fed_exclusion_list)
    |> normalize_extra_points_bands()
    |> normalize_fide_id_ranges()
    |> put_public_slug()
    |> pad_round_dates_to_rounds_count()
    |> derive_dates_from_round_dates()
  end

  @doc """
  Pads (with `""`) or truncates `dates` to exactly `count` entries - the
  same one-date-per-round shape `round_dates_complete?/1` requires. Shared
  by the changeset (`pad_round_dates_to_rounds_count/1`, below, so it fires
  on every save from every path) and `SettingsDatesLive`'s own live form
  state (which needs the padded shape mid-edit, before anything is saved).
  """
  def pad_round_dates(dates, count) do
    dates = List.wrap(dates)
    dates = Enum.take(dates, count)
    dates ++ List.duplicate("", max(count - length(dates), 0))
  end

  # Keeps `round_dates` in sync with `rounds_count` on every save, not just
  # ones that go through SettingsDatesLive's own form. `rounds_count` can
  # change from other paths too (e.g. RoundRobin auto-correcting it to match
  # the real Berger schedule total on freeze) - without this running
  # unconditionally here, `round_dates`'s length goes stale relative to the
  # new `rounds_count` and `round_dates_complete?/1` never clears even
  # though every date the arbiter actually needs is filled in. A blank
  # (`nil`) `rounds_count` is left alone; `validate_required/2` /
  # `validate_number/3` on `rounds_count` itself handle that case.
  defp pad_round_dates_to_rounds_count(changeset) do
    case get_field(changeset, :rounds_count) do
      count when is_integer(count) and count >= 0 ->
        dates = get_field(changeset, :round_dates) || []
        padded = pad_round_dates(dates, count)

        if padded == dates do
          changeset
        else
          put_change(changeset, :round_dates, padded)
        end

      _ ->
        changeset
    end
  end

  # start_date/end_date are always the earliest/latest non-blank entry in
  # round_dates - see the two fields' own doc comment above. Runs on every
  # save regardless of whether THIS particular update touches round_dates,
  # so a change made anywhere else (rounds_count shrinking the padded
  # list, an import) still leaves both in sync. Lexicographic sort is
  # correct here without parsing: every entry is ISO-8601 ("YYYY-MM-DD",
  # the native format of `<input type="date">`, and what every importer
  # normalizes to), which sorts identically as a string or as a date.
  defp derive_dates_from_round_dates(changeset) do
    dates =
      changeset
      |> get_field(:round_dates, [])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.sort()

    changeset
    |> put_change(:start_date, List.first(dates) || "")
    |> put_change(:end_date, List.last(dates) || "")
  end

  # Trims each comma-separated entry and drops blanks, storing back in the
  # same comma-separated shape ("Club A, Club B") - keeps the stored value
  # tidy regardless of how the arbiter typed it (extra spaces, trailing
  # commas, ...). Runs before validate_inclusion has any bearing on this
  # field (there is none - free text), so it's safe unconditionally.
  defp normalize_exclusion_list(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        normalized = value |> PairingsEngine.Exclusions.normalize_list() |> Enum.join(", ")
        put_change(changeset, field, normalized)
    end
  end

  # `keizer_top_value` is nullable (nil means "automatic") - only validate
  # it when an organiser has actually set it, so clearing the field back to
  # blank/automatic never fails validation.
  defp validate_keizer_top_value(changeset) do
    case get_field(changeset, :keizer_top_value) do
      nil -> changeset
      _ -> validate_number(changeset, :keizer_top_value, greater_than: 0)
    end
  end

  # `abs_jusque`/`abs_nbfois` (SWAR's "Pt ABSENT" caps - see
  # `PairingsEngine.Standings.bye_points/4`) are nullable the same way
  # `keizer_top_value` is: nil means "no cap", so only validate a value an
  # organiser (or SwarImport) actually set. Both are round/count numbers, so
  # negative doesn't mean anything - 0 is meaningful (see `swar_import.ex`'s
  # `tournament_attrs/1` doc on why 0 isn't the same as "uncapped").
  defp validate_abs_scoring(changeset) do
    changeset
    |> validate_number_if_present(:abs_jusque, greater_than_or_equal_to: 0)
    |> validate_number_if_present(:abs_nbfois, greater_than_or_equal_to: 0)
  end

  defp validate_number_if_present(changeset, field, opts) do
    case get_field(changeset, field) do
      nil -> changeset
      _ -> validate_number(changeset, field, opts)
    end
  end

  # Ainalrami on a FIDE-homologated tournament used to be REFUSED here, on
  # the grounds that OpenPairings' endorsement is FE1's "Internal engine:
  # NO - thru JaVaFo", and a rated round paired by anything else makes that
  # declaration untrue.
  #
  # It is now the arbiter's decision, taken deliberately (2026-08-21): the
  # engine agrees with bbpPairings across ~488 million pairings, and where
  # it differs from JaVaFo it is on Article 5.2.5's TPN parity, where it
  # follows the handbook text and JaVaFo carries pre-2026 behaviour (see
  # the sibling project's dispute-initial-colour.md). Refusing outright
  # asserted a quality judgement the measurements do not support.
  #
  # What has NOT changed is the paperwork, and that is the real risk: a
  # rated event paired this way was not paired by the engine OpenPairings'
  # endorsement names. So the UI warns prominently instead of blocking, and
  # docs/fide-endorsement.md now says so rather than claiming every rated
  # round is a JaVaFo round.
  defp validate_pairing_engine(changeset), do: changeset

  # (There used to be a `validate_ainalrami_excludes_baku/1` here. Ainalrami
  # did not read `XXA` at all, so an accelerated tournament would have been
  # paired on unaccelerated brackets - a wrong pairing that looks entirely
  # legal. It reads both `XXA` and `XXP` as of ainalrami `451c749`, verified
  # against bbpPairings on 1.79M rounds carrying those lines, so the
  # restriction is gone. `Pairing` still guards the general case at pairing
  # time by scanning the TRF it actually generated, so a future extension is
  # refused by default without anyone updating a list here.)

  # `rr_match_format` (immediate two-game rematch) and `rr_cycles == 2`
  # (season-style repeat a full cycle apart) are two different shapes of
  # "play everyone twice" that this codebase does not yet know how to
  # compose into a single schedule (see the field's doc comment above) - an
  # arbiter turning both on at once would silently get whichever one
  # `PairingsEngine.RoundRobin.do_pair/2` happens to check first, not the
  # combination they asked for, so this is rejected outright rather than
  # guessed at.
  defp validate_rr_match_format(changeset) do
    if get_field(changeset, :rr_match_format) == true and get_field(changeset, :rr_cycles) == 2 do
      add_error(
        changeset,
        :rr_match_format,
        "match format is not yet supported together with double round robin (rr_cycles=2)"
      )
    else
      changeset
    end
  end

  # `swiss_match_format` needs its second leg to fit inside `rounds_count`:
  # unlike round robin (whose match-format total round count is derived,
  # via `match_total_rounds/1`, from the schedule itself), Swiss's
  # `rounds_count` is a directly user-set total, so an odd total would
  # leave no room for the last match's second leg. Reject outright rather
  # than silently rounding/truncating.
  defp validate_swiss_match_format(changeset) do
    if get_field(changeset, :swiss_match_format) == true and
         rem(get_field(changeset, :rounds_count) || 0, 2) != 0 do
      add_error(
        changeset,
        :swiss_match_format,
        "match format requires an even number of rounds (each match is 2 rounds)"
      )
    else
      changeset
    end
  end

  # `pair_by_category` (SWAR-parity #24) needs category management actually
  # turned on (pairing per-category with no category data makes no sense),
  # and is deliberately not yet supported together with Baku acceleration or
  # `swiss_match_format` - rejected outright rather than guessed at, same
  # precedent as `validate_rr_match_format`/`validate_swiss_match_format`
  # above.
  defp validate_pair_by_category(changeset) do
    if get_field(changeset, :pair_by_category) == true do
      changeset
      |> validate_pair_by_category_requires_categories()
      |> validate_pair_by_category_excludes_baku()
      |> validate_pair_by_category_excludes_match_format()
    else
      changeset
    end
  end

  defp validate_pair_by_category_requires_categories(changeset) do
    if get_field(changeset, :categories_enabled) == true do
      changeset
    else
      add_error(
        changeset,
        :pair_by_category,
        "pairing by category requires categories to be enabled first"
      )
    end
  end

  defp validate_pair_by_category_excludes_baku(changeset) do
    if get_field(changeset, :acceleration) == "baku" do
      add_error(
        changeset,
        :pair_by_category,
        "pairing by category is not yet supported together with Baku acceleration"
      )
    else
      changeset
    end
  end

  defp validate_pair_by_category_excludes_match_format(changeset) do
    if get_field(changeset, :swiss_match_format) == true do
      add_error(
        changeset,
        :pair_by_category,
        "pairing by category is not yet supported together with match format"
      )
    else
      changeset
    end
  end

  # Re-parses and re-normalizes `extra_points_bands` on every write (like the
  # exclusion lists above), storing back the canonical
  # "threshold:bonus, threshold:bonus" shape sorted ascending by threshold -
  # tidy regardless of how the arbiter typed it, and a guarantee that
  # anything stored always parses cleanly for `apply_extra_points_bands/1`.
  # Blank input is valid (no bands configured). Adds a changeset error,
  # rather than silently dropping the bad entry, on malformed input.
  defp normalize_extra_points_bands(changeset) do
    case get_change(changeset, :extra_points_bands) do
      nil ->
        changeset

      value ->
        case parse_extra_points_bands(value) do
          {:ok, bands} ->
            canonical =
              bands
              |> Enum.sort_by(fn {threshold, _bonus} -> threshold end)
              |> Enum.map_join(", ", fn {threshold, bonus} ->
                "#{threshold}:#{format_bonus(bonus)}"
              end)

            put_change(changeset, :extra_points_bands, canonical)

          :error ->
            add_error(
              changeset,
              :extra_points_bands,
              "must be a comma-separated list of \"rating:bonus\" pairs, e.g. \"1400:1, 1600:0.5\""
            )
        end
    end
  end

  defp format_bonus(bonus) do
    if bonus == Float.round(bonus, 0), do: trunc(bonus), else: bonus
  end

  # Re-parses, validates and re-canonicalizes `fide_id_ranges` on every
  # write, same pattern as `normalize_extra_points_bands/1` above. Each
  # incoming entry (a map with either string or atom keys - a direct
  # `Tournaments.update_tournament/2` caller and a LiveView form submission
  # shape it slightly differently) needs a non-blank `fide_tournament_id`
  # and an integer-parseable `from_round <= to_round`; the canonical stored
  # shape always has string keys, integer round numbers, and is sorted by
  # `from_round`. Entries may never overlap each other (an unambiguous
  # per-round ID is the whole point of this field - see
  # `PairingsEngine.TrfExport.applicable_fide_id/2`, the consumer).
  defp normalize_fide_id_ranges(changeset) do
    case get_change(changeset, :fide_id_ranges) do
      nil ->
        changeset

      ranges when is_list(ranges) ->
        case parse_fide_id_ranges(ranges) do
          {:ok, parsed} ->
            case find_overlapping_fide_id_ranges(parsed) do
              nil ->
                canonical =
                  parsed
                  |> Enum.sort_by(& &1.from_round)
                  |> Enum.map(fn r ->
                    %{
                      "fide_tournament_id" => r.fide_tournament_id,
                      "from_round" => r.from_round,
                      "to_round" => r.to_round
                    }
                  end)

                put_change(changeset, :fide_id_ranges, canonical)

              {a, b} ->
                add_error(
                  changeset,
                  :fide_id_ranges,
                  "round ranges #{a.from_round}-#{a.to_round} and #{b.from_round}-#{b.to_round} overlap"
                )
            end

          :error ->
            add_error(
              changeset,
              :fide_id_ranges,
              "each range needs a FIDE tournament ID and from_round <= to_round (both >= 1)"
            )
        end

      _not_a_list ->
        add_error(changeset, :fide_id_ranges, "must be a list of ranges")
    end
  end

  defp parse_fide_id_ranges(ranges) do
    Enum.reduce_while(ranges, {:ok, []}, fn entry, {:ok, acc} ->
      with true <- is_map(entry),
           normalized <- Map.new(entry, fn {k, v} -> {to_string(k), v} end),
           fide_id <- normalized |> Map.get("fide_tournament_id") |> to_string() |> String.trim(),
           true <- fide_id != "",
           {:ok, from_r} <- parse_fide_id_range_round(Map.get(normalized, "from_round")),
           {:ok, to_r} <- parse_fide_id_range_round(Map.get(normalized, "to_round")),
           true <- from_r <= to_r do
        {:cont, {:ok, [%{fide_tournament_id: fide_id, from_round: from_r, to_round: to_r} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp parse_fide_id_range_round(v) when is_integer(v) and v >= 1, do: {:ok, v}

  defp parse_fide_id_range_round(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_fide_id_range_round(_), do: :error

  # First overlapping pair found (by round-span intersection), if any -
  # O(n^2) but `fide_id_ranges` is always a handful of entries per
  # tournament, never a performance concern.
  defp find_overlapping_fide_id_ranges(ranges) do
    indexed = Enum.with_index(ranges)

    Enum.find_value(indexed, fn {a, i} ->
      Enum.find_value(indexed, fn {b, j} ->
        if j > i and a.from_round <= b.to_round and b.from_round <= a.to_round do
          {a, b}
        end
      end)
    end)
  end

  @doc """
  Parses `extra_points_bands`'s stored/typed shape - a comma-separated list
  of `"threshold:bonus"` pairs, e.g. `"1400:1, 1600:0.5"` - into
  `{:ok, [{threshold :: non_neg_integer(), bonus :: float()}]}`, or `:error`
  for anything that doesn't match (wrong shape, negative numbers, ...).
  Blank/whitespace-only input parses to `{:ok, []}`.
  """
  @spec parse_extra_points_bands(String.t() | nil) ::
          {:ok, [{non_neg_integer(), float()}]} | :error
  def parse_extra_points_bands(nil), do: {:ok, []}

  def parse_extra_points_bands(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, []}

      trimmed ->
        trimmed
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> parse_band_tokens([])
    end
  end

  def parse_extra_points_bands(_), do: :error

  defp parse_band_tokens([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_band_tokens([token | rest], acc) do
    with [threshold_s, bonus_s] <- String.split(token, ":", parts: 2),
         {threshold, ""} <- Integer.parse(String.trim(threshold_s)),
         {bonus, ""} <- Float.parse(String.trim(bonus_s)),
         true <- threshold >= 0 and bonus >= 0.0 do
      parse_band_tokens(rest, [{threshold, bonus} | acc])
    else
      _ -> :error
    end
  end

  @doc """
  The extra-points bonus a player with `rating` earns from `bands` (as
  returned by `parse_extra_points_bands/1`), per the Elo-band auto-assign
  rule (SWAR parity #12):

    * A rated player (`rating > 0`) matches every band whose threshold is
      strictly greater than their rating (i.e. "rating below `threshold`").
      Among those, the **lowest-threshold** band wins - the most selective
      band, which is also the most generous one when bands are configured
      the expected way (lower threshold = bigger bonus for the
      lowest-rated players). A player at or above every threshold matches
      no band and gets `0.0`.
    * An unrated player (`rating == 0`) never matches a `rating < threshold`
      comparison (0 isn't below anything), so they only get a bonus when
      `bands` has an explicit `0:bonus` entry - an arbiter opt-in to give
      unrated players the same treatment as the lowest band, rather than an
      accidental side effect of the general rule.
  """
  @spec band_extra_points([{non_neg_integer(), float()}], non_neg_integer()) :: float()
  def band_extra_points(bands, rating)

  def band_extra_points(bands, 0) do
    case Enum.find(bands, fn {threshold, _bonus} -> threshold == 0 end) do
      {_threshold, bonus} -> bonus
      nil -> 0.0
    end
  end

  def band_extra_points(bands, rating) do
    bands
    |> Enum.filter(fn {threshold, _bonus} -> threshold > 0 and rating < threshold end)
    |> Enum.min_by(fn {threshold, _bonus} -> threshold end, fn -> nil end)
    |> case do
      nil -> 0.0
      {_threshold, bonus} -> bonus
    end
  end

  # Every tournament must always have a `public_slug` - this is the single
  # choke point all creation paths go through (the UI's "New tournament"
  # form, the SWAR importer, and the JSON tournament importer all call
  # `changeset/2`), so none of them need to generate one themselves. Only
  # fills it in when missing, so updating an existing tournament never
  # rotates its public link.
  defp put_public_slug(changeset) do
    if get_field(changeset, :public_slug) do
      changeset
    else
      put_change(changeset, :public_slug, generate_public_slug())
    end
  end

  @doc "A fresh random public-page slug (72 bits, url-safe). Also used by Tournaments.rotate_public_slug/1."
  def generate_public_slug, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

  @doc """
  The fields an arbiter must fill before a tournament can be paired. Until
  all of them are present, players can't be added and pairing can't start
  (see the guards in PlayersLive / PairingsLive), and their labels are shown
  bold in Settings.

  These are only the fields structurally needed to actually run rounds - the
  tournament's identity, its schedule and how standings are ordered. The
  FIDE-report metadata (chief arbiter, federation, rate of play, FIDE ID) is
  **not** here: it's needed to file a FIDE report, not to pair, so it's a
  soft nudge instead - see `recommended_setup_fields/0` /
  `missing_recommended_fields/1`, which never block pairing.

  No separate `:start_date` entry - it's derived from `:round_dates` now
  (see that field's own doc comment), so requiring `:round_dates` already
  covers it; a tournament can't satisfy one without the other.

  Kept as a flat list of field-name atoms for anything that just wants to
  know *which fields* matter (e.g. bolding a label) - for the actual
  present/absent logic (round dates need one entry per round), see
  `missing_setup_fields/1`.
  """
  def required_setup_fields do
    [
      :name,
      :rounds_count,
      :round_dates,
      :tiebreaks
    ]
  end

  @doc """
  Fields recommended for a complete FIDE report but **not** required to pair -
  the counterpart to `required_setup_fields/0`. Surfaced as a soft,
  non-blocking notice (see `missing_recommended_fields/1`) so an arbiter
  running a casual/club event can pair immediately, while one running a
  FIDE-rated event is still reminded to fill them in.
  """
  def recommended_setup_fields do
    [
      :chief_arbiter,
      :federation,
      :rate_of_play,
      :fide_tournament_id
    ]
  end

  @doc """
  The specific pairing-blocking requirements `tournament` doesn't satisfy
  yet, as a list of `{field, message}` pairs (plain-English `message`,
  suitable for showing directly to an arbiter) - empty once setup is
  complete. Each `field` is one of `required_setup_fields/0`'s atoms, so a
  caller that knows which Settings page hosts each field (Settings is split
  across several pages) can link straight to it - see PlayersLive/PairingsLive.
  """
  def missing_setup_fields(%__MODULE__{} = t) do
    checks = [
      {:name, "Tournament name", present?(t.name)},
      {:rounds_count, "Number of rounds", is_integer(t.rounds_count) and t.rounds_count >= 1},
      {:round_dates, "Round dates (one per round)", round_dates_complete?(t)},
      {:tiebreaks, "Tie-break selection", t.tiebreaks != []}
    ]

    for {field, message, ok?} <- checks, not ok?, do: {field, message}
  end

  @doc """
  The recommended-but-not-required fields `tournament` hasn't filled yet, in
  the same `{field, message}` shape as `missing_setup_fields/1`. Drives the
  soft "recommended for FIDE reporting" notice; never blocks pairing. The
  FIDE tournament ID only appears once the event is flagged FIDE-homologated
  (same rule as before - see `fide_id_ok?/1`).
  """
  def missing_recommended_fields(%__MODULE__{} = t) do
    checks = [
      {:chief_arbiter, "Chief arbiter", present?(t.chief_arbiter)},
      {:federation, "Federation", present?(t.federation)},
      {:rate_of_play, "Rate of play", present?(t.rate_of_play)},
      {:fide_tournament_id, "FIDE tournament ID (for a FIDE-homologated event)", fide_id_ok?(t)}
    ]

    for {field, message, ok?} <- checks, not ok?, do: {field, message}
  end

  @doc """
  Whether `tournament` has every `missing_setup_fields/1` (pairing-blocking)
  requirement met. Does not consider `recommended_setup_fields/0`.
  """
  def setup_complete?(%__MODULE__{} = t), do: missing_setup_fields(t) == []

  # Round dates are considered "filled in" the same way SettingsDatesLive
  # defines it: one non-blank date per round - the stored list is padded/
  # truncated to `rounds_count` by `pad_round_dates_to_rounds_count/1` on
  # every save (any path, not just the Dates page), so a complete
  # tournament's `round_dates` is exactly `rounds_count` long with no blanks.
  defp round_dates_complete?(t) do
    count = t.rounds_count
    dates = t.round_dates || []

    is_integer(count) and count >= 1 and
      length(dates) == count and
      Enum.all?(dates, &present?/1)
  end

  # The FIDE tournament ID is only mandatory once the tournament is flagged
  # as FIDE-homologated (`fide_homologated`, set on the FIDE settings page).
  # Read via `Map.get/3` with a `false` default rather than `t.fide_homologated`
  # directly - this was written while `fide_homologated` was being added to
  # the schema by a separate change; `Map.get/3` degrades gracefully (never
  # required) if that field is ever absent, and behaves like ordinary field
  # access now that it's present.
  #
  # A tournament that splits its FIDE ID entirely via `fide_id_ranges` (no
  # tournament-wide fallback `fide_tournament_id` set) still satisfies this
  # check as long as those ranges cover every round 1..rounds_count - see
  # `fide_id_ranges_cover_all_rounds?/1`.
  defp fide_id_ok?(t) do
    if Map.get(t, :fide_homologated, false) == true do
      fide_id_present?(t)
    else
      true
    end
  end

  @doc """
  Whether `tournament` has a FIDE tournament ID configured at all - either
  the tournament-wide fallback `fide_tournament_id`, or `fide_id_ranges`
  entries covering every round. Unconditional, unlike `fide_id_ok?/1` (the
  soft Settings-page nudge, only checked once `fide_homologated` is set):
  every FIDE report prints the tournament's own numeric ID (IT3 B2)
  regardless of whether the arbiter has ticked "FIDE-homologated", and a
  report FIDE can't identify a tournament from is a wasted submission - see
  `PairingsEngineWeb.NormsLive.report_blockers/1` and its Tools-page
  counterpart, which both gate report downloads on this.
  """
  def fide_id_present?(%__MODULE__{} = t) do
    present?(t.fide_tournament_id) or fide_id_ranges_cover_all_rounds?(t)
  end

  # Whether every round 1..rounds_count is covered by some `fide_id_ranges`
  # entry (see that field's schema doc for the shape). Tolerant of the field
  # being absent/nil (same graceful-degradation reasoning as `fide_id_ok?/1`
  # above) via `Map.get/3`.
  defp fide_id_ranges_cover_all_rounds?(t) do
    count = t.rounds_count
    ranges = Map.get(t, :fide_id_ranges, []) || []

    if is_integer(count) and count >= 1 do
      covered =
        Enum.reduce(ranges, MapSet.new(), fn range, acc ->
          from_r = Map.get(range, "from_round")
          to_r = Map.get(range, "to_round")

          if is_integer(from_r) and is_integer(to_r) do
            MapSet.union(acc, MapSet.new(from_r..to_r))
          else
            acc
          end
        end)

      Enum.all?(1..count, &MapSet.member?(covered, &1))
    else
      false
    end
  end

  defp present?(nil), do: false
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: true

  def types, do: @types

  def type_label("swiss"), do: "Swiss (individual)"
  def type_label("roundrobin"), do: "Round robin (individual)"
  def type_label("team-swiss"), do: "Swiss (teams)"
  def type_label("team-roundrobin"), do: "Round robin (teams)"
  def type_label(other), do: other

  def pairing_systems, do: @pairing_systems
  def pairing_engines, do: @pairing_engines
  def rr_cycles_values, do: @rr_cycles_values
  def exclusion_modes, do: @exclusion_modes

  def exclusion_mode_label("none"), do: "None"
  def exclusion_mode_label("all"), do: "All shared clubs/federations"
  def exclusion_mode_label("listed"), do: "Only listed"
  def exclusion_mode_label(other), do: other

  def pairing_engine_label("javafo"), do: "JaVaFo (2022 rules)"
  def pairing_engine_label("ainalrami"), do: "Ainalrami"
  def pairing_engine_label(other), do: other

  # Names the SYSTEM, not the engine - which one runs it is a separate
  # setting, and naming JaVaFo here was wrong the day a second engine landed.
  def pairing_system_label("swiss"), do: "Swiss - FIDE Dutch"
  def pairing_system_label("round_robin"), do: "Round robin (Berger)"
  def pairing_system_label("keizer"), do: "Keizer"
  def pairing_system_label(other), do: other

  def rr_cycles_label(1), do: "Single"
  def rr_cycles_label(2), do: "Double"
  def rr_cycles_label(other), do: to_string(other)

  @doc """
  This tournament's scoring, in the shape `Ainalrami.Pairing` takes.

  Score decides which bracket a player is paired in, so an engine reading
  different values than the standings do is not reporting different totals -
  it is pairing a different tournament. Until this existed, a tournament set
  to 3-1-0 was scored by us at 3-1-0 and paired by the engine at 1/half/0.

  One limitation, stated rather than hidden, and it is really one limitation
  wearing two hats: TRF has a single letter, `Z`, for three different things
  this app scores differently - a requested zero-point bye
  (`presence_value || points_loss`), an absence (`abs_value`, capped by
  `abs_jusque` and `abs_nbfois`), and a round with no row at all
  (`points_loss`). A per-result map cannot express that, so `zero_point_bye`
  is set to the absence value, which is the one people actually configure,
  and a capped absence or a 3-2-1 requested bye is passed at a value the
  crosstable would not agree with.

  It degrades gracefully rather than silently: the score the engine BRACKETS
  by comes from the file's own score column (`Pairing.player_points/2`),
  which is exact in all three cases. This map is only consulted where a
  per-round value is needed - reconstructing what a player had before round
  N, and deciding float direction - so the error is bounded to those. It is
  a gap, not a design.
  """
  def engine_point_system(%__MODULE__{} = t) do
    loss = t.points_loss || 0.0

    %{
      win: t.points_win || 1.0,
      draw: t.points_draw || 0.5,
      loss: loss,
      # SWAR 3-2-1's `SW321_PreBye` pays presence points ON TOP of the bye
      # value, and `Standings.bye_points/4` has always added them - so the
      # engine was told a smaller number than the crosstable used for the
      # same bye. Nil for every tournament that is not a 3-2-1 import.
      pairing_allocated_bye: (t.bye_value || 1.0) + allocated_bye_bonus(t),
      # A forfeit loss pays an ordinary loss here; the TRF code is what marks
      # it unplayed, not the value.
      forfeit_loss: loss,
      # TRF `Z` - a round the player sat out. See the cap note above.
      zero_point_bye: t.abs_value || loss
    }
  end

  defp allocated_bye_bonus(%__MODULE__{presence_on_allocated_bye: true, presence_value: v})
       when is_number(v),
       do: v

  defp allocated_bye_bonus(_t), do: 0.0

  @doc """
  The name of the program that actually pairs this tournament, for anywhere
  a page or a FIDE report has to say WHICH one produced the round.

  Lives here rather than in each page because it had already drifted once:
  the Pairings page hardcoded "JaVaFo" for every Swiss tournament, so a
  tournament opted into Ainalrami still had a button reading "Pair round 5
  (JaVaFo)" over pairings JaVaFo never produced. Round robin and Keizer
  compute their own schedules and consult no Swiss engine at all.
  """
  def engine_name(%{pairing_system: "round_robin"}), do: "Berger"
  def engine_name(%{pairing_system: "keizer"}), do: "Keizer"
  def engine_name(%{pairing_engine: "ainalrami"}), do: "Ainalrami"
  def engine_name(_swiss), do: "JaVaFo"

  @max_rounds 30

  @doc """
  The largest `rounds_count` this app accepts.

  Exposed because it is a bound on the UI's round picker, and a round robin
  derives its own length from the field size with no knowledge of it - so
  `RoundRobin.ensure_correct_rounds_count/2` needs to name the number in the
  message it returns when a schedule is longer than this. Hardcoding it
  there would let the message and the validation drift.
  """
  def max_rounds, do: @max_rounds

  def publish_modes, do: @publish_modes

  def publish_mode_label("immediate"), do: "Immediately - public the instant it's paired"
  def publish_mode_label("manual"), do: "Manually - I'll publish each round myself"
  def publish_mode_label("timed"), do: "After a delay - a fixed number of minutes"
  def publish_mode_label("scheduled"), do: "On the round's own date (Dates page)"
  def publish_mode_label(other), do: other
end
