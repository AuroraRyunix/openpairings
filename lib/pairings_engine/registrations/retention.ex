defmodule PairingsEngine.Registrations.Retention do
  @moduledoc """
  Forgets entrants' email addresses once their tournament is well over.

  The email in a pulled registration exists for one reason
  (`PairingsEngine.Registrations`, "The email address"): so the arbiter can
  reach the person - to say they are in, that the field is full, that a round
  moved. Every one of those conversations happens before or during the event.
  A month after its last day there is nothing left to tell an entrant, and the
  address is just personal data sitting in a table and in every backup.

  So `run/1` sets `payload["player"]["email"]` to `nil` on every registration
  of a tournament whose `end_date` is at least
  `PAIRINGS_REGISTRATION_RETENTION_DAYS` (30 by default) in the past. Nothing
  else in the row changes: the name, the decision and the rest of the payload
  are the arbiter's record of who asked to play, and `external_key` is
  already stored, so a later pull still recognises the entry and does not
  bring the address back.

  A tournament with a blank `end_date` is never touched - there is no way to
  tell whether it is over - and neither is one that ends in the future.
  """

  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.Tournament

  @default_days 30

  @doc """
  Clears the email of every registration past retention, and returns how many
  rows were changed. `now` is for tests.
  """
  @spec run(DateTime.t()) :: non_neg_integer()
  def run(now \\ DateTime.utc_now()) do
    cutoff = now |> DateTime.to_date() |> Date.add(-days()) |> Date.to_iso8601()

    # `end_date` is ISO `YYYY-MM-DD`, so string order is date order.
    Repo.all(
      from r in Registration,
        join: t in Tournament,
        on: t.id == r.tournament_id,
        where: t.end_date != "" and t.end_date <= ^cutoff
    )
    |> Enum.filter(&has_email?/1)
    |> Enum.reduce(0, fn registration, cleared ->
      player = Map.put(Registration.player_data(registration), "email", nil)

      registration
      |> Ecto.Changeset.change(payload: Map.put(registration.payload, "player", player))
      |> Repo.update!()

      cleared + 1
    end)
  end

  @doc "How many days after a tournament ends its entrants' emails are kept."
  @spec days() :: pos_integer()
  def days do
    case Application.get_env(:pairings_engine, :registration_retention_days, @default_days) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_days
    end
  end

  defp has_email?(%Registration{} = registration),
    do: not is_nil(Map.get(Registration.player_data(registration), "email"))
end
