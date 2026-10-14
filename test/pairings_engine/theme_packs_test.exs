defmodule PairingsEngine.ThemePacksTest do
  use ExUnit.Case, async: false

  import PairingsEngine.ThemePackFixtures

  alias PairingsEngine.Accounts.Preferences
  alias PairingsEngine.ThemePacks

  describe "where packs come from" do
    test "the hosted folder wins, on a server and on a desktop alike" do
      assert ThemePacks.resolve_dir("/srv/themes", false, nil) == "/srv/themes"
      assert ThemePacks.resolve_dir("/srv/themes", true, "/home/a/data") == "/srv/themes"
    end

    test "a desktop install reads <data dir>/themes" do
      assert ThemePacks.resolve_dir(nil, true, "/home/a/data") ==
               Path.join("/home/a/data", "themes")

      assert ThemePacks.resolve_dir("", true, "/home/a/data") ==
               Path.join("/home/a/data", "themes")
    end

    test "a server without the setting has none" do
      assert ThemePacks.resolve_dir(nil, false, nil) == nil
      assert ThemePacks.resolve_dir(nil, false, "/whatever") == nil
    end

    test "nothing is installed by default" do
      previous = Application.get_env(:pairings_engine, :themes_dir)
      Application.delete_env(:pairings_engine, :themes_dir)

      try do
        assert ThemePacks.list() == []
        assert Preferences.themes() == Preferences.builtin_themes()
        refute "jorian" in Preferences.themes()
      after
        if previous, do: Application.put_env(:pairings_engine, :themes_dir, previous)
      end
    end
  end

  describe "an installed pack" do
    setup :themes_dir

    test "is listed, served at a versioned URL and storable", %{themes_dir: dir} do
      install_pack(dir, "toon",
        meta: %{"name" => "Toon", "name_nl" => "Tekenfilm", "dark" => true}
      )

      assert [%{id: "toon", name: "Toon", dark: true} = pack] = ThemePacks.list()
      assert ThemePacks.label(pack, "nl") == "Tekenfilm"
      assert ThemePacks.label(pack, "en") == "Toon"
      assert ThemePacks.css_url(pack) =~ ~r/\A\/themes\/toon\/theme\.css\?v=[0-9a-f]{16}\z/
      assert "toon" in Preferences.themes()
      assert Preferences.theme?("toon")

      assert [%{"id" => "toon", "dark" => true, "css" => "/themes/toon/theme.css?v=" <> _}] =
               Jason.decode!(ThemePacks.bootstrap_json())
    end

    test "is gone the moment its folder is", %{themes_dir: dir} do
      path = install_pack(dir, "toon")
      assert ThemePacks.ids() == ["toon"]

      File.rm_rf!(path)
      assert ThemePacks.ids() == []
      refute Preferences.theme?("toon")
    end

    test "is refused, with the reason, when its CSS is not safe", %{themes_dir: dir} do
      install_pack(dir, "evil", css: ~s(@import "https://evil/x.css";))
      install_pack(dir, "loose", css: "body { color: red; }")

      assert ThemePacks.list() == []
      refused = Map.new(ThemePacks.refused())
      assert refused["evil"] =~ "@import"
      assert refused["loose"] =~ "scoped"
      refute Preferences.theme?("evil")
    end

    test "is refused when theme.json is wrong", %{themes_dir: dir} do
      install_pack(dir, "a", meta: %{"id" => "b"}, css: good_css("b"))
      install_pack(dir, "light", meta: %{"id" => "light"})
      install_pack(dir, "c", meta: %{"swatch" => ["red", "#fff", "#000"]})
      install_pack(dir, "d", meta: %{"dark" => "yes"})
      install_pack(dir, "e", meta: %{"name" => String.duplicate("x", 41)})
      File.mkdir_p!(Path.join(dir, "Bad Name"))

      refused = Map.new(ThemePacks.refused())
      assert refused["a"] =~ "folder"
      assert refused["light"] =~ "built-in"
      assert refused["c"] =~ "swatch"
      assert refused["d"] =~ "dark"
      assert refused["e"] =~ "name"
      assert refused["Bad Name"] =~ "theme.json"
      assert ThemePacks.list() == []
    end

    test "is refused when its stylesheet is over the cap", %{themes_dir: dir} do
      filler = "/*" <> String.duplicate("x", ThemePacks.css_limit()) <> "*/"
      install_pack(dir, "big", css: good_css("big") <> filler)

      assert [{"big", reason}] = ThemePacks.refused()
      assert reason =~ "200 KB"
    end
  end
end
