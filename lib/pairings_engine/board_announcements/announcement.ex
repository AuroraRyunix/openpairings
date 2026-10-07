defmodule PairingsEngine.BoardAnnouncements.Announcement do
  @moduledoc """
  The boards of one round, not yet paired, whose name cards the arbiter put
  out early - see `PairingsEngine.BoardAnnouncements`.

  `base` and `round_results` are the state of the data the boards were
  certain for (`PairingsEngine.NextRoundPreview.base_state/2`):
  `round_results` keyed by pairing id as a string, the way JSON stores it.
  `acknowledged_round_id` is the paired round whose differences from the
  announcement the arbiter has seen; a round unpaired and paired again has
  a new id, so its differences are shown again.
  """
  use Ecto.Schema

  schema "board_announcements" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    field :round, :integer
    field :base, :binary
    field :round_results, :map, default: %{}
    field :acknowledged_round_id, :integer

    has_many :boards, PairingsEngine.BoardAnnouncements.AnnouncedBoard,
      foreign_key: :announcement_id

    timestamps(type: :utc_datetime)
  end
end
