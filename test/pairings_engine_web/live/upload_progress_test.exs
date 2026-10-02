defmodule PairingsEngineWeb.UploadProgressTest do
  # The JSON backup import that "just hangs on 0%" (0.70.0 - 0.72.0): every
  # import box disabled its button until the upload was done, while the
  # uploads were not `auto_upload` - so the file only started moving on a
  # submit that the disabled button could never send. These tests pin the
  # client-facing half (the inputs auto-upload, a refused file leaves the
  # button pressable with a readable reason) and the server-facing half (a
  # minimal hand-written backup imports, and an importer crash is shown in
  # the dialog instead of taking the LiveView down).
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.{Player, Tournament}

  import Ecto.Query

  setup :register_and_log_in_user

  # The shape of a backup written by a tool other than OpenPairings: no
  # rounds, no settings beyond the basics, keys OpenPairings never writes
  # (`club_number`, `affiliated`, ...), a string national id, and one player
  # without a birth date. Every name and id is made up.
  defp minimal_backup do
    players =
      for n <- 1..6 do
        %{
          "id" => n,
          "name" => "Testplayer, Alpha#{n}",
          "sex" => "m",
          "title" => "",
          "fide_rating" => 1500 + n * 10,
          "national_id" => "9#{n}000",
          "national_rating" => 0,
          "federation" => "BEL",
          "club" => "",
          "status" => "active",
          "fide_id" => 99_000_000 + n,
          "birth_year" => 1990 + n,
          "club_number" => 900 + n,
          "affiliated" => true
        }
        |> then(&if(n == 3, do: &1, else: Map.put(&1, "birth_date", "#{1990 + n}-01-0#{n}")))
      end

    %{
      "format" => "openpairings-export",
      "version" => 1,
      "exported_at" => "2026-10-02T12:00:00Z",
      "tournaments" => [
        %{
          "tournament" => %{
            "name" => "Synthetic Blitz",
            "type" => "swiss",
            "pairing_system" => "swiss",
            "venue" => "Test Hall, Teststraat 1, 0000 Nowhere",
            "city" => "Nowhere",
            "federation" => "BEL",
            "organizer" => "Organiser, Some",
            "chief_arbiter" => "Arbiter, Some",
            "deputy_arbiter" => "",
            "rounds_count" => 15,
            "round_dates" => List.duplicate("2026-11-01", 15),
            "status" => "setup",
            "standard" => "blitz",
            "rate_of_play" => "",
            "organizer_club_number" => "900",
            "event_code" => "123456",
            "fide_homologated" => true
          },
          "players" => players
        }
      ]
    }
  end

  defp open_backup_dialog(conn) do
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> element("button", "Import backup (JSON)") |> render_click()
    lv
  end

  defp choose(lv, name, content) do
    file_input(lv, "#backup-import-form", :backup, [
      %{name: name, content: content, type: "application/json"}
    ])
  end

  test "every import box uploads on selection, so its disabled-until-done button can be pressed",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")

    for {button, form} <- [
          {"Import backup (JSON)", "#backup-import-form"},
          {"Import TRF", "#trf-import-form"}
        ] do
      lv |> element("button", button) |> render_click()
      assert has_element?(lv, "#{form} input[type=file][data-phx-auto-upload]")
      lv |> element("#{form} button", "Cancel") |> render_click()
    end
  end

  test "a minimal hand-written backup imports instead of sticking at 0%", %{
    conn: conn,
    scope: scope
  } do
    lv = open_backup_dialog(conn)
    backup = choose(lv, "openpairings_synthetic.json", Jason.encode!(minimal_backup()))

    render_upload(backup, "openpairings_synthetic.json")
    refute has_element?(lv, "#backup-import-form button[type=submit][disabled]")

    html = lv |> form("#backup-import-form", %{}) |> render_submit()
    assert html =~ "Imported 1 tournament"

    tournament =
      Repo.one!(
        from t in Tournament,
          where: t.user_id == ^scope.user.id and t.name == "Synthetic Blitz"
      )

    assert tournament.fide_homologated
    assert tournament.rounds_count == 15

    assert Repo.aggregate(from(p in Player, where: p.tournament_id == ^tournament.id), :count) ==
             6
  end

  test "a file of the wrong type leaves Import pressable and says why, without a stuck 0%", %{
    conn: conn
  } do
    lv = open_backup_dialog(conn)

    backup =
      file_input(lv, "#backup-import-form", :backup, [
        %{name: "players.csv", content: "a,b\n", type: "text/csv"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(backup, "players.csv")

    assert render(lv) =~ "Only .json files are accepted here."
    refute has_element?(lv, "#backup-import-form button[type=submit][disabled]")
    refute has_element?(lv, "#backup-import-form .dropzone-file .hint")

    html = lv |> form("#backup-import-form", %{}) |> render_submit()
    assert html =~ "That file could not be uploaded"
  end

  test "a record that is not a JSON object is refused by name and position, and the page lives",
       %{conn: conn} do
    lv = open_backup_dialog(conn)

    broken =
      update_in(minimal_backup(), ["tournaments", Access.at(0), "players"], &(&1 ++ ["oops"]))

    backup = choose(lv, "broken.json", Jason.encode!(broken))
    render_upload(backup, "broken.json")
    html = lv |> form("#backup-import-form", %{}) |> render_submit()

    assert html =~ ~s(entry 7 of &quot;players&quot; is not a JSON object)
    assert render(lv) =~ "Import an OpenPairings backup"
  end

  test "a player field the schema refuses names the player entry", %{conn: conn} do
    lv = open_backup_dialog(conn)

    broken =
      put_in(
        minimal_backup(),
        ["tournaments", Access.at(0), "players", Access.at(1), "birth_date"],
        "not a date"
      )

    backup = choose(lv, "broken.json", Jason.encode!(broken))
    render_upload(backup, "broken.json")
    html = lv |> form("#backup-import-form", %{}) |> render_submit()

    assert html =~ "Could not import player entry 2 (id 2): birth_date is invalid"
  end
end
