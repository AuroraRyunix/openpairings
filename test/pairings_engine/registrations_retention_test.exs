defmodule PairingsEngine.RegistrationsRetentionTest do
  @moduledoc """
  An entrant's email is kept while there is still something to tell them,
  and cleared once their tournament is well over - and nothing else in the
  row goes with it.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Repo
  alias PairingsEngine.Registrations.{Registration, Retention}
  alias PairingsEngine.Tournaments.Tournament

  @now ~U[2026-09-13 12:00:00Z]

  setup do
    Application.delete_env(:pairings_engine, :registration_retention_days)
    on_exit(fn -> Application.delete_env(:pairings_engine, :registration_retention_days) end)
    :ok
  end

  defp registration(end_date) do
    tournament =
      Repo.insert!(%Tournament{
        name: "Retention Open",
        type: "swiss",
        rounds_count: 5,
        public_slug: "ret-#{System.unique_integer([:positive])}",
        end_date: end_date
      })

    Repo.insert!(%Registration{
      tournament_id: tournament.id,
      external_key: "id:#{System.unique_integer([:positive])}",
      received_at: ~U[2026-01-01 09:00:00.000000Z],
      status: "discarded",
      decided_at: ~U[2026-01-02 09:00:00.000000Z],
      payload: %{
        "schema" => "openresults/registration",
        "player" => %{"name" => "Ilse Peeters", "email" => "ilse@example.org", "rating" => 1804}
      }
    })
  end

  defp reload(registration), do: Repo.get!(Registration, registration.id)

  test "a tournament that ended long enough ago loses the email, and only the email" do
    old = registration("2026-08-01")

    assert Retention.run(@now) == 1

    fresh = reload(old)
    assert Registration.email(fresh) == nil
    assert fresh.payload["player"]["email"] == nil
    assert fresh.payload["player"]["name"] == "Ilse Peeters"
    assert fresh.payload["player"]["rating"] == 1804
    assert fresh.payload["schema"] == "openresults/registration"
    assert fresh.status == "discarded"
    assert fresh.external_key == old.external_key

    # Idempotent: nothing left to clear.
    assert Retention.run(@now) == 0
  end

  test "exactly the retention window is enough; a day short is not" do
    on_the_day = registration("2026-08-14")
    a_day_short = registration("2026-08-15")

    Retention.run(@now)

    assert Registration.email(reload(on_the_day)) == nil
    assert Registration.email(reload(a_day_short)) == "ilse@example.org"
  end

  test "a tournament that has not ended yet keeps the email" do
    upcoming = registration("2026-10-01")
    Retention.run(@now)
    assert Registration.email(reload(upcoming)) == "ilse@example.org"
  end

  test "a tournament with no end_date keeps the email" do
    undated = registration("")
    Retention.run(@now)
    assert Registration.email(reload(undated)) == "ilse@example.org"
  end

  test "the window is configurable" do
    Application.put_env(:pairings_engine, :registration_retention_days, 7)
    recent = registration("2026-09-05")
    Retention.run(@now)
    assert Registration.email(reload(recent)) == nil
  end

  test "PAIRINGS_REGISTRATION_RETENTION_DAYS that is not a whole number of days, at least one, stops the boot" do
    runtime = Path.expand("../../config/runtime.exs", __DIR__)
    data_dir = Path.join(System.tmp_dir!(), "opret-runtime-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_dir) end)

    read = fn value ->
      vars = %{
        "OPENPAIRINGS_LOCAL" => "1",
        "OPENPAIRINGS_DATA_DIR" => data_dir,
        "PAIRINGS_REGISTRATION_RETENTION_DAYS" => value
      }

      previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
      Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

      try do
        Config.Reader.read!(runtime, env: :prod)
      after
        Enum.each(previous, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end

    assert read.("14")[:pairings_engine][:registration_retention_days] == 14

    for bad <- ["0", "-1", "30d", "1.5"] do
      assert_raise RuntimeError, ~r/PAIRINGS_REGISTRATION_RETENTION_DAYS/, fn -> read.(bad) end
    end
  end
end
