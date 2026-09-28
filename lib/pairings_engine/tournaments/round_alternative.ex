defmodule PairingsEngine.Tournaments.RoundAlternative do
  @moduledoc """
  One "why him and not me" answer of a round, worked out when somebody
  first opened it on the explanation page (`PairingsEngine.Pairing.open_alternative/4`).

    * `job` - the fingerprint of the round's account it belongs to
      (`rounds.explanation["job"]`). A round paired afresh has another, so
      an answer about an earlier pairing is never read as one about this.
    * `question` - `"bye/<section>"` or `"float/<section>/<bracket>/<player id>"`,
      the indexes those of the stored account's sections and brackets.
    * `result` - the answer in the stored account's JSON shape (player ids,
      as `PairingsEngine.RoundExplanation` reads it).

  Written only by `PairingsEngine.ExplanationJobs.store_alternative/4`.
  """
  use Ecto.Schema

  schema "round_alternatives" do
    belongs_to :round, PairingsEngine.Tournaments.Round
    field :job, :string
    field :question, :string
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
