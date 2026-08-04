defmodule PairingsEngine.Tools.OverlayTest do
  # async: true — Overlay is pure, no database.
  use ExUnit.Case, async: true

  alias PairingsEngine.Tools.Overlay
  alias PairingsEngine.Tournaments.Tournament

  defp tournament(overrides \\ %{}), do: struct(%Tournament{officials: %{}}, overrides)

  test "merges chief arbiter, organizer and their e-mails onto officials" do
    merged =
      Overlay.apply(tournament(), %{
        "chief_arbiter_name" => "Cornet, Luc",
        "chief_arbiter_fide_id" => "205494",
        "chief_arbiter_email" => "luc@example.com",
        "organizer_name" => "VPTD Geraardsbergen",
        "organizer_fide_id" => "300100",
        "organizer_email" => "org@example.com",
        "event_code" => "BEL2026001"
      })

    assert merged.chief_arbiter == "Cornet, Luc"
    assert merged.organizer == "VPTD Geraardsbergen"
    assert merged.event_code == "BEL2026001"
    assert merged.officials["chief_arbiter_fide_id"] == "205494"
    assert merged.officials["chief_arbiter_email"] == "luc@example.com"
    assert merged.officials["organizer_id"] == "300100"
    assert merged.officials["organizer_email"] == "org@example.com"
  end

  test "a blank overlay value never clobbers what the file already carried" do
    t =
      tournament(%{
        chief_arbiter: "From TRF, Chief",
        officials: %{"chief_arbiter_email" => "already@example.com"}
      })

    merged =
      Overlay.apply(t, %{
        "chief_arbiter_name" => "",
        "chief_arbiter_email" => ""
      })

    assert merged.chief_arbiter == "From TRF, Chief"
    assert merged.officials["chief_arbiter_email"] == "already@example.com"
  end

  test "unrecognised keys are ignored" do
    merged = Overlay.apply(tournament(), %{"nonsense_key" => "whatever"})

    refute Map.has_key?(merged.officials, "nonsense_key")
  end
end
