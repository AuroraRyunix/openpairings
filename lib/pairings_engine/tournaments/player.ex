defmodule PairingsEngine.Tournaments.Player do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @paid_statuses ~w(nopaid paid gratis)

  schema "players" do
    field :name, :string
    field :sex, :string, default: ""
    field :title, :string, default: ""
    field :fide_id, :integer
    field :fide_rating, :integer, default: 0
    # Where `fide_rating` came from, kept beside it (VCL4THP 134): the FIDE
    # list it was read from ("standard" | "rapid" | "blitz"), the monthly list
    # ("YYYY-MM") it belongs to, and the value as that list printed it. All
    # nil for a rating nobody read from a list. A later hand edit changes
    # `fide_rating` and leaves these three, which is how `rating_manual?/1`
    # tells a modified rating from an untouched one.
    field :fide_rating_source, :string
    field :fide_rating_period, :string
    field :fide_rating_listed, :integer
    field :national_id, :string, default: ""
    field :national_rating, :integer, default: 0
    # A rating typed by hand for this tournament (the TEC Manual's "manually
    # entered value"), read only by the HBFN and OTHER Tournament Rating
    # methods - see `rating/2`. nil when nobody typed one.
    field :tournament_rating, :integer
    # A tournament lasting more than 30 days (`Tournament.long_event`): the
    # player's LATER ratings, each with the first round it applies to -
    # `[%{"from_round" => 5, "fide_rating" => 1850}]`, optionally with a
    # `"national_rating"` too, oldest first. `fide_rating`/`national_rating`
    # above stay the first rating, the one the tournament started with. Read
    # through `PairingsEngine.PeriodRatings`; typed on the Players page as
    # `period_ratings_text` ("5:1850, 9:1872").
    field :period_ratings, {:array, :map}, default: []
    field :period_ratings_text, :string, virtual: true
    field :federation, :string, default: ""
    field :birth_year, :integer
    field :club, :string, default: ""
    field :status, :string, default: "active"
    field :start_round, :integer, default: 1
    field :board_order, :integer
    # The teams this player was on before a move between teams made after
    # they had played (`Tournaments.set_player_team/3`, outside FIDE mode
    # only): `[%{"team_id" => id, "through_round" => n}]`, oldest first - on
    # that team through round n. Read by the TRF report, which lists a
    # player under the team they played for. Never cast.
    field :team_history, {:array, :map}, default: []
    field :pairing_number, :integer

    # nopaid | paid | gratis (SWAR §5.20)
    # Defaults to NOT paid, because that is what is true when a player is
    # added: they are on the list and the money has not arrived yet.
    # Defaulting to "paid" made the arbiter's job the wrong way round - every
    # new entry arrived already ticked, so the only way to keep the column
    # honest was to un-tick people, and a column nobody trusts is a column
    # nobody reads. Now it fills in as the fee comes in.
    #
    # The COLUMN default in `20260710120000_add_swar_admin_fields.exs` is
    # still "paid" and is deliberately left alone: every write goes through
    # this schema, which sends the struct default, so the column default is
    # reachable only from hand-written SQL - and changing it would cost a
    # SQLite table rebuild for no behaviour. The SWAR importer sets `paid`
    # from the file it is reading and is unaffected either way.
    # Same reasoning as `publish_mode`'s two defaults - see TODO.md.
    field :paid, :string, default: "nopaid"
    # SWAR Aff. (§5.21)
    field :affiliated, :boolean, default: true
    # SWAR Absent checkbox - player not paired at all while set
    field :absent, :boolean, default: false
    # SWAR Forfeit - player withdrawn/forfeited out
    field :forfeit, :boolean, default: false
    # Fixed-table accommodation (SWAR HandyTable) - informational only
    field :special_table, :boolean, default: false
    # Comma-separated round numbers, e.g. "3,5"
    field :absent_rounds, :string, default: ""
    # C.05:6.7.4: no half-point bye for a player who received conditions or
    # free entry. Marked by the arbiter; `Tournaments.update_player/2,3`
    # refuses to give such a player a half-point absence.
    field :no_half_bye, :boolean, default: false

    # "No pairing-allocated bye" - an ORGANISER's rule, not FIDE's (a player
    # who travelled far, a junior with a long drive home). While set, the
    # Swiss engine treats the player as C.04.3 [C2] treats one who already
    # had a pairing-allocated bye: ineligible for the bye, and for nothing
    # else. `no_bye_rounds` blank means every round; otherwise the rounds it
    # applies to, in `absent_rounds`' canonical form and parsed by the same
    # two functions. Only Ainalrami honours it (`PairingsEngine.Pairing`'s
    # `bye_exclusion_ranks/4`); JaVaFo, round robin and Keizer ignore it.
    # See docs/pairing-systems.md, "Bye exclusions".
    field :no_bye, :boolean, default: false
    field :no_bye_rounds, :string, default: ""
    # The player form's "All rounds" / "Certain rounds" choice. Not stored:
    # it is `no_bye_rounds` being blank or not, and exists so the form can
    # be told "certain rounds" before any round has been typed.
    field :no_bye_scope, :string, virtual: true

    # A PREFERENCE for the pairing-allocated bye - also an organiser's wish,
    # not FIDE's (docs/pairing-systems.md, "Bye preferences"):
    #
    #   ""           none
    #   "want_hard"  must get it, if a legal round gives it to them
    #   "want_soft"  rather gets it: decides among the players on the bye
    #                score, never lifts the bye to a higher score
    #   "avoid_soft" rather not: someone else on the bye score takes it if
    #                anyone can
    #
    # The fourth setting, "must not get it", is `no_bye` above - the same
    # rule, kept in its own columns so tournaments that already use it pair
    # exactly as before. `bye_preference_rounds` is `no_bye_rounds`' twin.
    # Only Ainalrami honours it, and never on a FIDE-rated tournament
    # (`fide_homologated`): the pairing ignores a stored one there and the
    # player form does not offer it (`PairingsEngine.Pairing`'s
    # `bye_preference_ranks/4`).
    field :bye_preference, :string, default: ""
    field :bye_preference_rounds, :string, default: ""
    field :bye_preference_scope, :string, virtual: true
    # SWAR XtPts
    field :extra_points, :float, default: 0.0
    # A tie-break value calculated outside the program (code "EXT" in the
    # tournament's tie-break list), typed by the arbiter on the Standings
    # page; nil until entered, counted as 0. Higher ranks higher.
    field :external_tiebreak, :float
    # The pairing-pool OVERRIDE, not "the player's category". A player can
    # carry several categories (`categories` below); `pair_by_category` can
    # only put them in one pool, so exactly one of those tags has to win.
    # This field names which - and it is honoured only while it is still one
    # of the player's tags AND still one of the tournament's categories, so a
    # stale value self-heals into the derived answer rather than fighting it.
    # `PairingsEngine.Categories.pairing_category/2` is the only reader that
    # matters; nothing else should compare this to a category name directly.
    #
    # Still called `category` (singular) and still the SWAR wire field: SWAR
    # carries one signed category index per player and has no second slot to
    # put a tag in, so this is what a `.swar` round trip preserves.
    field :category, :string, default: ""

    # Every category this player belongs to, as names drawn from the
    # tournament's own `categories` list. Prize lists, filtering, the printed
    # per-category standings tables - everything that is a LABEL rather than
    # a pairing decision reads this. Order is not meaningful: it is a set,
    # and the UI is careful never to sort on it as though it were not (see
    # `PlayersLive`'s "cat" and "cat:<tag>" sort clauses).
    #
    # Stored as JSON in a TEXT column by the SQLite adapter, same as
    # `tournaments.categories` has been since the SWAR admin fields landed.
    field :categories, {:array, :string}, default: []
    # SWAR N° Club (club NAME stays in `club`)
    field :club_number, :integer

    # Per-player title-norm judgment data for the IT4 report - recognised
    # string keys (all optional; a blank/missing "title_claimed" means this
    # player isn't currently an IT4 candidate):
    #
    #   title_claimed       - target title being claimed, e.g. "IM" (IT4 W11)
    #   norm_description    - free text, e.g. "IM norm" (IT4 Y11)
    #   medal_percent       - free text/numeric, e.g. "62.5%" (IT4 U11)
    #   remarks             - free text (IT4 AB11)
    #   event_group         - e.g. "U20, Women" (IT4 P11)
    #   fed_participating   - number of federations participating (IT4 R11)
    #   fed_members         - number of federations eligible (IT4 S11)
    field :norm_data, :map, default: %{}

    # Full date of birth when known (TRF wants YYYY/MM/DD); birth_year is the
    # year-only fallback. Keep both in sync where possible.
    field :birth_date, :date

    # Physical table override (SWAR "special table"): this player's games are
    # displayed/printed at this table number. nil = normal board numbering.
    field :fixed_board, :integer

    # Arbiter-assigned standings position, honoured only while the tournament
    # has `manual_ranking` on (SWAR parity #23). nil = never hand-placed.
    # Managed by the Tournaments reorder functions - NOT cast by changeset/2,
    # so an ordinary player edit can never silently reposition the field.
    field :manual_rank, :integer

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :team, PairingsEngine.Tournaments.Team

    timestamps(type: :utc_datetime)
  end

  @doc """
  Whether the player is out of the event of their own accord or by the
  arbiter's hand as a withdrawal: the `withdrawn` status (a withdrawn team's
  roster) or the individual Forfeit tick, which is how a player is
  withdrawn here.
  """
  def withdrawn?(%{status: "withdrawn"}), do: true
  def withdrawn?(%{forfeit: true}), do: true
  def withdrawn?(_player), do: false

  @doc """
  Whether the arbiter expelled the player (VCL4THP Q197): not paired any
  further, like a withdrawn player, and left out of the standings.
  """
  def expelled?(%{status: "expelled"}), do: true
  def expelled?(_player), do: false

  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :name,
      :sex,
      :title,
      :fide_id,
      :fide_rating,
      :fide_rating_source,
      :fide_rating_period,
      :fide_rating_listed,
      :national_id,
      :national_rating,
      :tournament_rating,
      :federation,
      :birth_year,
      :club,
      :status,
      :start_round,
      :team_id,
      :board_order,
      :pairing_number,
      :paid,
      :affiliated,
      :absent,
      :forfeit,
      :special_table,
      :absent_rounds,
      :no_half_bye,
      :extra_points,
      :external_tiebreak,
      :category,
      :categories,
      :club_number,
      :norm_data,
      :birth_date,
      :fixed_board,
      :no_bye,
      :no_bye_rounds,
      :no_bye_scope,
      :bye_preference,
      :bye_preference_rounds,
      :bye_preference_scope,
      :period_ratings
    ])
    # Kept as typed, blank included: an emptied box is "no later ratings",
    # which the default empty-to-nil cast would not see as a change.
    |> cast(attrs, [:period_ratings_text], empty_values: [])
    |> normalize_rating_provenance()
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:status, ~w(active withdrawn expelled))
    |> validate_inclusion(:paid, @paid_statuses)
    |> validate_number(:extra_points, greater_than_or_equal_to: 0.0)
    |> blank_start_round_is_one()
    |> validate_number(:start_round,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: PairingsEngine.Tournaments.Tournament.max_rounds()
    )
    |> validate_fixed_board()
    |> validate_team_in_tournament()
    |> normalize_absent_rounds()
    |> normalize_no_bye()
    |> normalize_bye_preference()
    |> normalize_categories()
    |> normalize_period_ratings()
    |> sync_special_table()
    |> validate_fide_id_range()
    |> validate_number(:tournament_rating, greater_than_or_equal_to: 0, less_than: 10_000)
    |> unique_fide_id_in_tournament()
  end

  @rating_lists ~w(standard rapid blitz)

  # Blank means "no source", and anything that is not one of the three lists
  # or a YYYY-MM period is dropped rather than stored.
  defp normalize_rating_provenance(changeset) do
    changeset
    |> update_change(:fide_rating_source, fn v -> if v in @rating_lists, do: v end)
    |> update_change(:fide_rating_period, fn v ->
      if PairingsEngine.Fide.period?(v), do: v
    end)
  end

  @doc """
  Whether the FIDE rating was typed or changed by hand (or arrived from
  somewhere that does not say where it came from): no source list on record,
  or the value differs from the one the list printed. A player with no rating
  is not "manual" - there is nothing to describe.
  """
  def rating_manual?(%__MODULE__{fide_rating: r}) when r in [nil, 0], do: false
  def rating_manual?(%__MODULE__{fide_rating_source: nil}), do: true
  def rating_manual?(%__MODULE__{fide_rating: r, fide_rating_listed: l}), do: r != l

  # A physical table number, so it has to be one that can exist: 0 and
  # negatives were accepted and travelled all the way to the printed sheet,
  # the PGN `[Board]` tag and the SWAR HandyTable field. The only guard was
  # the `min="1"` attribute on the Players page input - client-side, and
  # bypassed by a crafted form post or by a JSON import (`fixed_board` is in
  # `TournamentExport`'s `@player_fields`).
  #
  # Deliberately ONLY a lower bound. A `fixed_board` that COLLIDES with an
  # ordinary board number - a hall whose accessible table really is table 1 -
  # is allowed on purpose; the resulting duplicate label is the documented,
  # signed-off output (see `PairingsEngine.PairingDisplay` and
  # `test/pairings_engine/fixed_board_collision_test.exs`, which asserts that
  # duplicate row by row). Rejecting a colliding value here, or checking it
  # against the round's real boards, would reverse that decision.
  # The Players dialog's "Joins in round" box, emptied, means "from the
  # start" - the column is NOT NULL and 1 is what it has always defaulted to.
  defp blank_start_round_is_one(changeset) do
    if get_field(changeset, :start_round) == nil,
      do: put_change(changeset, :start_round, 1),
      else: changeset
  end

  # `period_ratings_text` ("5:1850, 9:1872", `PeriodRatings.parse/1`) is
  # the form's spelling of `period_ratings`; a list given directly (the JSON
  # import) is checked the same way.
  defp normalize_period_ratings(changeset) do
    alias PairingsEngine.PeriodRatings

    case fetch_change(changeset, :period_ratings_text) do
      {:ok, text} ->
        case PeriodRatings.parse(text || "") do
          {:ok, list} ->
            put_change(changeset, :period_ratings, list)

          :error ->
            add_error(
              changeset,
              :period_ratings_text,
              "use round:rating pairs from round 2 on, such as 5:1850, 9:1872"
            )
        end

      :error ->
        case fetch_change(changeset, :period_ratings) do
          {:ok, list} ->
            case PeriodRatings.normalize(list || []) do
              {:ok, list} -> put_change(changeset, :period_ratings, list)
              :error -> add_error(changeset, :period_ratings, "is not a list of round ratings")
            end

          :error ->
            changeset
        end
    end
  end

  defp validate_fixed_board(changeset) do
    validate_number(changeset, :fixed_board, greater_than: 0)
  end

  # `:team_id` is cast (the JSON import needs it - `TournamentImport`
  # remaps every id through its `team_map` and hands the new one here), and
  # `teams` has no tournament column on the `players` foreign key to check
  # it against, so the ownership check has to live here. `update_player/2` is
  # reached from a LiveView form whose params are whatever the browser sent:
  # without this, any team row in the database could be attached to any
  # player. Nothing renders `player.team` today, so this is a fence built
  # before the field is read rather than a fix for a visible bug.
  #
  # Only queried when the value actually changes to something non-nil -
  # clearing a team is always fine, and the ordinary player edit that does
  # not touch the field must not cost a query.
  defp validate_team_in_tournament(changeset) do
    case get_change(changeset, :team_id) do
      nil ->
        changeset

      team_id ->
        tournament_id = get_field(changeset, :tournament_id)

        if PairingsEngine.Repo.exists?(
             from t in PairingsEngine.Tournaments.Team,
               where: t.id == ^team_id and t.tournament_id == ^tournament_id
           ) do
          changeset
        else
          add_error(changeset, :team_id, "must be a team in this tournament")
        end
    end
  end

  # ---------- Absent rounds (SWAR "Absent at the rounds x,y,z") ----------
  #
  # Two functions, one concept, kept next to each other on purpose:
  #
  #   * `parse_absent_rounds_input/1` (the WRITER, below) accepts a
  #     forgiving grammar from the settings form and NORMALIZES it, before
  #     storage, to the strict canonical form every consumer reads: comma-
  #     separated, ascending, unique, plain integers (e.g. "1,2,3,4").
  #   * `parse_absent_rounds/1` (the READER, further down) is what
  #     `PairingsEngine.Pairing` and `PairingsEngine.Keizer` call at pairing
  #     time to turn that back into a list of integers. It used to be a
  #     private, byte-for-byte copy in each of those two modules - two
  #     places that had to be kept in agreement by a comment rather than by
  #     the compiler, which is exactly the shape of bug that has bitten this
  #     project more than once. One rule, one home.
  #
  # Every value THIS changeset writes already satisfies the canonical
  # grammar below, but the reader cannot assume every value already sitting
  # in `players.absent_rounds` was written by it - see `parse_absent_rounds/1`'s
  # own doc for what it does about that.
  #
  # Accepted grammar (see `parse_absent_rounds_input/1` below):
  #   * separators: comma, semicolon, colon, period, and/or whitespace
  #   * ranges: "2-4" (inclusive; reversed ranges like "5-3" are accepted
  #     and normalized ascending)
  #   * any mix of the above, e.g. "2-4;1" => "1,2,3,4"
  defp normalize_absent_rounds(changeset) do
    case fetch_change(changeset, :absent_rounds) do
      :error ->
        changeset

      {:ok, value} ->
        case parse_absent_rounds_input(value) do
          {:ok, canonical} ->
            put_change(changeset, :absent_rounds, canonical)

          :error ->
            add_error(
              changeset,
              :absent_rounds,
              "must be round numbers or ranges, e.g. \"3,5\" or \"2-4\" " <>
                "(comma, semicolon, colon, period and \"-\" ranges are all accepted)"
            )
        end
    end
  end

  # "No pairing-allocated bye": `no_bye_rounds` takes exactly the absent
  # rounds' grammar and is stored in the same canonical form, so one parser
  # serves both. The form's scope choice decides whether rounds are kept:
  # "all" clears them (blank = every round), "rounds" requires some. Turning
  # the exclusion off clears them too, so a stale list cannot come back to
  # life the next time somebody ticks the box.
  defp normalize_no_bye(changeset) do
    changeset =
      case fetch_change(changeset, :no_bye_rounds) do
        {:ok, value} ->
          case parse_absent_rounds_input(to_string(value || "")) do
            {:ok, canonical} ->
              put_change(changeset, :no_bye_rounds, canonical)

            :error ->
              add_error(
                changeset,
                :no_bye_rounds,
                "must be round numbers or ranges, e.g. \"3,5\" or \"2-4\" " <>
                  "(comma, semicolon, colon, period and \"-\" ranges are all accepted)"
              )
          end

        :error ->
          changeset
      end

    cond do
      get_field(changeset, :no_bye) != true ->
        clear_no_bye_rounds(changeset)

      get_field(changeset, :no_bye_scope) == "all" ->
        clear_no_bye_rounds(changeset)

      get_field(changeset, :no_bye_scope) == "rounds" and
          get_field(changeset, :no_bye_rounds) in [nil, ""] ->
        add_error(changeset, :no_bye_rounds, "needs the rounds, e.g. \"3,5\" or \"2-4\"")

      true ->
        changeset
    end
  end

  defp clear_no_bye_rounds(changeset) do
    if get_field(changeset, :no_bye_rounds) in [nil, ""],
      do: changeset,
      else: put_change(changeset, :no_bye_rounds, "")
  end

  @bye_preferences ~w(want_hard want_soft avoid_soft)

  @doc "The stored bye preferences other than none, strongest want first."
  def bye_preferences, do: @bye_preferences

  # The bye preference, by the same rules as `normalize_no_bye/1`: its rounds
  # in the absent rounds' canonical form, cleared when the scope is "all" or
  # the preference is none. And one more, because the two settings live
  # side by side on the form: a player cannot be kept from the bye and want
  # it in the same round - the exclusion would win silently, so the form
  # says so instead.
  defp normalize_bye_preference(changeset) do
    changeset =
      changeset
      |> update_change(:bye_preference, &(&1 || ""))
      |> validate_inclusion(:bye_preference, ["" | @bye_preferences])

    changeset =
      case fetch_change(changeset, :bye_preference_rounds) do
        {:ok, value} ->
          case parse_absent_rounds_input(to_string(value || "")) do
            {:ok, canonical} ->
              put_change(changeset, :bye_preference_rounds, canonical)

            :error ->
              add_error(
                changeset,
                :bye_preference_rounds,
                "must be round numbers or ranges, e.g. \"3,5\" or \"2-4\" " <>
                  "(comma, semicolon, colon, period and \"-\" ranges are all accepted)"
              )
          end

        :error ->
          changeset
      end

    changeset =
      cond do
        get_field(changeset, :bye_preference) in [nil, ""] ->
          clear_bye_preference_rounds(changeset)

        get_field(changeset, :bye_preference_scope) == "all" ->
          clear_bye_preference_rounds(changeset)

        get_field(changeset, :bye_preference_scope) == "rounds" and
            get_field(changeset, :bye_preference_rounds) in [nil, ""] ->
          add_error(
            changeset,
            :bye_preference_rounds,
            "needs the rounds, e.g. \"3,5\" or \"2-4\""
          )

        true ->
          changeset
      end

    validate_bye_settings_agree(changeset)
  end

  defp clear_bye_preference_rounds(changeset) do
    if get_field(changeset, :bye_preference_rounds) in [nil, ""],
      do: changeset,
      else: put_change(changeset, :bye_preference_rounds, "")
  end

  defp validate_bye_settings_agree(changeset) do
    player = %{
      no_bye: get_field(changeset, :no_bye) == true,
      no_bye_rounds: get_field(changeset, :no_bye_rounds) || "",
      bye_preference: get_field(changeset, :bye_preference) || "",
      bye_preference_rounds: get_field(changeset, :bye_preference_rounds) || ""
    }

    case bye_settings_clash(player) do
      nil ->
        changeset

      :all ->
        add_error(
          changeset,
          :bye_preference,
          "cannot want the pairing-allocated bye while excluded from it - " <>
            "untick the exclusion or give the two different rounds"
        )

      rounds ->
        add_error(
          changeset,
          :bye_preference,
          "cannot want the pairing-allocated bye in rounds where it is excluded from it " <>
            "(#{Enum.join(rounds, ", ")})"
        )
    end
  end

  @doc """
  Where a player's "must not get the bye" (`no_bye`) and a WANT for the bye
  overlap: nil when they do not, `:all` when both cover every round, else
  the rounds both name. A soft "rather not" beside an exclusion is only
  redundant, and is not a clash.
  """
  def bye_settings_clash(%{no_bye: true, bye_preference: pref} = player)
      when pref in ["want_hard", "want_soft"] do
    case {player.no_bye_rounds, player.bye_preference_rounds} do
      {a, b} when a in [nil, ""] and b in [nil, ""] ->
        :all

      {a, b} when a in [nil, ""] ->
        parse_absent_rounds(b)

      {a, b} when b in [nil, ""] ->
        parse_absent_rounds(a)

      {a, b} ->
        a |> parse_absent_rounds() |> Enum.filter(&(&1 in parse_absent_rounds(b)))
    end
    |> case do
      [] -> nil
      other -> other
    end
  end

  def bye_settings_clash(_player), do: nil

  @doc """
  The player's bye preference in `round_number` as the engine names it
  (`:want_hard`, `:want_soft`, `:avoid_soft`), or nil - every round when
  `bye_preference_rounds` is blank, else only those rounds. Not a FIDE
  rule; whether the tournament may use it at all is the caller's question.
  """
  def bye_preference_for_round(%{bye_preference: pref} = player, round_number)
      when pref in @bye_preferences do
    rounds = Map.get(player, :bye_preference_rounds)

    applies? =
      if rounds in [nil, ""],
        do: is_integer(round_number),
        else: round_number in parse_absent_rounds(rounds)

    if applies?, do: preference_atom(pref)
  end

  def bye_preference_for_round(_player, _round_number), do: nil

  defp preference_atom("want_hard"), do: :want_hard
  defp preference_atom("want_soft"), do: :want_soft
  defp preference_atom("avoid_soft"), do: :avoid_soft

  @doc """
  Whether `player` must not receive the pairing-allocated bye in
  `round_number` - the organiser's exclusion, which is not a FIDE rule.
  Every round when `no_bye_rounds` is blank, else only those rounds.
  """
  def no_bye_for_round?(%{no_bye: true, no_bye_rounds: rounds}, round_number)
      when rounds in [nil, ""],
      do: is_integer(round_number)

  def no_bye_for_round?(%{no_bye: true, no_bye_rounds: rounds}, round_number),
    do: round_number in parse_absent_rounds(rounds)

  def no_bye_for_round?(_player, _round_number), do: false

  # Max rounds a single range token may expand to - guards against a
  # pathological input (e.g. "1-999999999") ballooning the stored string.
  @max_range_span 1000

  @doc """
  Parses the forgiving "absent at the rounds" grammar into the canonical
  comma-separated ascending-unique form, e.g. `"2-4;1"` => `{:ok, "1,2,3,4"}`.
  Blank input is valid and normalizes to `""`. Returns `:error` for input
  that isn't round numbers/ranges/separators.
  """
  def parse_absent_rounds_input(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, ""}

      trimmed ->
        trimmed
        |> String.split(~r/[,;:.\s]+/, trim: true)
        |> parse_round_tokens([])
    end
  end

  def parse_absent_rounds_input(_), do: :error

  defp parse_round_tokens([], acc) do
    {:ok, acc |> Enum.uniq() |> Enum.sort() |> Enum.join(",")}
  end

  defp parse_round_tokens([token | rest], acc) do
    case parse_round_token(token) do
      {:ok, numbers} -> parse_round_tokens(rest, numbers ++ acc)
      :error -> :error
    end
  end

  defp parse_round_token(token) do
    cond do
      Regex.match?(~r/^\d+$/, token) ->
        {:ok, [String.to_integer(token)]}

      Regex.match?(~r/^\d+-\d+$/, token) ->
        [a, b] = token |> String.split("-") |> Enum.map(&String.to_integer/1)
        {low, high} = if a <= b, do: {a, b}, else: {b, a}

        if high - low + 1 > @max_range_span do
          :error
        else
          {:ok, Enum.to_list(low..high)}
        end

      true ->
        :error
    end
  end

  @doc """
  Parses the canonical "absent at the rounds" storage form (see
  `parse_absent_rounds_input/1` above) into a list of round numbers, e.g.
  `"1,3,5"` => `[1, 3, 5]`. `nil` and `""` both give `[]`.

  This is the READER side: `PairingsEngine.Pairing.absent_for_round?/2` and
  `PairingsEngine.Keizer.excused_absence?/2` both call it at pairing time.
  It used to be a private, byte-for-byte copy of this logic in each of
  those two modules - see the comment above `parse_absent_rounds_input/1`.

  Every value this app ever WRITES to `absent_rounds` already passed
  through `parse_absent_rounds_input/1`, so it cannot reach here malformed.
  But this reads whatever is actually in the column, and not every row got
  there that way - a hand-edited database, or one written by an older build
  with looser (or no) validation, is not bound by today's grammar. So this
  is deliberately tolerant rather than strict: a comma-separated token that
  is not, in its entirety, a plain integer is skipped rather than raised on
  (`String.to_integer/1`'s behaviour, which this used to call directly).
  One corrupted player's `absent_rounds` should cost that player their
  recorded absences, not take down pairing for the whole tournament.
  `parse_absent_rounds_input/1` stays strict - strictness there is what
  keeps new data clean - this is only the read side, where the honest
  choice is "skip the junk" or "crash a pairing run over it".
  """
  def parse_absent_rounds(nil), do: []
  def parse_absent_rounds(""), do: []

  def parse_absent_rounds(rounds) when is_binary(rounds) do
    rounds
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn token ->
      case Integer.parse(String.trim(token)) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

  def parse_absent_rounds(_), do: []

  # Keeps `special_table` (SWAR round-trip compat: HandyTable != 0) in sync
  # with `fixed_board` whenever the caller actually touches `fixed_board`
  # (e.g. the player-edit form always submits it, blank or not). This is the
  # one thing that makes the pair agree, and both halves are load-bearing:
  # `PairingDisplay.special?/1` reads only `fixed_board`, `SwarExport` reads
  # both - so a row with one set and not the other is special in exactly one
  # of the two places. The SWAR importer used to produce precisely that row
  # (boolean from HandyTable, no number); it now sets `fixed_board` from
  # HandyTable and lets this derive the boolean.
  #
  # A writer that sets `special_table` WITHOUT a `fixed_board` key still
  # keeps its own value - the shape a database written by that older
  # importer still holds, and the one `TournamentImport` re-asserts
  # explicitly after the changeset so a backup can restore it verbatim.
  # `categories` is a SET, and two things have to be true of it for
  # `PairingsEngine.Categories.pairing_category/2` to mean what it says.
  #
  # It has to actually be a set: blanks dropped, whitespace trimmed,
  # duplicates collapsed. Nothing downstream counts tags, but a list holding
  # "Women" twice renders the chip twice and exports the name twice, and the
  # cheapest place to make that impossible is before it is stored.
  #
  # And the pairing-pool override has to be IN it. `pairing_category/2`
  # honours `category` only while the player still carries it, which is what
  # stops a stale override from silently pairing someone in a pool the screen
  # does not show - but that rule would also quietly demote every writer that
  # sets `category` alone and knows nothing about tags: an old JSON backup, a
  # `.swar` file, a caller written before this field existed. So a changeset
  # that sets `category` and does NOT set `categories` folds the one into the
  # other. Same shape, and the same reason, as `sync_special_table/1` below:
  # the PRESENCE of the other key in the params is what says whether the
  # writer had an opinion about it.
  #
  # A writer that sets both is left alone in both directions - that is the
  # player dialog, where unticking a category is how an arbiter says the
  # player is no longer in it, and re-adding it here would fight them.
  defp normalize_categories(changeset) do
    changeset =
      case get_change(changeset, :categories) do
        nil ->
          changeset

        categories ->
          put_change(changeset, :categories, normalize_category_list(categories))
      end

    params = changeset.params || %{}
    told_about_tags? = Map.has_key?(params, "categories") or Map.has_key?(params, :categories)
    category = get_change(changeset, :category)

    if not told_about_tags? and is_binary(category) and String.trim(category) != "" do
      existing = get_field(changeset, :categories) || []
      put_change(changeset, :categories, normalize_category_list(existing ++ [category]))
    else
      changeset
    end
  end

  defp normalize_category_list(categories) when is_list(categories) do
    categories
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_category_list(_other), do: []

  defp sync_special_table(changeset) do
    if Map.has_key?(changeset.params || %{}, "fixed_board") do
      put_change(changeset, :special_table, not is_nil(get_field(changeset, :fixed_board)))
    else
      changeset
    end
  end

  # A FIDE ID is an :integer column, and nothing bounded it. A value that
  # parses as a number but is larger than SQLite's signed 64-bit range - a
  # mistyped or pasted string of digits - reached the driver and raised
  # `Exqlite.Error: argument error` on insert, rather than coming back as an
  # ordinary changeset error the form could render.
  #
  # Bounded generously rather than to FIDE's real issuing range: this is a
  # storage guard, not a registry check, and an ID FIDE has not issued yet is
  # still a number this app should be able to hold. 999,999,999 is nine
  # digits, comfortably past the ~8 in use today.
  @max_fide_id 999_999_999

  @doc """
  The largest `fide_id` this app stores.

  Public because `Tournaments.create_player/2`'s duplicate-check query pins
  the value into SQL BEFORE the changeset runs, so it has to apply the same
  bound or the driver raises on an oversized number first.
  """
  def max_fide_id, do: @max_fide_id

  defp validate_fide_id_range(changeset) do
    validate_number(changeset, :fide_id,
      greater_than: 0,
      less_than_or_equal_to: @max_fide_id
    )
  end

  defp unique_fide_id_in_tournament(changeset) do
    unique_constraint(changeset, :fide_id, name: :players_tournament_id_fide_id_index)
  end

  @doc """
  The FIDON rating: FIDE first, national as fallback - `rating/2` under the
  default method, for a caller with no tournament in hand. Where the
  tournament is known, `rating(player, tournament)` is the one that ranks.
  """
  def rating(%__MODULE__{} = player), do: rating(player, "FIDON")

  @doc """
  The player's Tournament Rating under `method` - a `%Tournament{}` (its
  `rating_method`) or the method itself - always an integer, 0 for none.

  The methods are TRF26 record 172's (VCL4THP Q145):

    * `"FIDE"` - the FIDE rating only (the stored one is already the list
      for the tournament's rate of play, see `PairingsEngine.Fide`).
    * `"NRO"` - the national rating only.
    * `"FIDON"` - FIDE, the national one for a player without. The default,
      and what this app always did.
    * `"NIDOF"` - national, the FIDE one for a player without.
    * `"HBFN"` - the highest of FIDE, national and the hand-typed
      `tournament_rating`.
    * `"OTHER"` - the hand-typed `tournament_rating` alone: the arbiter's
      own figure, the C.04.2 2.1 estimate for a player with no reliable
      rating included.

  An unknown or missing method reads as FIDON, so a struct built without the
  column (an older file, a hand-made test struct) ranks as it always did.
  """
  def rating(%__MODULE__{} = player, %{rating_method: method}), do: rating(player, method)

  def rating(%__MODULE__{} = player, method) do
    # Coerce nils to 0 first: a `nil` rating field (a raw/partial insert that
    # bypassed the schema's `default: 0`) would otherwise make `f > 0` return
    # `nil` - in Elixir's term ordering `nil > 0` is `true` - and returning
    # `nil` here crashes every `-Player.rating(p)` sort key downstream.
    f = player.fide_rating || 0
    n = player.national_rating || 0
    manual = Map.get(player, :tournament_rating) || 0

    case method do
      "FIDE" -> f
      "NRO" -> n
      "NIDOF" -> if n > 0, do: n, else: f
      "HBFN" -> Enum.max([f, n, manual])
      "OTHER" -> manual
      _fidon -> if f > 0, do: f, else: n
    end
  end

  # C.04.2 2.2.2: "FIDE-title (GM-IM-WGM-FM-WIM-CM-WFM-WCM-no title), for
  # individual tournaments". Stored as the TRF-style uppercase code; the
  # TRF's own one- and two-letter forms (g, i, wg, f, wi, c, wf, wc) are read
  # too, since an import can carry either.
  @title_order %{
    "GM" => 0,
    "G" => 0,
    "IM" => 1,
    "I" => 1,
    "WGM" => 2,
    "WG" => 2,
    "FM" => 3,
    "F" => 3,
    "WIM" => 4,
    "WI" => 4,
    "CM" => 5,
    "C" => 5,
    "WFM" => 6,
    "WF" => 6,
    "WCM" => 7,
    "WC" => 7
  }

  @doc """
  Where the player's FIDE title puts them in C.04.2 2.2.2's order - 0 for a
  GM, 8 for no title (or one that is not a FIDE playing title).
  """
  def title_rank(%{title: title}) when is_binary(title),
    do: Map.get(@title_order, title |> String.trim() |> String.upcase(), 8)

  def title_rank(_player), do: 8

  @doc """
  Display label for `sex`: stored internally as "m"/"w" (see
  `PairingsEngineWeb.PlayersLive.normalize_fide_sex/1`, matching
  `Ainalrami.Trf`'s own `trf_sex/1` export convention), shown as FIDE's own
  capital letters "M"/"F". Blank/unset renders as an empty string, letting
  callers decide their own placeholder ("-", "" etc).
  """
  def sex_label("m"), do: "M"
  def sex_label("w"), do: "F"
  def sex_label(_), do: ""
end
