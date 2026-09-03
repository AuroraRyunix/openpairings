defmodule PairingsEngine.Federations.BEL.Member do
  @moduledoc """
  One row of the local mirror of the KBSB/FRBE member list.

  ## The table is called `kbsb_players` and stays called `kbsb_players`

  The module moved here from `PairingsEngine.Kbsb.KbsbPlayer` when the
  Belgian code was gathered into its own namespace. The table did not move
  with it, and should not: renaming a table is a data migration - it rewrites
  every deployed database, invalidates the `kbsb_players_fts` index and its
  triggers, and buys nobody anything they can see. A schema module is allowed
  to name a table that is spelled differently from itself, and this one does,
  on purpose. Please leave it.
  """

  use Ecto.Schema

  # Belgian national IDs ("matricule") are printed with leading zeros in some
  # club exports, so they're kept as strings - same treatment as
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
