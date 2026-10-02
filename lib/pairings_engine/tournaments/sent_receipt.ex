defmodule PairingsEngine.Tournaments.SentReceipt do
  @moduledoc """
  One send of a round's report, or of a postponed-games file: the proof of
  exactly what went to the rating officer. See the migration and
  `PairingsEngine.SentReceipts`. It guards nothing - the sent-games record
  (`TrfSentGame`) does - and, like that record, a restore never touches it.
  """
  use Ecto.Schema

  schema "trf_sent_receipts" do
    field :kind, :string
    field :round, :integer
    field :period, :date
    field :code, :string
    field :fingerprint, :string
    field :file_sha256, :string
    field :final_sha256, :string
    field :games, {:array, :map}
    field :status, :string, default: "receipt"
    field :origin, :string, default: "sent"
    field :sent_at, :utc_datetime
    field :sent_by, :string
    field :sent_by_id, :integer

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
  end
end
