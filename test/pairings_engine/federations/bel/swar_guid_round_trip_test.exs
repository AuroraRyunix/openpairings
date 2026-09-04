defmodule PairingsEngine.Federations.BEL.SwarGuidRoundTripTest do
  @moduledoc """
  A tournament keeps ONE identity across the whole loop.

  The realistic path is: pair a few rounds here, export to `.swar`, carry on in
  SWAR at the venue, and upload from SWAR at the end. The federation's results
  site overwrites by guid, so if the identity changes anywhere along that loop
  the same event is published twice.

  SWAR only ever mints a guid when the field it reads is empty
  (`GenerateGUID()` is guarded on that), so whatever OpenPairings writes into
  the file is what SWAR keeps and uploads.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Federations.BEL.{SwarExport, SwarPublish}

  defp tournament(attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        user_scope_fixture(),
        Map.merge(
          %{
            "name" => "Round trip",
            "type" => "swiss",
            # `start_date` is DERIVED from the round dates rather than set
            # directly (see `SettingsDatesLive.derive_dates_from_round_dates/1`),
            # so a fixture that sets it alone leaves it empty - and the guid
            # would fall back to today, which is not what is being tested.
            "round_dates" => ["2026-08-01", "2026-08-05"],
            "organizer_club_number" => "351"
          },
          attrs
        )
      )

    t
  end

  test "exporting mints a guid in the shape the results site accepts" do
    t = tournament()
    assert t.swar_guid in [nil, ""]

    SwarExport.export(t.id)

    guid = Repo.get!(Tournaments.Tournament, t.id).swar_guid

    # club - YYMMDD from the start date - 8 hex - {uuid}
    assert guid =~ ~r/^351-260801-[0-9a-f]{8}-\{[0-9a-f-]{36}\}$/,
           "a bare UUID here would come back from the federation as 'bad Guid date'"
  end

  test "exporting twice keeps the same identity" do
    # Two files with two guids means two tournaments on a site that overwrites
    # by guid - the exact duplicate this test exists to prevent.
    t = tournament()

    SwarExport.export(t.id)
    first = Repo.get!(Tournaments.Tournament, t.id).swar_guid

    SwarExport.export(t.id)
    second = Repo.get!(Tournaments.Tournament, t.id).swar_guid

    assert first == second
  end

  test "a guid that came in with an imported tournament is never replaced" do
    # Imported from SWAR, worked on here, exported back: SWAR must recognise
    # its own tournament rather than treating it as a new one.
    existing = "601-260829-0002a320-{b050e04f-9bfc-4b69-a71a-211a537ddffa}"
    t = tournament()
    {:ok, t} = Tournaments.update_tournament(t, %{"swar_guid" => existing})

    SwarExport.export(t.id)

    assert Repo.get!(Tournaments.Tournament, t.id).swar_guid == existing
  end

  test "the guid actually written into the file is the stored one" do
    t = tournament()
    binary = SwarExport.export(t.id)
    guid = Repo.get!(Tournaments.Tournament, t.id).swar_guid

    assert String.contains?(binary, guid),
           "the file has to carry the same identity the database kept"
  end

  test "publishing from here and exporting to SWAR agree on the identity" do
    t = tournament()
    t = SwarPublish.ensure_guid!(t)

    SwarExport.export(t.id)

    assert Repo.get!(Tournaments.Tournament, t.id).swar_guid == t.swar_guid
  end
end
