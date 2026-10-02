defmodule PairingsEngine.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(swiss roundrobin team-swiss team-roundrobin)
  @accelerations ~w(none baku)
  # What `players.extra_points` are - see `extra_points_mode` below and
  # docs/extra-points.md.
  @extra_points_modes ~w(handicap acceleration)
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
  # The Olympiad plays four boards and the largest national leagues ten; 20
  # is a sanity bound on a form field, not a regulation.
  @max_team_boards 20
  @team_types ~w(team-swiss team-roundrobin)
  # How far the automation moves each round's public level for the arbiter
  # (Settings -> OpenResults, "Automatically:") - since 2026-09-28 one
  # cumulative ladder, the same four levels as the per-round control on the
  # Pairings page:
  #
  #   "manual"    - by hand: nothing reaches the public until the arbiter
  #                 chooses a level on the Pairings page
  #   "pairings"  - a round's pairings go public once it is paired, after
  #                 `publish_delay_minutes`
  #   "results"   - and its results go public live, as they are entered
  #   "standings" - and the standings after it, once the round is finished
  #
  # The automation only ever moves a round UP; the arbiter can always take a
  # round back down by hand, and that sticks (`Round.publish_cap`). See
  # `PairingsEngine.Tournaments`' "Automatic publishing" section.
  #
  # **"manual" is the default.** A round that reaches the public page the
  # instant the engine hands it back has not been looked at by anyone: the
  # first person to see a pairing should be the person responsible for it.
  #
  # The values before 2026-09-28 were "immediate", "manual", "timed" and
  # "scheduled"; `legacy_publish_mode/2` is the conversion the migration and
  # the import of an older backup both apply.
  @publish_modes ~w(manual pairings results standings)
  @legacy_publish_modes ~w(immediate timed scheduled)
  # Club/federation pairing-exclusion rules (SWAR parity #7-10) - see
  # PairingsEngine.Exclusions and docs/forbidden-pairings.md.
  @exclusion_modes ~w(none all listed)
  # Where a soft pairing wish sits on Ainalrami's criteria ladder - see
  # PairingsEngine.Pairing.soft_pairs/5 and docs/forbidden-pairings.md.
  @soft_positions ~w(strong weak)
  @initial_colours ~w(lot white black)

  # `swar_guid` is minted by another program and imported verbatim from a
  # `.swar` file, and it is then used as a filename:
  # `SwarPublish.filename/1` puts it straight into a `Content-Disposition`
  # header. A control character in it makes Plug reject that header, which is
  # a 500 on this tournament's SWAR download for good rather than once, and a
  # quote breaks out of the quoted `filename=` parameter.
  #
  # Deliberately a refusal of the characters that break something, not an
  # allow-list of what a guid may look like: the value's shape is SWAR's to
  # decide, and inventing one here would refuse whole imports over a
  # character nothing in this app minds.
  #
  # `\A`/`\z`, not `^`/`$`: the latter pair matches before a FINAL newline, so
  # a guid ending in one would have passed a check written to exclude exactly
  # that character.
  @safe_swar_guid ~r|\A[^\x00-\x1f\x7f"\\/]*\z|

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
    # existed. Only PairingsEngine.Federations.BEL.SwarImport writes a non-nil value.
    field :presence_value, :float
    # SWAR `AbsValue` - the points paid for a player simply marked ABSENT
    # for a round (our `byes`-table `type: "absent"` row, from SWAR's
    # per-player `Absent` status / the per-round `TABLE_ABSENT` special
    # value). It's a plain UI checkbox ("½ point" for absence) in SWAR's
    # own source, raw 0 (unchecked) or 1 (checked) - NOT the "0 or 5" an
    # earlier version of this comment (and the mapping in
    # `PairingsEngine.Federations.BEL.SwarImport`) assumed; see that module's
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
    # PairingsEngine.Federations.BEL.SwarImport writes a non-nil value. See `abs_jusque`/
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
    # PairingsEngine.Federations.BEL.SwarImport writes non-nil values.
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
    # "Rounds before a late entrant joins count as absences": each round
    # before a player's `start_round` is scored as a plain absence - at
    # `abs_value`, under the same `abs_jusque`/`abs_nbfois` caps, using up
    # the same allowance - exactly as if they had been registered and marked
    # absent for it. What SWAR does: a player added after rounds were paired
    # gets an absent record for every one of them (`JoueurInit`, Joueur.cpp).
    #
    # ON by default, and it only has an effect where absences pay points at
    # all (`abs_value` > 0, Swiss, individual): a FIDE event keeps scoring a
    # round before joining as nothing, which is how C.07 16.1.2 reads. The
    # rounds are derived, never written as `byes` rows, so changing this or
    # a player's `start_round` rescores at once. See `PairingsEngine.LateEntry`.
    field :late_entry_absences, :boolean, default: true
    # SWAR `SW321_PreBye` (manual §5.16, "Add presence points for bye
    # games") - when true, a pairing-allocated bye pays `presence_value` ON
    # TOP of `bye_value` (SWAR pays SW321_Bye + SW321_Pre for a WIN_BYE
    # round when this club option is on). Kept as a flag rather than folded
    # into `bye_value` at import so `bye_value` keeps meaning exactly the
    # club's configured SW321_Bye. Consulted only by
    # `PairingsEngine.Standings.bye_points/2`'s "pairing-allocated" branch;
    # false (the default for every tournament that isn't a SWAR 3-2-1
    # import) leaves scoring byte-identical to before this field existed.
    # Only PairingsEngine.Federations.BEL.SwarImport sets it true (type == 3 files only).
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
    # When PairingsEngine.Federations.BEL.SwarUpload last successfully PUT
    # this tournament's generated results page to the federation's intake
    # (step 1), and when the federation's own index step (step 2) last
    # actually confirmed it - two timestamps rather than one, so a PUT that
    # lands followed by a GET that fails is visible as "staged, not yet
    # indexed" rather than looking untouched. See that module's moduledoc
    # and the migration that added these. Neither is cast by changeset/2:
    # both are written only by SwarUpload itself, same as openresults_key
    # below.
    field :swar_uploaded_at, :utc_datetime
    field :swar_published_at, :utc_datetime
    # ISO dates, index = round-1
    field :round_dates, {:array, :string}, default: []
    # tournament-defined category names (SWAR CATEGORIES)
    field :categories, {:array, :string}, default: []

    # Set only by a two-axis SWAR import (Categorie type 3/4 - age-then-
    # rating or rating-then-age); nil for a plain single-axis or
    # OpenPairings-authored category list. Lets `SwarExport` write the same
    # two `[CATEGORIES]` columns back out. See
    # `PairingsEngine.Federations.BEL.SwarImport`'s category section and
    # `docs/swar-import.md`.
    field :swar_category_type, :integer
    # The subset (and order) of `categories` that came from the SWAR file's
    # `value2` column; `categories -- swar_category_axis2`, in order, is
    # axis 1. Empty for anything that isn't a two-axis SWAR import.
    field :swar_category_axis2, {:array, :string}, default: []

    # Optional CONDITION SET behind a category name, keyed by that name -
    # e.g. `%{"1600-1799" => %{"rating_from" => 1600, "rating_below" =>
    # 1800}, "45+ women" => %{"age_from" => 45, "women" => true}}`. Each
    # entry is a map carrying any combination of five recognised keys, all
    # optional:
    #
    #   "rating_from"  - integer, player's Elo (`Player.rating/1`) >= this
    #   "rating_below" - integer, player's Elo < this
    #   "age_from"     - integer, player's FIDE age (see below) >= this
    #   "age_below"    - integer, player's FIDE age < this
    #   "women"        - `true`, player's `sex` field == "w"
    #
    # Only the keys actually set are stored - an empty map (or no entry at
    # all) means the same thing a missing entry always has: this category
    # stays a plain name the arbiter assigns to `player.category`/
    # `player.categories` by hand on the Players page. A category WITH at
    # least one key set is rule-owned and can instead be filled in for
    # every player at once via `Tournaments.auto_assign_categories/1` - a
    # player qualifies when EVERY condition the category sets is true for
    # them, so two rule-owned categories are free to overlap (U1800 and
    # U1600 both matching a 1500-rated player is the point, not a
    # collapse-away case the way SWAR's non-overlapping bands would
    # force). See `PairingsEngine.CategoryRules` for the full condition
    # language, the exact matching semantics (including the unrated-player
    # and missing-birth-data readings), and `rule_owned?/1`, the one test
    # for "does this category have a rule".
    #
    # Age is the player's age on 1 January of the tournament's year (FIDE's
    # convention - see `CategoryRules.tournament_year/1` for which year
    # that is and `CategoryRules.age_at_year_start/2` for the exact
    # arithmetic, birth-date-aware when the player has one). This differs
    # by one from the legacy age arithmetic a tournament created before
    # this shape existed used (`year - birth_year`, no adjustment) - a
    # tournament migrated from the old `"kind"`/`"value"` shape
    # (`CategoryRules.migrate_legacy_rules/2`, run once by
    # `MigrateLegacyCategoryRules` for every tournament that predates this
    # field, and again by `PairingsEngine.TournamentImport` for an older
    # backup file) has already had that difference translated away, so its
    # auto-assign results are unchanged by the shape switch.
    field :category_rules, :map, default: %{}

    # Optional PRIZE COUNT per category, keyed by name - e.g. `%{"U1800" =>
    # 3}` for "3 prizes in this category". Deliberately a SEPARATE field
    # from `category_rules` rather than a sixth key on its entry: whether a
    # category is rule-owned is decided entirely by `category_rules`
    # (`CategoryRules.rule_owned?/1`), and a prize count has nothing to do
    # with that question - giving a hand-assigned category a prize count
    # must not turn it into one `auto_assign_categories/1` would touch, and
    # a rule-owned category with no prizes configured (most of them, most
    # of the time) must not need an empty placeholder here just to avoid
    # looking rule-owned by this field's presence.
    #
    # A name with no entry (or an entry of `0`) means "no prize count set" -
    # `PairingsEngine.Categories.prize_place?/3` treats both the same way,
    # so nothing here is highlighted on the standings page until an arbiter
    # actually sets a count. Purely informational: nothing allocates an
    # actual prize or enforces "one prize per player" across categories a
    # player is in more than one of - see docs/design-player-tags.md for
    # that as a documented follow-up, not something this field does.
    field :category_prizes, :map, default: %{}

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

    # The entry form's own settings, added 2026-09-30. Like the flag above
    # they are enforced only on the results site, by riding along in the
    # snapshot (`tournament.registration`), and none of them opens the form -
    # that is still `registration_open`. Set together through
    # `registration_changeset/2` and `Tournaments.set_registration_settings/2`,
    # never by `changeset/2`.
    #
    # The window, in UTC. Either end may be missing; the results site judges
    # it by its own clock, so it opens and shuts on time while this machine
    # is off.
    field :registration_opens_at, :utc_datetime
    field :registration_closes_at, :utc_datetime
    # The size of the field: the form stops taking entries once the players
    # plus the entries waiting here for a decision reach it. nil = no cap.
    field :registration_max_players, :integer
    # Whether the form page may list who has entered. Off by default: it puts
    # names on a page the arbiter did not otherwise choose.
    field :registration_list_public, :boolean, default: false

    # Whether this tournament is published to OpenResults at all. Toggled by
    # Tournaments.set_publish_to_openresults/2, and NOT cast by changeset/2
    # for the same reason as the three fields above: an ordinary settings
    # save must not be able to start sending an event's player names,
    # ratings and clubs to a remote server by accident.
    #
    # Whether the tournament appears in the results site's index, as opposed
    # to being reachable only by its address.
    #
    # Default FALSE, changed on 2026-08-29 within hours of shipping as true.
    # True was chosen to preserve what publishing had always meant, and that
    # produced a front page nobody chose: sixteen tournaments listed at once
    # because a migration had switched publishing on, not because sixteen
    # arbiters decided to advertise their events. Publishing gives a
    # tournament an address; putting it on the front page is a second,
    # deliberate act.
    #
    # Not a security control either way, and the settings page says so in as
    # many words. The address is an unguessable token, but an unlisted
    # tournament is still world-readable to anyone holding one. This hides an
    # event from somebody browsing the site, not from somebody sent the link.
    field :public_listed, :boolean, default: false

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

    # How the results site's hall display runs: which views it cycles, for
    # how long, and the arbiter's announcement. Nil means every default; see
    # `PairingsEngine.HallDisplay`. Preferences for the hall screen only -
    # never a gate on what the public may see, which is `public_display`'s
    # and the round levels' job.
    field :public_hall, :map

    # Which of this tournament's own tie-breaks are kept off the public page.
    # Not a key in `public_display` above: that map is resolved to a boolean
    # per key when published, and these codes exist only because this arbiter
    # picked them. Empty means all shown, the same absent-means-shown rule.
    #
    # Hiding a column does NOT stop the tie-break deciding the order, so a
    # snapshot whose ranking used a hidden code carries a flag saying so -
    # see `PairingsEngine.Snapshot`. A page that showed some of the working
    # and none of the rest would read as broken rather than as withheld.
    field :public_hidden_tiebreaks, {:array, :string}, default: []

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

    # The three facts about a slug the results site created, all nil for a
    # slug it did not. Only consulted in public mode (a desktop copy with no
    # operator token, see `PairingsEngine.Publishing.public_mode?/0`). There
    # the SERVER picks the slug (`POST /api/tournaments`), so the one every
    # tournament is born with is a placeholder.
    #
    #   public_slug_minted_at     when the site created `public_slug`
    #   public_slug_server        the address it was created on - a slug
    #                             belongs to that server, and on any other
    #                             one this tournament is unminted
    #   public_slug_published_at  when the first publish under it succeeded
    #
    # The link waits for the third, not the first: the server answers a
    # minted slug with no snapshot exactly like an unknown one, so a link or
    # QR code shown in between would be dead. `Publishing.public_slug_state/1`
    # is the one reading of the three, and `PairingsEngineWeb.PublicLink`
    # offers no address until it says so - which makes that true on every
    # surface at once rather than at each call site.
    #
    # Written only by `Publishing.Installation.mint/1` (all three: set, set,
    # cleared), `Publishing`'s first successful publish (the third), and
    # cleared together by `Tournaments.rotate_public_slug/1`, the takedown and
    # `Publishing.adopt_claim/1` - after each of those the slug they described
    # is gone or is not this installation's creation. Not cast, for the same
    # reason as the key above, and not exported: an imported copy gets a fresh
    # slug of its own, and these describe the slug, not the tournament.
    field :public_slug_minted_at, :utc_datetime
    field :public_slug_server, :string
    field :public_slug_published_at, :utc_datetime

    # How far the automation publishes each round for the arbiter - see
    # `@publish_modes`'s own comment above - and how long after pairing the
    # pairings step waits. Cast by the ordinary changeset, but written by the
    # Settings page through `Tournaments.set_auto_publish/3`, which keeps what
    # the automation already made public when it is turned down.
    #
    # `20260813150000_add_pairing_publish_delay.exs` sets the COLUMN default to
    # "immediate", a value that no longer exists. Unreachable: Ecto sends
    # struct defaults on insert, so this line wins for every tournament
    # created through the app, and for restored ones too (`TournamentImport`
    # inserts through a changeset). Nothing writes a tournament row in raw
    # SQL, and changing a column default in SQLite means rebuilding the table.
    field :publish_mode, :string, default: "manual"
    field :publish_delay_minutes, :integer, default: 0

    # Public STANDINGS go up to round S - the maintainer's 2026-09-11
    # publish-model rewrite (see `PairingsEngine.Snapshot`'s moduledoc and
    # `PairingsEngine.Tournaments`' "Publishing pairings and standings"
    # section for the full rules). Cumulative, like the pairings prefix it
    # travels beside:
    #
    #   * `nil` - nothing public at all, not even the entry list. The one
    #     surface where round 0 and "unset" are different states.
    #   * `0` - "standings after round 0", i.e. the entry list in start
    #     order, before round 1 has any result. What OpenResults calls the
    #     "Starting rank". Replaces `publish_starting_rank: true` with no
    #     round published - see the migration that dropped that field.
    #   * `N > 0` - standings after round N are public.
    #
    # Written only by `Tournaments.publish_standings_through/2` and
    # `unpublish_standings_through/2`, and NOT cast by the ordinary
    # changeset - same reasoning as `publish_to_openresults`/
    # `registration_open` above: publishing standings is a deliberate act
    # with its own cascade (unpublishing standings after round N also hides
    # any pairings that would leak them), not an everyday settings save.
    #
    # The value STORED here is not what a snapshot publishes through - see
    # `Tournaments.effective_standings_through/1`, which folds in "a
    # published round's own sheet already reveals the standings before it"
    # and the automation's standings step, and caps the result at the
    # complete-and-published prefix, so nothing here can ever publish
    # through an incomplete round on its own.
    #
    # Default `nil` since 2026-09-28: before round 1, spectators see nothing
    # until the arbiter switches on "Before round 1, spectators see the
    # starting ranking" (Settings -> OpenResults,
    # `Tournaments.set_initial_standings_public/2`). It was `0` - the entry
    # list public from creation - and every tournament created then keeps
    # the value it has, so nothing public today goes dark. Like the other
    # uncast fields above, the default reaches every insert through the
    # struct itself, not through `cast/3`.
    field :standings_through, :integer, default: nil

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
    # implements C.04.3 as it stood until 31 January 2026 and has not been
    # updated for the edition effective 1 February 2026, so leaving it as
    # the default handed arbiters superseded pairings. Existing tournaments
    # keep whatever they were created with - the engine is locked once a
    # round is paired, and changing one mid-event is exactly what C.04.2
    # forbids.
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

    # Team tournaments only (`type` "team-roundrobin"/"team-swiss") - inert
    # for every individual tournament, same tolerance as `acceleration`.
    # See docs/team-tournaments.md.
    #
    # `team_boards` is how many boards one match is played on. Locked once
    # round 1 is paired (`Tournaments.locked_fields/1`): a match's boards are
    # numbered from it, and `PairingsEngine.TeamStandings` reads it back to
    # tell which side of a board belongs to which team.
    field :team_boards, :integer, default: 4
    # C.07 Art. 11.1.1: match points for a team win, draw and loss. 2/1/0 is
    # FIDE's own team scoring and the default; a league scoring 3/1/0 changes
    # them. Game points (Art. 11.1.2) need no setting - they are the board
    # results, scored with `points_win`/`points_draw`/`points_loss`.
    field :team_match_points_win, :float, default: 2.0
    field :team_match_points_draw, :float, default: 1.0
    field :team_match_points_loss, :float, default: 0.0

    # Swiss (teams) only: how its rounds are paired. "teams" - team against
    # team under C.04.6 (`PairingsEngine.TeamSwiss`); "players" - player by
    # player on the individual Swiss path, which is how every team Swiss was
    # paired before C.04.6 was wired in and how those events carry on (no
    # conversion mid-event); nil - nothing paired yet, so the first pairing
    # will be by teams and will store "teams". Set by the pairing code and by
    # import, never cast. See docs/team-tournaments.md.
    field :team_pairing_mode, :string

    # The initial colour (C.04.3 Art. 5.1, C.04.6 Art. 4.1: "determined by
    # drawing of lots before the pairing of the first round"). "lot" draws it
    # at the first Swiss pairing and stores the result in
    # `initial_colour_drawn`; "white"/"black" is the arbiter's own choice.
    # Locked once round 1 is paired (`Tournaments.locked_fields/1`).
    # `initial_colour_drawn` is written only by
    # `Tournaments.ensure_initial_colour/2`, never cast. A tournament that
    # paired round 1 before this setting existed has neither a choice nor a
    # draw on record, and its engine keeps reading the colour off the boards
    # as before. See `effective_initial_colour/1`.
    field :initial_colour, :string, default: "lot"
    field :initial_colour_drawn, :string

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

    # Soft pairing rules - wishes the Ainalrami engine weighs against the
    # pairing criteria, not rules it must satisfy (docs/forbidden-pairings.md,
    # "Soft rules"). Clubmates are asked to be kept apart for rounds
    # 1..`soft_club_rounds` (0 = never; the usual request is "not in the
    # first two rounds"), and `soft_position` says how hard every soft wish
    # is tried: "strong" puts it above the quality criteria (the engine would
    # rather float a player than seat the pair), "weak" makes it a tie-break
    # and nothing more. Explicit soft pairs live on `forbidden_pairings.soft`.
    # JaVaFo and Keizer have no such option and ignore all three.
    field :soft_club_rounds, :integer, default: 0
    field :soft_position, :string, default: "strong"

    # Extra points (SWAR parity #12, "XtPts") - see docs/extra-points.md.
    #
    # `extra_points_mode` says what `players.extra_points` ARE:
    #
    #   * "handicap" - a head start. `count_extra_points` is the one switch:
    #     on, the points count in the standings AND in the score the pairing
    #     engine groups by (so the score groups are the standings' own); off,
    #     they do nothing at all. The Elo bands pay players BELOW a rating.
    #   * "acceleration" - SWAR's XtraPoints. The points always go to the
    #     pairing engine as virtual points (`XXA`), round by round, and
    #     `count_extra_points` only decides whether they also stay in the
    #     standings ("Keep acceleration points in the final standings" - on
    #     is SWAR's behaviour, off removes them like Baku's). The Elo bands
    #     pay players AT OR ABOVE a rating, as SWAR's do.
    #
    # `count_extra_points` keeps its one meaning in both modes - "the
    # standings rank on points plus extra points" - so every surface that
    # shows a score reads it and nothing else. Which of the two feeds the
    # pairing is `extra_points_pairing?/1`. Baku acceleration and extra
    # points in the pairing are refused together
    # (`validate_extra_points_excludes_baku/1`).
    #
    # `extra_points_bands` is the Elo-band auto-assign rule: a
    # comma-separated "threshold:bonus" string, e.g. "1400:1, 1600:0.5" - see
    # `parse_extra_points_bands/1` and `band_extra_points/3` below for exact
    # matching semantics per mode. Never applied automatically; only
    # `PairingsEngine.Tournaments.apply_extra_points_bands/1`, triggered
    # explicitly from Settings, writes it into players' `extra_points`.
    field :extra_points_mode, :string, default: "handicap"

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

    # Each category ranked on its own - SWAR's "separate categories"
    # (`CatSepares`). When on (and categories are enabled), `Standings`
    # ranks every player within their pairing category
    # (`PairingsEngine.Categories.pairing_category/2`): places start from 1
    # in each category, and a tie is broken among the tied players of the
    # same category only, so direct encounter looks at the games inside the
    # category. The table lists the categories one after another, in the
    # tournament's own category order, uncategorised players last. Off by
    # default: one ranking for the whole field, with each category's places
    # read off it. See `PairingsEngine.Standings.ranked_separately?/1` and
    # docs/swar-import.md.
    field :categories_ranked_separately, :boolean, default: false

    # The SWAR file's own settings that OpenPairings has no counterpart for,
    # exactly as the imported `.swar` had them - the rating SWAR pairs by,
    # the first table number, the rating-report round ranges, its XtraPoints
    # band table, its exact tournament type and tie-break list. Written by
    # `SwarImport` only (never cast from a form), read by `SwarExport`, so a
    # tournament that came from SWAR goes back with them - and carried by
    # JSON backups and restore points (`TournamentExport`), so a restored
    # copy does too. String keys;
    # see `SwarImport.swar_settings/1` for the list. Empty for anything that
    # did not come from a `.swar` file.
    field :swar_settings, :map, default: %{}

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

    # ---- Hand-off lock (moving a tournament between this copy and another) ----
    #
    # A tournament is live in EXACTLY ONE place at a time. There is no merge
    # for two copies that both took writes - one machine recorded 1-0 on
    # board 4 and the other a draw, or both paired round 6 differently, and
    # no rule picks a winner because the disagreement is about what happened
    # in a room. So handing a tournament over locks the copy left behind.
    #
    # nil = live here and writable. Set = checked out; this copy is a
    # read-only record of the event until `Tournaments.take_back/2` clears
    # it. A timestamp rather than a boolean because the banner has to say
    # WHEN it left; not a `status` value because `status` is derived (see
    # `Tournaments.derive_status/1`) and would be recomputed away - the same
    # reasoning as `archived_at` above.
    field :handed_off_at, :utc_datetime

    # Where it went, as a human label: "this laptop", a hostname, a server
    # address. Free text on purpose - the two ends of a hand-off do not
    # necessarily know each other's identifiers, and the only consumer is a
    # person reading a banner that has to answer "so where IS it?".
    field :handed_off_to, :string

    # The secret minted at hand-off, which the returning payload must present
    # to unlock (constant-time compared - see `Tournaments.take_back/2`).
    # Without it, anything that could reach this row could clear the lock and
    # produce a second live copy, which is the exact state the lock exists to
    # prevent.
    field :handoff_token, :string

    # The mirror of the three above, and deliberately NOT stored in them:
    # where this copy CAME FROM, plus the token that unlocks the copy left
    # behind there. `%{"instance" => ..., "address" => ..., "label" => ...,
    # "release_token" => ..., "handed_off_at" => ..., "received_at" => ...}`,
    # or nil for a tournament that was created here.
    #
    # "Handed away" and "arrived from" are opposite states, and a copy can be
    # in both at once - received from A and handed on to C. The three columns
    # above cannot express that: `hand_off/2` overwrites `handoff_token` with
    # a freshly minted one, so handing a received copy onward would destroy
    # the borrowed key, and `handoff_token_matches?/2` refuses to compare a
    # token at all while `handed_off_at` is nil - which it must be on a
    # received copy, since a received copy is live and writable here. See
    # `20260902180000_add_tournament_handoff_origin.exs` for the full
    # argument.
    #
    # Written only by `PairingsEngine.Handoff`, and not cast, for the same
    # reason as `openresults_claim`: it holds a credential that arrived in a
    # file, and an ordinary settings save or a backup import must not be able
    # to invent one.
    field :handoff_origin, :map

    # None of the three is cast by `changeset/2`, and that is the whole
    # safety property rather than tidiness. `Tournaments.hand_off/2` and
    # `take_back/2` are meant to be the ONLY writers: every other write in
    # the app is refused while `handed_off_at` is set
    # (`Tournaments.ensure_writable/1`), so a form or an import that could
    # set - or worse, CLEAR - these fields would be a way to mint a second
    # live copy with an ordinary settings save. `TournamentImport` and
    # `Snapshots.restore/3` both write through `changeset/2`, so keeping
    # these out of `cast` is what makes an imported file structurally unable
    # to arrive holding somebody else's lock (or, having been exported from
    # a locked copy, to unlock itself on the way in). Same reasoning, and
    # the same mechanism, as `archived_at` / `openresults_key` above.

    # Manual standings override (SWAR parity #23) - when true, the arbiter's
    # hand-set `players.manual_rank` order replaces the computed tiebreak
    # order. Every surface showing a rank must display an override banner:
    # a silent override is indistinguishable from a tiebreak bug.
    field :manual_ranking, :boolean, default: false

    # Set when a result changes after the hand-set order was seeded: the order
    # is still displayed, but every banner must report it as no longer matching
    # the current results. Managed by the Tournaments manual-ranking functions.
    field :manual_ranking_stale, :boolean, default: false

    # The round in which this tournament's settings first stopped describing
    # a FIDE-handled event, or nil if that has never happened. See
    # `PairingsEngine.Compliance`, which decides WHETHER, and only ever from
    # the settings - there is no stored "is it compliant" flag and there is
    # no toggle, because FIDE Mode is the default and a second FIDE-ish
    # tickbox is exactly the control VCL.01/VCL.02 do not describe.
    #
    # This is the one half that cannot be derived. VCL4THP wants a `###` TRF
    # comment naming the round the mode was left in, and by the time anyone
    # exports the file the setting may have been put back, or five more
    # rounds may have been paired over it. So the round is recorded once, at
    # the moment it happens, and never cleared - putting the setting back
    # makes `Compliance.compliant?/1` true again while this column keeps
    # saying it was once false. The two answer different questions.
    #
    # `0` is a legitimate value ("lost before round 1 was paired" - a Keizer
    # tournament is non-compliant from creation); nil means "never lost", and
    # nothing else.
    #
    # NOT in `cast/3`'s list below, and that is the whole safety property
    # rather than tidiness: this is a fact about history, and an ordinary
    # settings save - or a stale form, or an import - must not be able to
    # rewrite it or, far worse, clear it. `Tournaments` writes it with
    # `put_change/3` inside the same changeset as the save that causes it, so
    # the settings change and the record of it either both land or neither
    # does; `TournamentImport` carries it explicitly, taking the EARLIER of
    # the live value and the file's. Same mechanism as `manual_ranking_stale`
    # directly above.
    field :fide_compliance_lost_round, :integer

    # Per-tournament print logo (SWAR parity #14-16), stored as a DB blob so
    # backups/deploys carry it. Written only by Tournaments.set_logo/2 and
    # clear_logo/1 - NOT cast by changeset/2, same reasoning as deleted_at.
    field :logo_data, :binary
    field :logo_content_type, :string

    # Postponed games (`PairingsEngine.PostponedGames`, VCL4THP Q157-169):
    # whether the tournament allows them, and what one counts as until it is
    # played - for the player who postponed it and for the opponent, as an
    # outcome (`"win"`/`"draw"`/`"loss"`) so it scales with the tournament's
    # own scoring. Both draw by default, the FIDE rule; anything else is a
    # departure from FIDE mode (`PairingsEngine.Compliance`).
    field :postponed_games, :boolean, default: false
    field :postponed_requester_outcome, :string, default: "draw"
    field :postponed_opponent_outcome, :string, default: "draw"

    # The postponed-games file is reported to FIDE as a tournament of its
    # own (`PairingsEngine.TrfExport.postponed_export/2`): its own name -
    # nil for the default, the event's name + "postponed games" - and its
    # own FIDE tournament ID, separate from `fide_tournament_id`.
    field :postponed_report_name, :string
    field :postponed_fide_tournament_id, :string

    # Set on a copy imported from a file of an event that may already have
    # been reported from elsewhere (`"json"`, `"trf"`, `"swar"`): nothing
    # is sent from this copy until an arbiter confirms it is the one that
    # reports (`Tournaments.confirm_sending/2`). Not cast, not exported -
    # only an import sets it and only that confirmation clears it.
    field :send_confirmation_needed, :string

    # Bye exclusions for ONE pairing run - never stored (docs/pairing-systems.md,
    # "Bye exclusions"). They ride on the struct because it is the one value
    # every layer of `PairingsEngine.Pairing` already passes down, from
    # `pair_next_round/2` to the Ainalrami options, so the per-round
    # exclusion list reaches the engine without a new argument on every
    # function in between.
    #
    #   * `bye_exclusion_override` - a player id whose exclusion the arbiter
    #     lifted for the round being paired ("Pair anyway, ignoring the
    #     exclusion for X"). Set by the caller.
    #   * `engine_bye_exclusions` - the engine ranks excluded from the bye in
    #     the run under way. Set by `Pairing` itself just before the engine
    #     is called, from the players' `no_bye` settings.
    field :bye_exclusion_override, :integer, virtual: true
    field :engine_bye_exclusions, {:array, :integer}, virtual: true, default: []
    # The players' bye preferences for the run under way, as the engine
    # takes them - `[{rank, :want_hard | :want_soft | :avoid_soft}]` - set
    # beside `engine_bye_exclusions` and never stored. Empty on a
    # FIDE-rated tournament (docs/pairing-systems.md, "Bye preferences").
    field :engine_bye_preferences, {:array, :any}, virtual: true, default: []
    belongs_to :user, PairingsEngine.Accounts.User
    has_many :players, PairingsEngine.Tournaments.Player
    has_many :teams, PairingsEngine.Tournaments.Team
    has_many :rounds, PairingsEngine.Tournaments.Round

    timestamps(type: :utc_datetime)
  end

  @doc """
  The entry form's window, cap and entry-list switch - and nothing else.

  Its own changeset because `changeset/2` deliberately does not cast any of
  the entry form's settings (see `registration_open`): these four are saved
  from their own card on the Results settings page, through
  `Tournaments.set_registration_settings/2`.
  """
  def registration_changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [
      :registration_opens_at,
      :registration_closes_at,
      :registration_max_players,
      :registration_list_public
    ])
    |> validate_number(:registration_max_players,
      greater_than: 0,
      less_than_or_equal_to: 10_000,
      message: "must be a whole number of players, at least 1"
    )
    |> validate_window()
  end

  defp validate_window(changeset) do
    opens = get_field(changeset, :registration_opens_at)
    closes = get_field(changeset, :registration_closes_at)

    if opens && closes && DateTime.compare(closes, opens) != :gt do
      add_error(changeset, :registration_closes_at, "must be after the opening time")
    else
      changeset
    end
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
      :late_entry_absences,
      :presence_on_allocated_bye,
      :postponed_games,
      :postponed_requester_outcome,
      :postponed_opponent_outcome,
      :postponed_report_name,
      :postponed_fide_tournament_id,
      :tiebreaks,
      :acceleration,
      :status,
      :standard,
      :rate_of_play,
      :organizer_club_number,
      :swar_guid,
      :categories,
      :swar_category_type,
      :swar_category_axis2,
      :category_rules,
      :category_prizes,
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
      :team_boards,
      :team_match_points_win,
      :team_match_points_draw,
      :team_match_points_loss,
      :initial_colour,
      :pair_by_category,
      :club_exclusion,
      :club_exclusion_list,
      :fed_exclusion,
      :fed_exclusion_list,
      :soft_club_rounds,
      :soft_position,
      :extra_points_mode,
      :count_extra_points,
      :extra_points_bands,
      :categories_enabled,
      :categories_ranked_separately,
      :manual_ranking,
      :publish_mode,
      :publish_delay_minutes
    ])
    |> cast_round_dates(attrs)
    |> validate_required([:name, :type, :rounds_count])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:acceleration, @accelerations)
    |> validate_inclusion(:extra_points_mode, @extra_points_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:standard, @standards)
    |> validate_inclusion(:pairing_system, @pairing_systems)
    |> validate_inclusion(:pairing_engine, @pairing_engines)
    |> validate_inclusion(:rr_cycles, @rr_cycles_values)
    |> validate_inclusion(:publish_mode, @publish_modes)
    |> validate_number(:publish_delay_minutes, greater_than_or_equal_to: 0)
    |> validate_inclusion(:club_exclusion, @exclusion_modes)
    |> validate_inclusion(:fed_exclusion, @exclusion_modes)
    |> validate_inclusion(:soft_position, @soft_positions)
    |> validate_inclusion(:postponed_requester_outcome, ~w(win draw loss))
    |> validate_inclusion(:postponed_opponent_outcome, ~w(win draw loss))
    |> validate_length(:postponed_report_name, max: 200)
    |> validate_length(:postponed_fide_tournament_id, max: 40)
    |> validate_inclusion(:initial_colour, @initial_colours)
    |> validate_number(:soft_club_rounds, greater_than_or_equal_to: 0)
    |> validate_number(:team_boards, greater_than: 0, less_than_or_equal_to: @max_team_boards)
    |> validate_number(:team_match_points_win, greater_than_or_equal_to: 0)
    |> validate_number(:team_match_points_draw, greater_than_or_equal_to: 0)
    |> validate_number(:team_match_points_loss, greater_than_or_equal_to: 0)
    |> validate_number(:rounds_count, greater_than: 0, less_than_or_equal_to: max_rounds())
    |> validate_length(:swar_guid, max: 200)
    |> validate_format(:swar_guid, @safe_swar_guid,
      message: "must not contain quotes, slashes or control characters"
    )
    |> validate_keizer_top_value()
    |> validate_pairing_engine()
    |> validate_abs_scoring()
    |> validate_rr_match_format()
    |> validate_swiss_match_format()
    |> validate_pair_by_category()
    |> validate_extra_points_excludes_baku()
    |> normalize_exclusion_list(:club_exclusion_list)
    |> normalize_exclusion_list(:fed_exclusion_list)
    |> normalize_extra_points_bands()
    |> normalize_fide_id_ranges()
    |> normalize_category_prizes()
    |> put_public_slug()
    |> pad_round_dates_to_rounds_count()
    |> derive_dates_from_round_dates()
  end

  # `round_dates` is positional: entry i is round i+1's date, `""` when that
  # round has none. So it is cast on its own, with no empty values. Under
  # `cast/3`'s default `empty_values`, Ecto removes every blank string from
  # INSIDE an array it casts, which compacted a schedule with gaps:
  # ["2026-10-18", "", "", "", "", "", "2026-10-25"] became
  # ["2026-10-18", "2026-10-25", "", ...] once padded, and the last round's
  # date landed on round 2. Every writer went through here - the Dates page,
  # the JSON import (whose own export writes the blanks), the SWAR import.
  # A nil entry (a JSON null) is a blank too, and like a whitespace-only one
  # is stored as the `""` every other blank is.
  defp cast_round_dates(changeset, attrs) do
    changeset = cast(changeset, attrs, [:round_dates], empty_values: [])

    case get_change(changeset, :round_dates) do
      dates when is_list(dates) ->
        put_change(changeset, :round_dates, Enum.map(dates, &blank_round_date/1))

      _ ->
        changeset
    end
  end

  defp blank_round_date(nil), do: ""
  defp blank_round_date(date), do: String.trim(date)

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
  #
  # The upper bound is SWAR's: both are one-byte fields in the `.swar`
  # format, so `SwarExport`'s `w_u8/1` masked anything past 255 (256 wrote
  # as 0 - "no round qualifies", the opposite of what was meant). The export
  # clamps and logs as a backstop; refusing the value at the door is the
  # honest answer for a number no round count or absence count could reach.
  defp validate_abs_scoring(changeset) do
    changeset
    |> validate_number_if_present(:abs_jusque,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 255
    )
    |> validate_number_if_present(:abs_nbfois,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 255
    )
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
  # engine agrees with bbpPairings across ~488 million pairings. The one
  # place it differed - Article 5.2.5's parity - was settled by the FIDE
  # Systems of Pairings and Programs Commission on 2026-08-28, against this
  # project, and v0.14.0 conforms (see the sibling project's
  # dispute-initial-colour.md). So the divergence this paragraph was written
  # around is gone; refusing outright asserted a quality judgement the
  # measurements did not support then and do not now.
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

  # Baku (C.04.7) and extra points that feed the pairing are two ways of
  # handing the engine virtual points, and they are not combined: both would
  # be one `XXA` value per player per round, and no rule says how Baku's
  # Group A and a player's extra points should add up. Refused outright,
  # same precedent as the other exclusive options above. The error lands on
  # whichever of the two this save changed, so the page that made the
  # conflicting change is the one that shows it.
  #
  # `Pairing.accelerations/3` gives Baku precedence all the same, for a row
  # that reached the database some other way (an import writes the two in
  # separate saves).
  defp validate_extra_points_excludes_baku(changeset) do
    extra_points_pairing? =
      case get_field(changeset, :extra_points_mode) do
        "acceleration" -> true
        _handicap -> get_field(changeset, :count_extra_points) == true
      end

    if get_field(changeset, :acceleration) == "baku" and extra_points_pairing? do
      field = if get_change(changeset, :acceleration), do: :acceleration, else: :extra_points_mode

      add_error(
        changeset,
        field,
        "Baku acceleration cannot be combined with extra points in the pairing (extra points in acceleration mode, or counted in handicap mode)"
      )
    else
      changeset
    end
  end

  @doc """
  Whether `tournament`'s players' `extra_points` go to the pairing engine as
  virtual points (`PairingsEngine.Pairing.accelerations/3`).

    * Acceleration mode: always - that is what the mode is.
    * Handicap mode: while the points count (`count_extra_points`), so that
      the score groups the engine pairs are the standings' own. Off, the
      points do nothing anywhere.

  Only a Swiss pairs through an engine that reads virtual points; round
  robin's schedule and Keizer's ladder never do. And never together with
  Baku, which the changeset refuses and this gives precedence to.
  """
  def extra_points_pairing?(%__MODULE__{pairing_system: "swiss", acceleration: acceleration} = t)
      when acceleration != "baku" do
    case t.extra_points_mode do
      "acceleration" -> true
      _handicap -> t.count_extra_points == true
    end
  end

  def extra_points_pairing?(%__MODULE__{}), do: false

  @doc "Whether `tournament` treats extra points as SWAR-style acceleration."
  def extra_points_acceleration?(%__MODULE__{extra_points_mode: "acceleration"}), do: true
  def extra_points_acceleration?(%__MODULE__{}), do: false

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
  returned by `parse_extra_points_bands/1`) in `mode` - the tournament's
  `extra_points_mode`.

  ## "acceleration" - at or above the rating (SWAR's XtraPoints)

  A player matches every band whose threshold is at or below their rating,
  and the **highest** such threshold wins: with `"1800:0.5, 2000:1"` a
  2100-rated player gets `1.0`, a 1900-rated one `0.5`, a 1700-rated one
  nothing. This is SWAR's own rule (`XtraPoints.cpp`, `AssignExtraPoints`:
  the bands sorted by Elo descending, the first with `EloUsed >= Elo`
  wins). A `0:bonus` band is the one an unrated player (rating 0) can
  match - everybody is at or above 0 - so it reads as "everyone else".

  ## "handicap" - below the rating

  The rule this app has always had (SWAR parity #12):

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
  @spec band_extra_points([{non_neg_integer(), float()}], non_neg_integer(), String.t()) ::
          float()
  def band_extra_points(bands, rating, mode \\ "handicap")

  def band_extra_points(bands, rating, "acceleration") do
    bands
    |> Enum.filter(fn {threshold, _bonus} -> rating >= threshold end)
    |> Enum.max_by(fn {threshold, _bonus} -> threshold end, fn -> nil end)
    |> case do
      nil -> 0.0
      {_threshold, bonus} -> bonus
    end
  end

  def band_extra_points(bands, 0, _handicap) do
    case Enum.find(bands, fn {threshold, _bonus} -> threshold == 0 end) do
      {_threshold, bonus} -> bonus
      nil -> 0.0
    end
  end

  def band_extra_points(bands, rating, _handicap) do
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

  # Coerces every value in `category_prizes` to a non-negative integer,
  # dropping anything that doesn't parse as one (a blank form field, a
  # negative number, stray non-numeric input) rather than failing the whole
  # save - the same "tidy what's there, refuse nothing outright" precedent
  # `normalize_exclusion_list/2` sets, chosen here because a bad prize count
  # is display-only (see `PairingsEngine.Categories.prize_place?/3`) and
  # never something pairing or scoring reads. A category name is not
  # checked against `categories` here - same reasoning as
  # `category_rules`, which has never pruned itself when a category is
  # removed (see `CategoriesLive.remove_category/2`): the count is a fact
  # an arbiter set, and re-adding the name should bring it back.
  defp normalize_category_prizes(changeset) do
    case get_change(changeset, :category_prizes) do
      nil ->
        changeset

      value when is_map(value) ->
        normalized =
          value
          |> Enum.map(fn {name, count} -> {to_string(name), coerce_prize_count(count)} end)
          |> Enum.reject(fn {_name, count} -> count == nil end)
          |> Map.new()

        put_change(changeset, :category_prizes, normalized)

      _not_a_map ->
        add_error(changeset, :category_prizes, "must be a map of category name to prize count")
    end
  end

  defp coerce_prize_count(count) when is_integer(count) and count >= 0, do: count

  defp coerce_prize_count(count) when is_binary(count) do
    case Integer.parse(String.trim(count)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp coerce_prize_count(_count), do: nil

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

  @doc """
  Whether this is a team tournament - `type` "team-roundrobin" or
  "team-swiss". The one question every team-aware screen asks, so it is
  asked one way.
  """
  def team?(%{type: type}), do: type in @team_types
  def team?(_), do: false

  @doc """
  Whether this is a team round robin that runs the Berger table over teams.

  Both fields, because they are set independently: the TRF importer
  classifies a file's `092` into `type` and always pairs the result as a
  Swiss, so "team-roundrobin" alone does not mean a Berger table runs.
  """
  def team_round_robin?(%{type: "team-roundrobin", pairing_system: "round_robin"}), do: true
  def team_round_robin?(_), do: false

  @doc """
  Whether this is a team Swiss paired team against team (C.04.6,
  `PairingsEngine.TeamSwiss`): type "team-swiss", Swiss pairing, and not an
  event whose rounds were paired player by player (`team_pairing_mode`
  "players"), which stays on the individual path. nil - nothing paired yet -
  counts as by teams, because that is how its first round will be paired.
  """
  def team_swiss?(%{type: "team-swiss", pairing_system: "swiss", team_pairing_mode: mode})
      when mode in [nil, "teams"],
      do: true

  def team_swiss?(_), do: false

  @doc """
  Whether this tournament is paired as teams - team against team, in
  matches - by either system: a team round robin (`team_round_robin?/1`), or
  a team Swiss paired under C.04.6 (`team_swiss?/1`: new, not yet paired, or
  already paired by teams).

  False for an individual tournament, and false for a team Swiss whose rounds
  were paired player by player before C.04.6 was wired in
  (`team_pairing_mode` "players"): that event has no matches and no team
  standings, and its real standings are the individual ones. So this, not
  `team?/1`, is the question for anything that shows or publishes matches,
  team standings or team printing; `team?/1` only says the event is
  classified as a team event (it has a Teams page and a TRF team section).
  """
  def paired_as_teams?(t), do: team_round_robin?(t) or team_swiss?(t)

  @doc "The values `initial_colour` takes: drawn by lot, or set by the arbiter."
  def initial_colours, do: @initial_colours

  @doc """
  The initial colour the engines are told, as "white" / "black", or nil when
  there is none to tell: the setting is "lot" and nothing has been drawn yet
  (before round 1, or a tournament paired before the draw was recorded).
  """
  def effective_initial_colour(%{initial_colour: colour}) when colour in ["white", "black"],
    do: colour

  def effective_initial_colour(%{initial_colour_drawn: drawn}) when drawn in ["white", "black"],
    do: drawn

  def effective_initial_colour(_), do: nil

  def max_team_boards, do: @max_team_boards

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

  def soft_positions, do: @soft_positions

  def soft_position_label("strong"), do: "Strong - before the colour and float rules"
  def soft_position_label("weak"), do: "Weak - only as a tie-break"
  def soft_position_label(other), do: other

  def pairing_engine_label("javafo"), do: "JaVaFo (2017 rules)"
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

  An unplayed round is written with the TRF letter for what it is worth
  (`Pairing.unplayed_code/2`): `Z` for nothing - a zero-point bye, an
  absence that pays nothing, a round before the player joined or after
  they withdrew - `H` for a draw's worth and `F` for a win's. So
  `zero_point_bye` is 0, TRF's own meaning of `Z`, and the letters in the
  file add up to its score column.

  Until 2026-10-02 every unplayed round was written `Z` and
  `zero_point_bye` was the absence value (`abs_value`, else the loss): a
  round before joining or after withdrawing, an absence paid half a point
  or a full one and a capped absence were all one letter at one value, so
  the file contradicted its own score column whenever they differed.

  What is left: a value that is none of 0, a draw's or a win's - an absence
  paid half a point in a 3-1-0 event, a 3-2-1 event's zero-point bye or
  capped absence worth the loss's presence point - has no letter and is
  written `Z`. The score the engine BRACKETS by comes from the file's own
  score column (`Pairing.player_points/2`), which is exact; this map is only
  consulted where a per-round value is needed - reconstructing what a
  player had before round N, and deciding float direction - so the error is
  bounded to those.
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
      # TRF `Z` - an unplayed round worth nothing. An absence that pays
      # something is written `H` or `F` instead (see above).
      zero_point_bye: 0.0
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

  @doc """
  How far the automation moves each round up, as a level of the per-round
  ladder (`Tournaments.round_publish_state/2`): `0` by hand, `1` pairings,
  `2` and results, `3` and standings. A value this code does not know reads
  as `0` - never publishing is the direction a mistake here should fail in.
  """
  @spec auto_publish_level(%__MODULE__{} | String.t() | nil) :: 0..3
  def auto_publish_level(%__MODULE__{publish_mode: mode}), do: auto_publish_level(mode)
  def auto_publish_level("pairings"), do: 1
  def auto_publish_level("results"), do: 2
  def auto_publish_level("standings"), do: 3
  def auto_publish_level(_manual_or_unknown), do: 0

  @doc "The `publish_mode` for an automation level - `auto_publish_level/1` backwards."
  @spec publish_mode_for_level(0..3) :: String.t()
  def publish_mode_for_level(level) when level in 0..3, do: Enum.at(@publish_modes, level)

  @doc """
  The `publish_mode` a tournament stored before 2026-09-28 converts to.
  Shared, frozen logic, pure for the reason `legacy_standings_through/3`
  gives: the migration that introduced the automation ladder, the import of
  an older backup and the account's stored tournament defaults all apply it.

  One to one, as far as each old mode goes:

    * `"manual"` - by hand, as before.
    * `"timed"` - the pairings step, its delay kept. Results and standings
      followed the switches by hand in timed mode, and still do.
    * `"immediate"` - the standings step: immediate made every paired round,
      every result and the standings through every finished round public the
      moment they existed, which is the whole ladder with no delay. The
      per-round lock it carried is gone - the arbiter can now take a round
      back down by hand.
    * `"scheduled"` (a round public at midnight on its own date) - by hand.
      There is no date step on the ladder, and publishing the next round the
      moment it is paired would put it out before the date the arbiter chose;
      rounds already paired keep their date.

  `display` is the tournament's stored `public_display`. The "Standings" and
  "Round pairings" page switches were retired the same day - the per-round
  level decides that now - so a tournament that had one of them off gets an
  automation that stops below that step: no standings step with "Standings"
  off, nothing automatic with "Round pairings" off. The switch itself stays
  stored and honoured until the arbiter shows the page again
  (`PairingsEngine.PublicDisplay.legacy_hidden/1`), so nothing hidden today
  appears on the upgrade.
  """
  @spec legacy_publish_mode(String.t() | nil, map() | nil) :: String.t()
  def legacy_publish_mode(mode, display) do
    level =
      case mode do
        "immediate" -> 3
        "timed" -> 1
        "scheduled" -> 0
        other -> auto_publish_level(other)
      end

    level =
      cond do
        hidden_page?(display, "pairings") -> 0
        hidden_page?(display, "standings") -> min(level, 2)
        true -> level
      end

    publish_mode_for_level(level)
  end

  @doc "Whether `mode` is one of the values `publish_mode` held before 2026-09-28."
  def legacy_publish_mode?(mode), do: mode in @legacy_publish_modes

  defp hidden_page?(display, key) when is_map(display), do: Map.get(display, key) == false
  defp hidden_page?(_display, _key), do: false

  @doc """
  The `standings_through` a tournament converts to, from what publishing
  looked like under the pre-2026-09-11 model where the entry list was
  gated by a single `publish_starting_rank` flag rather than a per-round
  value. Shared, frozen logic: `20260911130000_add_standings_through.exs`
  (backfilling every existing tournament at deploy) and
  `PairingsEngine.TournamentImport` (a backup written before this field
  existed) both need the exact same conversion, and this is a pure
  function of three already-computed facts so that calling it from the
  migration carries none of the "drifts from a live computation" risk that
  migration's own moduledoc warns about - there is no schema or query
  inside it to drift.

  `contiguous_prefix` is the deepest round N such that rounds 1..N are
  both published and complete (what `standings_through_round/1` already
  computes); `any_published?` is whether any round is published at all,
  contiguous or not; `publish_starting_rank?` is the flag's own value.

  Returns `nil` - "withhold the roster entirely" - only in the one case
  that used to mean exactly that: nothing published, and the flag off.
  Every other combination keeps the roster public via `contiguous_prefix`
  (itself `0` when nothing is complete yet), matching what publishing
  already looked like before this field existed.
  """
  @spec legacy_standings_through(non_neg_integer(), boolean(), boolean()) ::
          non_neg_integer() | nil
  def legacy_standings_through(contiguous_prefix, any_published?, publish_starting_rank?) do
    if contiguous_prefix == 0 and not any_published? and not publish_starting_rank? do
      nil
    else
      contiguous_prefix
    end
  end
end
