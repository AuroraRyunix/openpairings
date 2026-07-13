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
      :pairing_system, :rr_cycles, :keizer_top_value
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
    |> validate_number(:rounds_count, greater_than: 0, less_than_or_equal_to: 30)
    |> validate_keizer_top_value()
    |> put_public_slug()
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

  def types, do: @types

  def type_label("swiss"), do: "Swiss (individual)"
  def type_label("roundrobin"), do: "Round robin (individual)"
  def type_label("team-swiss"), do: "Swiss (teams)"
  def type_label("team-roundrobin"), do: "Round robin (teams)"
  def type_label(other), do: other

  def pairing_systems, do: @pairing_systems
  def rr_cycles_values, do: @rr_cycles_values

  def pairing_system_label("swiss"), do: "Swiss — FIDE Dutch (JaVaFo)"
  def pairing_system_label("round_robin"), do: "Round robin (Berger)"
  def pairing_system_label("keizer"), do: "Keizer"
  def pairing_system_label(other), do: other

  def rr_cycles_label(1), do: "Single"
  def rr_cycles_label(2), do: "Double"
  def rr_cycles_label(other), do: to_string(other)
end
