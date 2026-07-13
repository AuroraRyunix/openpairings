defmodule PairingsEngine.Tournaments.Player do
  use Ecto.Schema
  import Ecto.Changeset

  @paid_statuses ~w(nopaid paid gratis)

  schema "players" do
    field :name, :string
    field :sex, :string, default: ""
    field :title, :string, default: ""
    field :fide_id, :integer
    field :fide_rating, :integer, default: 0
    field :national_id, :string, default: ""
    field :national_rating, :integer, default: 0
    field :federation, :string, default: ""
    field :birth_year, :integer
    field :club, :string, default: ""
    field :status, :string, default: "active"
    field :start_round, :integer, default: 1
    field :board_order, :integer
    field :pairing_number, :integer

    # nopaid | paid | gratis (SWAR §5.20)
    field :paid, :string, default: "paid"
    # SWAR Aff. (§5.21)
    field :affiliated, :boolean, default: true
    # SWAR Absent checkbox — player not paired at all while set
    field :absent, :boolean, default: false
    # SWAR Forfeit — player withdrawn/forfeited out
    field :forfeit, :boolean, default: false
    # Fixed-table accommodation (SWAR HandyTable) — informational only
    field :special_table, :boolean, default: false
    # Comma-separated round numbers, e.g. "3,5"
    field :absent_rounds, :string, default: ""
    # SWAR XtPts
    field :extra_points, :float, default: 0.0
    # SWAR player category
    field :category, :string, default: ""
    # SWAR N° Club (club NAME stays in `club`)
    field :club_number, :integer

    # Per-player title-norm judgment data for the IT4 report — recognised
    # string keys (all optional; a blank/missing "title_claimed" means this
    # player isn't currently an IT4 candidate):
    #
    #   title_claimed       — target title being claimed, e.g. "IM" (IT4 W11)
    #   norm_description    — free text, e.g. "IM norm" (IT4 Y11)
    #   medal_percent       — free text/numeric, e.g. "62.5%" (IT4 U11)
    #   remarks             — free text (IT4 AB11)
    #   event_group         — e.g. "U20, Women" (IT4 P11)
    #   fed_participating   — number of federations participating (IT4 R11)
    #   fed_members         — number of federations eligible (IT4 S11)
    field :norm_data, :map, default: %{}

    # Full date of birth when known (TRF wants YYYY/MM/DD); birth_year is the
    # year-only fallback. Keep both in sync where possible.
    field :birth_date, :date

    # Physical table override (SWAR "special table"): this player's games are
    # displayed/printed at this table number. nil = normal board numbering.
    field :fixed_board, :integer

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :team, PairingsEngine.Tournaments.Team

    timestamps(type: :utc_datetime)
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :name, :sex, :title, :fide_id, :fide_rating, :national_id,
      :national_rating, :federation, :birth_year, :club, :status,
      :start_round, :team_id, :board_order, :pairing_number,
      :paid, :affiliated, :absent, :forfeit, :special_table,
      :absent_rounds, :extra_points, :category, :club_number, :norm_data,
      :birth_date, :fixed_board
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:status, ~w(active withdrawn))
    |> validate_inclusion(:paid, @paid_statuses)
    |> validate_number(:extra_points, greater_than_or_equal_to: 0.0)
    |> normalize_absent_rounds()
    |> sync_special_table()
    |> unique_fide_id_in_tournament()
  end

  # ---------- Absent rounds (SWAR "Absent at the rounds x,y,z") ----------
  #
  # The form accepts a forgiving grammar and this step NORMALIZES it, before
  # storage, to the strict canonical form every consumer parses:
  # comma-separated, ascending, unique, plain integers (e.g. "1,2,3,4"). Do
  # not change `parse_absent_rounds/1` in `PairingsEngine.Pairing` or
  # `PairingsEngine.Keizer` to understand the forgiving grammar — they only
  # ever see the canonical form produced here.
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

  # Max rounds a single range token may expand to — guards against a
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

  # Keeps `special_table` (SWAR round-trip compat: HandyTable != 0) in sync
  # with `fixed_board` whenever the caller actually touches `fixed_board`
  # (e.g. the player-edit form always submits it, blank or not). Other
  # writers — notably the SWAR importer, which sets `special_table` directly
  # from HandyTable without going through `fixed_board` at all — never
  # include `fixed_board` in their attrs, so this leaves their value alone.
  defp sync_special_table(changeset) do
    if Map.has_key?(changeset.params || %{}, "fixed_board") do
      put_change(changeset, :special_table, not is_nil(get_field(changeset, :fixed_board)))
    else
      changeset
    end
  end

  defp unique_fide_id_in_tournament(changeset) do
    # Enforced at the context level (needs tournament scope); placeholder for
    # schema-level validations that don't require a query.
    changeset
  end

  @doc "Rating used for sorting/pairing display: FIDE first, national as fallback."
  def rating(%__MODULE__{fide_rating: f, national_rating: n}) do
    if f > 0, do: f, else: n
  end
end
