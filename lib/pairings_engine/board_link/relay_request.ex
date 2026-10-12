defmodule PairingsEngine.BoardLink.RelayRequest do
  @moduledoc """
  Where one tournament stands with the results site about its hall box's
  permission to send moves there. See `PairingsEngine.BoardLink.RelayKeys`,
  which is the only thing that writes it.

  `state`:

    * `"held"` - a key was fetched (`obtained_at`, for the address `slug`)
      and is in `tournaments.openresults_relay_key`;
    * `"wanted"` - asked and not answered: unreachable, busy, not there yet.
      Asked again by itself at `next_attempt_at`;
    * `"refused"` - the site said no, and `reason` is its code. Asked again
      rarely by itself, and at once when the arbiter says so.

  `replace` is the arbiter asking for a new key while one is held.

  The key is not here. It is in no export either, and neither is this.
  """
  use Ecto.Schema

  schema "board_relay_requests" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    field :state, :string, default: "wanted"
    field :reason, :string
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :obtained_at, :utc_datetime
    field :slug, :string
    field :replace, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
