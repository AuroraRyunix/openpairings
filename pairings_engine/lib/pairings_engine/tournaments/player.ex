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
      :absent_rounds, :extra_points, :category, :club_number, :norm_data
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:status, ~w(active withdrawn))
    |> validate_inclusion(:paid, @paid_statuses)
    |> validate_number(:extra_points, greater_than_or_equal_to: 0.0)
    |> validate_format(:absent_rounds, ~r/^$|^\d+(,\d+)*$/,
      message: "must be a comma-separated list of round numbers"
    )
    |> unique_fide_id_in_tournament()
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
