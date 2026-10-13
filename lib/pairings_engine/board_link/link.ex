defmodule PairingsEngine.BoardLink.Link do
  @moduledoc """
  One connect code for a hall box (`PairingsEngine.BoardLink`): for one
  tournament (`tournament_id`) or for one tournament group (`group_id`),
  exactly one of the two.

  `secret_hash` is the SHA-256 of the secret the box presents, in lowercase
  hex. The secret itself is shown once, when the code is made, and is not
  kept: this side only ever checks it. `secret_hint` is its last four
  characters, so two codes can be told apart on the settings page.

  `created_by_id` is who made the code, and for a group code it is more than
  a record: the code reaches the members of the group its maker may open,
  and no others (see `PairingsEngine.BoardLink.covered/1`).

  `reach` is `"lan"` for a code a desktop copy made for a box elsewhere on
  the hall network (`PairingsEngineWeb.BoardLan`), nil for every other code.
  Such a code carries the `address` it was made with and an `expires_at`
  that is nil for a new code: it works until it is withdrawn. A row that has
  a date is still refused after it.
  Only a `"lan"` code is accepted on the network listener.

  `last_seen_at`, `box_name`, `box_version` and `box_boards` are what the box
  said about itself the last time it called. Nothing here trusts them; they
  are for the arbiter looking at the settings page.
  """
  use Ecto.Schema

  schema "board_links" do
    field :secret_hash, :string
    field :secret_hint, :string
    field :last_seen_at, :utc_datetime
    field :box_name, :string
    field :box_version, :string
    field :box_boards, :map
    field :reach, :string
    field :address, :string
    field :expires_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :group, PairingsEngine.TournamentGroups.Group
    belongs_to :created_by, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
