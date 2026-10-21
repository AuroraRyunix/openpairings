defmodule PairingsEngine.Mobile.Submission do
  @moduledoc """
  The answer the server gave one queued entry from a phone, kept under the
  phone's own id for it (`client_id`) - see `PairingsEngine.Mobile.Sync`.

  Only FINAL answers are kept (`"saved"` or `"refused"`). A `"retry"` is
  not an answer, it is "ask again later", and keeping it would turn a rate
  limit into a permanent refusal.
  """
  use Ecto.Schema

  schema "mobile_submissions" do
    field :client_id, :string
    field :kind, :string
    field :status, :string
    field :reason, :string, default: ""
    field :board, :integer

    belongs_to :enrollment, PairingsEngine.Mobile.Enrollment

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
