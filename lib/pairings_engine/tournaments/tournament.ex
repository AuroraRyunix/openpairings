defmodule PairingsEngine.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(swiss roundrobin team-swiss team-roundrobin)
  @rating_types ~w(fide national none)
  @accelerations ~w(none baku)
  @statuses ~w(setup running finished)
  @standards ~w(standard rapid blitz)
  # Which pairing engine PairingsEngine.Pairing.pair_next_round/1 dispatches
  # to — independent of `type` above (FIDE report classification).
  @pairing_systems ~w(swiss round_robin keizer)
  @rr_cycles_values [1, 2]
  # Club/federation pairing-exclusion rules (SWAR parity #7-10) — see
  # PairingsEngine.Exclusions and docs/forbidden-pairings.md.
  @exclusion_modes ~w(none all listed)

  schema "tournaments" do
    field :name, :string
    field :type, :string, default: "swiss"
    field :venue, :string, default: ""
    field :city, :string, default: ""
    field :federation, :string, default: ""
    field :start_date, :string, default: ""
    field :end_date, :string, default: ""
    field :organizer, :string, default: ""
    field :chief_arbiter, :string, default: ""
    field :deputy_arbiter, :string, default: ""
    field :time_control, :string, default: ""
    field :rounds_count, :integer, default: 9
    field :rating_type, :string, default: "fide"
    field :points_win, :float, default: 1.0
    field :points_draw, :float, default: 0.5
    field :points_loss, :float, default: 0.0
    field :bye_value, :float, default: 1.0
    field :tiebreaks, {:array, :string}, default: []
    field :acceleration, :string, default: "none"
    field :status, :string, default: "setup"

    # standard | rapid | blitz (SWAR TournoiStd)
    field :standard, :string, default: "standard"
    field :rate_of_play, :string, default: ""
    field :organizer_club_number, :string, default: ""
    # ISO dates, index = round-1
    field :round_dates, {:array, :string}, default: []
    # tournament-defined category names (SWAR CATEGORIES)
    field :categories, {:array, :string}, default: []

    # FIDE "Code of event" (FA1/IA1 B6, IT4 S4 "FIDE Event code")
    field :event_code, :string, default: ""
    # FIDE "ID of Tournament" (IT3 B2) — the report's own numeric ID
    field :fide_tournament_id, :string, default: ""

    # Officials / pairing-system / FIDE-report metadata that doesn't
    # warrant its own column each — recognised string keys (all optional,
    # blank/missing means "not set"):
    #
    #   organizer_id, organizer_email            — IT3 B8/B10
    #   chief_arbiter_fide_id, chief_arbiter_email — IT3 B59/B61, FA1/IA1 B18
    #   deputyN_name, deputyN_fide_id, deputyN_email (N in 1..4) — IT3 B62-B69
    #   pairing_mode                             — "computerized" | "manual" (IT3 B19/B21)
    #   pairing_program                          — IT3 B22
    #   swiss_variant                            — "Dutch" | "Lim" | "Dubov" | "Burstein" (IT3 B17)
    #   person_responsible_pairings              — IT3 B20
    #   remark1..remark4                         — IT3 B23-B26 (free text)
    #   it4_event_type                           — IT4 S6 "Event type"
    #   pairings_web_link                        — IT4 Y4 "Link to pairings web"
    field :officials, :map, default: %{}

    # Unguessable token for the public (no-login) read-only pages — see
    # docs/public-pages.md. Deliberately not the numeric `id`, which is
    # sequential and easy to enumerate. Always set (never nil) — see
    # `put_public_slug/1` below, applied by every creation path.
    field :public_slug, :string

    # Pairing engine dispatch (see PairingsEngine.Pairing.pair_next_round/1):
    # "swiss" | "round_robin" | "keizer". Locked in the UI once the
    # tournament has paired its first round (see SettingsLive).
    field :pairing_system, :string, default: "swiss"
    # Round-robin only: 1 = single cycle, 2 = double.
    field :rr_cycles, :integer, default: 1
    # Keizer only: nil means "automatic" (2 x player count), computed by
    # PairingsEngine.Keizer.
    field :keizer_top_value, :integer

    # Club/federation pairing exclusions (SWAR parity #7-10) — arbiters
    # often must avoid pairing clubmates / same-federation players
    # together. "none" | "all" | "listed" — "listed" restricts the rule to
    # the comma-separated names in the matching `_list` field. Translated
    # into forbidden pairs at pairing time by PairingsEngine.Exclusions;
    # respected by Swiss (JaVaFo XXP lines) and Keizer, ignored by round
    # robin's fixed schedule by design — see docs/forbidden-pairings.md.
    field :club_exclusion, :string, default: "none"
    field :club_exclusion_list, :string, default: ""
    field :fed_exclusion, :string, default: "none"
    field :fed_exclusion_list, :string, default: ""

    # Extra points (SWAR parity #12, "XtPts") — see docs/extra-points.md.
    # `players.extra_points` (administrative bonus points) already exists,
    # but an explicit earlier product decision keeps standings from counting
    # it by default — this flag is the opt-in, per tournament, always
    # starting off. `extra_points_bands` is the Elo-band auto-assign rule:
    # a comma-separated "threshold:bonus" string, e.g. "1400:1, 1600:0.5"
    # (rating below 1400 gets 1.0, below 1600 gets 0.5) — see
    # `parse_extra_points_bands/1` and `band_extra_points/2` below for exact
    # matching semantics. Never applied automatically; only
    # `PairingsEngine.Tournaments.apply_extra_points_bands/1`, triggered
    # explicitly from Settings, writes it into players' `extra_points`.
    field :count_extra_points, :boolean, default: false
    field :extra_points_bands, :string, default: ""

    # When true, the Categories tab (category management + extra-points
    # admin) is shown in the top bar — see CategoriesLive. Off by default
    # so the tab only appears for tournaments that actually use categories.
    field :categories_enabled, :boolean, default: false

    # Soft-delete timestamp for the recycle bin (docs: recycle bin). nil =
    # live tournament; set = in the bin, auto-purged 3 months later. Managed
    # by PairingsEngine.Tournaments.soft_delete/restore/purge — deliberately
    # NOT cast by changeset/2 so ordinary saves can't touch it.
    field :deleted_at, :utc_datetime

    belongs_to :user, PairingsEngine.Accounts.User
    has_many :players, PairingsEngine.Tournaments.Player
    has_many :teams, PairingsEngine.Tournaments.Team
    has_many :rounds, PairingsEngine.Tournaments.Round

    timestamps(type: :utc_datetime)
  end

  def changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [
      :name, :type, :venue, :city, :federation, :start_date, :end_date,
      :organizer, :chief_arbiter, :deputy_arbiter, :time_control,
      :rounds_count, :rating_type, :points_win, :points_draw, :points_loss,
      :bye_value, :tiebreaks, :acceleration, :status,
      :standard, :rate_of_play, :organizer_club_number, :round_dates, :categories,
      :event_code, :fide_tournament_id, :officials,
      :pairing_system, :rr_cycles, :keizer_top_value,
      :club_exclusion, :club_exclusion_list, :fed_exclusion, :fed_exclusion_list,
      :count_extra_points, :extra_points_bands, :categories_enabled
    ])
    |> validate_required([:name, :type, :rounds_count])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:rating_type, @rating_types)
    |> validate_inclusion(:acceleration, @accelerations)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:standard, @standards)
    |> validate_inclusion(:pairing_system, @pairing_systems)
    |> validate_inclusion(:rr_cycles, @rr_cycles_values)
    |> validate_inclusion(:club_exclusion, @exclusion_modes)
    |> validate_inclusion(:fed_exclusion, @exclusion_modes)
    |> validate_number(:rounds_count, greater_than: 0, less_than_or_equal_to: 30)
    |> validate_keizer_top_value()
    |> normalize_exclusion_list(:club_exclusion_list)
    |> normalize_exclusion_list(:fed_exclusion_list)
    |> normalize_extra_points_bands()
    |> put_public_slug()
  end

  # Trims each comma-separated entry and drops blanks, storing back in the
  # same comma-separated shape ("Club A, Club B") — keeps the stored value
  # tidy regardless of how the arbiter typed it (extra spaces, trailing
  # commas, ...). Runs before validate_inclusion has any bearing on this
  # field (there is none — free text), so it's safe unconditionally.
  defp normalize_exclusion_list(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        normalized = value |> PairingsEngine.Exclusions.normalize_list() |> Enum.join(", ")
        put_change(changeset, field, normalized)
    end
  end

  # `keizer_top_value` is nullable (nil means "automatic") — only validate
  # it when an organiser has actually set it, so clearing the field back to
  # blank/automatic never fails validation.
  defp validate_keizer_top_value(changeset) do
    case get_field(changeset, :keizer_top_value) do
      nil -> changeset
      _ -> validate_number(changeset, :keizer_top_value, greater_than: 0)
    end
  end

  # Re-parses and re-normalizes `extra_points_bands` on every write (like the
  # exclusion lists above), storing back the canonical
  # "threshold:bonus, threshold:bonus" shape sorted ascending by threshold —
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
              |> Enum.map_join(", ", fn {threshold, bonus} -> "#{threshold}:#{format_bonus(bonus)}" end)

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

  @doc """
  Parses `extra_points_bands`'s stored/typed shape — a comma-separated list
  of `"threshold:bonus"` pairs, e.g. `"1400:1, 1600:0.5"` — into
  `{:ok, [{threshold :: non_neg_integer(), bonus :: float()}]}`, or `:error`
  for anything that doesn't match (wrong shape, negative numbers, ...).
  Blank/whitespace-only input parses to `{:ok, []}`.
  """
  @spec parse_extra_points_bands(String.t() | nil) :: {:ok, [{non_neg_integer(), float()}]} | :error
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
      Among those, the **lowest-threshold** band wins — the most selective
      band, which is also the most generous one when bands are configured
      the expected way (lower threshold = bigger bonus for the
      lowest-rated players). A player at or above every threshold matches
      no band and gets `0.0`.
    * An unrated player (`rating == 0`) never matches a `rating < threshold`
      comparison (0 isn't below anything), so they only get a bonus when
      `bands` has an explicit `0:bonus` entry — an arbiter opt-in to give
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

  # Every tournament must always have a `public_slug` — this is the single
  # choke point all creation paths go through (the UI's "New tournament"
  # form, the SWAR importer, and the JSON tournament importer all call
  # `changeset/2`), so none of them need to generate one themselves. Only
  # fills it in when missing, so updating an existing tournament never
  # rotates its public link.
  defp put_public_slug(changeset) do
    if get_field(changeset, :public_slug) do
      changeset
    else
      slug = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
      put_change(changeset, :public_slug, slug)
    end
  end

  @doc """
  The fields an arbiter must fill before a tournament is workable — a name,
  a start date and a round count. Until all three are present, players
  can't be added and pairing can't start (see the guards in PlayersLive /
  PairingsLive), and their labels are shown bold in Settings.
  """
  def required_setup_fields, do: [:name, :start_date, :rounds_count]

  @doc """
  Whether `tournament` has all `required_setup_fields/0` filled in.
  """
  def setup_complete?(%__MODULE__{} = t) do
    present?(t.name) and present?(t.start_date) and
      is_integer(t.rounds_count) and t.rounds_count >= 1
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
  def rr_cycles_values, do: @rr_cycles_values
  def exclusion_modes, do: @exclusion_modes

  def exclusion_mode_label("none"), do: "None"
  def exclusion_mode_label("all"), do: "All shared clubs/federations"
  def exclusion_mode_label("listed"), do: "Only listed"
  def exclusion_mode_label(other), do: other

  def pairing_system_label("swiss"), do: "Swiss — FIDE Dutch (JaVaFo)"
  def pairing_system_label("round_robin"), do: "Round robin (Berger)"
  def pairing_system_label("keizer"), do: "Keizer"
  def pairing_system_label(other), do: other

  def rr_cycles_label(1), do: "Single"
  def rr_cycles_label(2), do: "Double"
  def rr_cycles_label(other), do: to_string(other)
end
