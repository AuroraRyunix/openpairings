defmodule PairingsEngine.Kbsb.KbsbPlayer do
  use Ecto.Schema

  # Belgian national IDs ("matricule") are printed with leading zeros in some
  # club exports, so they're kept as strings — same treatment as
  # `PairingsEngine.Tournaments.Player.national_id`.
  @primary_key {:national_id, :string, autogenerate: false}
  schema "kbsb_players" do
    field :last_name, :string
    field :first_name, :string, default: ""
    field :national_rating, :integer
    field :fide_id, :integer
    field :club_number, :integer
    field :club_name, :string, default: ""
    field :federation, :string, default: ""
    field :birth_year, :integer

    # Only set by the data-platform API sync, which mirrors the roster
    # unfiltered (see the AddKbsbPlayerStatusFlags migration). `nil` on
    # every row that came from an uploaded file, which carries neither.
    field :died, :boolean
    field :affiliated, :boolean
  end

  @doc "Combined \"Lastname, Firstname\" display name, matching the FIDE list convention."
  def full_name(%__MODULE__{last_name: last, first_name: ""}), do: last
  def full_name(%__MODULE__{last_name: last, first_name: first}), do: "#{last}, #{first}"
end
