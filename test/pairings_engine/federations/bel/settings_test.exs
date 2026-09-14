defmodule PairingsEngine.Federations.BEL.SettingsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Federations.BEL.Settings

  test "players_url/0 defaults to KBSB's public template" do
    assert Settings.players_url() == Settings.default_players_url()
    assert Settings.players_url() =~ "{YYYYMM}"
  end

  test "put_players_url/1 stores a template or a fixed URL, put_players_url(nil) resets to default" do
    Settings.put_players_url("https://mirror.example/fixed.zip")
    assert Settings.players_url() == "https://mirror.example/fixed.zip"

    Settings.put_players_url(nil)
    assert Settings.players_url() == Settings.default_players_url()
  end

  test "clubs_url/0 is nil until configured" do
    assert Settings.clubs_url() == nil

    Settings.put_clubs_url("https://mirror.example/clubs.csv")
    assert Settings.clubs_url() == "https://mirror.example/clubs.csv"

    Settings.put_clubs_url(nil)
    assert Settings.clubs_url() == nil
  end
end
