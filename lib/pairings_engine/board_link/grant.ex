defmodule PairingsEngine.BoardLink.Grant do
  @moduledoc """
  The one-time ticket of the connect flow (`PairingsEngine.BoardLink.connect/2`,
  docs/board-link-api.md, "Connecting an account"): what the browser carries
  from the consent page back to the box, and what the box trades, once, for
  the account code it stands for.

  Two minutes, one use. `grant_hash` is a SHA-256 of the grant; `sealed` is
  the code's secret under AES-256-GCM with a key derived from the grant
  itself, so a copy of this table opens nothing without the grant, and the
  grant is gone from here the moment it is used.
  """
  use Ecto.Schema

  schema "board_link_grants" do
    field :grant_hash, :string
    field :sealed, :binary, redact: true
    field :expires_at, :utc_datetime

    belongs_to :link, PairingsEngine.BoardLink.Link

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
