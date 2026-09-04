defmodule PairingsEngine.MobileHostedOnlyTest do
  @moduledoc """
  Phone enrolment is hosted-only, and the refusal has to live in the domain.

  The Live Round page hides the panel on a local run, but hiding a control is
  not refusing the action behind it - this codebase's own rule, written into
  `PairingsEngineWeb.FideLive`, is that a control absent from the page is
  still an event anybody can send.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Mobile
  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  setup do
    original = Application.get_env(:pairings_engine, :local_mode, false)
    on_exit(fn -> Application.put_env(:pairings_engine, :local_mode, original) end)

    tournament =
      Repo.insert!(%Tournament{name: "Club night", type: "swiss", rounds_count: 5})

    {:ok, tournament: tournament}
  end

  test "a hosted run mints a code as before", %{tournament: t} do
    Application.put_env(:pairings_engine, :local_mode, false)

    assert {:ok, enrollment} = Mobile.create_enrollment(t.id)
    assert enrollment.token
    assert enrollment.code
  end

  test "a local run refuses, even though the panel is already hidden", %{tournament: t} do
    Application.put_env(:pairings_engine, :local_mode, true)

    assert {:error, :local_mode} = Mobile.create_enrollment(t.id)
  end

  test "and nothing is written when it refuses", %{tournament: t} do
    Application.put_env(:pairings_engine, :local_mode, true)

    assert {:error, :local_mode} = Mobile.create_enrollment(t.id)
    assert Mobile.list_enrollments(t.id) == []
  end

  test "the refusal explains itself rather than reading as a fault" do
    text = PairingsEngine.Tournaments.refusal_message(:local_mode, "enrolling a phone")

    assert text =~ "your own computer"
    assert text =~ "hosted"
  end
end
