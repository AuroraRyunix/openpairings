defmodule PairingsEngine.Federations.BEL.Club do
  @moduledoc """
  One row of `kbsb_clubs`: a club number and the name last learned for it.

  Separate table from `kbsb_players` on purpose - see
  `PairingsEngine.Federations.BEL.Clubs`'s moduledoc for why it survives a
  full player-roster replace instead of being wiped alongside it.
  """

  use Ecto.Schema

  @primary_key {:club_number, :integer, autogenerate: false}
  schema "kbsb_clubs" do
    field :name, :string
  end
end
