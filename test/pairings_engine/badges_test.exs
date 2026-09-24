defmodule PairingsEngine.BadgesTest do
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Badges, RateLimit, Repo, Tournaments}
  alias PairingsEngine.Badges.{Badge, Defaults, Image}

  setup do
    RateLimit.clear_all()
    %{scope: user_scope_fixture()}
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Brussels Open", "city" => "Brussels", "type" => "swiss"}, attrs)
      )

    t
  end

  defp player(t, attrs) do
    {:ok, p} = Tournaments.create_player(t.id, attrs)
    p
  end

  defp event(scope, attrs \\ %{}) do
    {:ok, event} = Badges.create_event(scope, Map.merge(%{"name" => "Badge event"}, attrs))
    event
  end

  # A PNG header is all `Image` reads: the signature and the IHDR size.
  def png(w \\ 400, h \\ 500),
    do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", w::32, h::32, 8, 6, 0, 0, 0>>

  describe "events" do
    test "a stand-alone event gets the default roles, rooms and conditions", %{scope: scope} do
      event = event(scope, %{"name" => "Press Day"})

      assert event.tournament_id == nil
      assert Enum.map(event.roles, & &1["key"]) == Enum.map(Defaults.roles(), & &1["key"])
      assert event.room_names["1"] == "PLAYING HALL"
      assert event.usage_conditions =~ "$tournament-name"
    end

    test "a linked event fills its blanks from the tournament", %{scope: scope} do
      t = tournament(scope)
      {:ok, event} = Badges.create_event(scope, %{"name" => "", "tournament_id" => t.id})

      assert event.name == "Brussels Open"
      assert event.city == "Brussels"
      assert event.tournament_id == t.id
    end

    test "a name is required", %{scope: scope} do
      assert {:error, changeset} = Badges.create_event(scope, %{"name" => " "})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "another user cannot see, change or delete the event", %{scope: scope} do
      event = event(scope)
      other = user_scope_fixture()

      assert Badges.list_events(other) == []
      assert Badges.get_event(other, event.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Badges.get_event!(other, event.id) end

      assert_raise Ecto.NoResultsError, fn ->
        Badges.update_event(other, event, %{"name" => "x"})
      end

      assert_raise Ecto.NoResultsError, fn -> Badges.delete_event(other, event) end
      assert_raise Ecto.NoResultsError, fn -> Badges.create_badge(other, event) end
      assert Badges.get_event!(scope, event.id).name == "Badge event"
    end

    test "list_events counts badges", %{scope: scope} do
      event = event(scope)
      {:ok, _} = Badges.create_badge(scope, event)
      {:ok, _} = Badges.create_badge(scope, event)

      assert [%{badge_count: 2}] = Badges.list_events(scope)
    end

    test "fewer rooms drop the ticks for rooms that are gone", %{scope: scope} do
      event = event(scope)
      {:ok, badge} = Badges.create_badge(scope, event)
      {:ok, badge} = Badges.set_room_access(scope, event, badge, [1, 5, 8])

      {:ok, event} = Badges.update_event(scope, event, %{"room_count" => "4"})

      assert event.room_count == 4
      assert Repo.reload!(badge).room_access == [1]
    end

    test "the import roles cannot be removed and colours must be #RRGGBB", %{scope: scope} do
      event = event(scope)

      {:ok, event} =
        Badges.update_event(scope, event, %{
          "roles" => %{
            "0" => %{"key" => "press", "label" => "PERS / PRESSE", "color" => "#DD6118"}
          }
        })

      keys = Enum.map(event.roles, & &1["key"])
      assert "press" in keys
      for key <- Defaults.import_role_keys(), do: assert(key in keys)
      assert Enum.find(event.roles, &(&1["key"] == "press"))["label"] == "PERS / PRESSE"

      assert {:error, changeset} =
               Badges.update_event(scope, event, %{
                 "roles" => %{"0" => %{"key" => "press", "label" => "X", "color" => "red"}}
               })

      assert %{roles: [_]} = errors_on(changeset)
    end

    test "the printed conditions fill in the event name and organiser", %{scope: scope} do
      event = event(scope, %{"name" => "Antwerp Masters", "organiser" => "KBSB"})
      {:ok, badge} = Badges.create_badge(scope, event)
      card = Badges.card(event, badge, fn _, _ -> nil end)

      assert card.usage_conditions =~ "Antwerp Masters"
      assert card.usage_conditions =~ "KBSB reserves"
      refute card.usage_conditions =~ "$organiser"
    end
  end

  describe "linking to a tournament" do
    test "only to a tournament the user can access", %{scope: scope} do
      other = user_scope_fixture()
      theirs = tournament(other)
      event = event(scope)

      assert {:error, :unauthorized} = Badges.link_tournament(scope, event, theirs.id)

      assert {:error, :unauthorized} =
               Badges.create_event(scope, %{"name" => "x", "tournament_id" => theirs.id})

      assert {:error, :unauthorized} = Badges.link_tournament(scope, event, "not-a-number")

      mine = tournament(scope)
      assert {:ok, %{tournament_id: id}} = Badges.link_tournament(scope, event, mine.id)
      assert id == mine.id
      assert {:ok, %{tournament_id: nil}} = Badges.link_tournament(scope, event, "")
    end

    test "an accepted collaborator may link the tournament", %{scope: scope} do
      owner = user_scope_fixture()
      t = tournament(owner)
      {:ok, invite} = Tournaments.add_collaborator(owner, t, scope.user.email)
      {:ok, _} = Tournaments.accept_invitation(scope, invite.invite_token)

      assert {:ok, event} = Badges.create_event(scope, %{"name" => "x", "tournament_id" => t.id})
      assert event.tournament_id == t.id
    end

    test "event_for_tournament finds the user's own event only", %{scope: scope} do
      t = tournament(scope)
      event = event(scope, %{"tournament_id" => t.id})

      assert Badges.event_for_tournament(scope, t.id).id == event.id
      assert Badges.event_for_tournament(user_scope_fixture(), t.id) == nil
    end
  end

  describe "importing players" do
    setup %{scope: scope} do
      t = tournament(scope)

      carlsen =
        player(t, %{
          "name" => "Carlsen, Magnus",
          "title" => "GM",
          "federation" => "NOR",
          "fide_id" => "1503014"
        })

      burssens = player(t, %{"name" => "Burssens, Jorian", "federation" => "BEL"})

      %{
        t: t,
        event: event(scope, %{"tournament_id" => t.id}),
        carlsen: carlsen,
        burssens: burssens
      }
    end

    test "creates one badge per player with the player role", %{
      scope: scope,
      event: event,
      carlsen: carlsen
    } do
      assert {:ok, %{created: 2, updated: 0}} = Badges.import_players(scope, event)

      badge = Enum.find(Badges.list_badges(scope, event), &(&1.source_player_id == carlsen.id))
      assert badge.first_name == "Magnus"
      assert badge.last_name == "Carlsen"
      assert badge.title == "GM"
      assert badge.federation == "NOR"
      assert badge.fide_id == "1503014"
      assert badge.source == "player"
      assert badge.role == "PLAYER"
      assert badge.room_access == [1]
    end

    test "re-import updates in place, keeps manual badges and hand edits", %{
      scope: scope,
      event: event,
      carlsen: carlsen,
      burssens: burssens
    } do
      {:ok, _} = Badges.import_players(scope, event)

      {:ok, manual} =
        Badges.create_badge(scope, event, %{"first_name" => "Press", "last_name" => "Person"})

      badge = Enum.find(Badges.list_badges(scope, event), &(&1.source_player_id == burssens.id))
      {:ok, badge} = Badges.update_badge(scope, badge, %{"first_name" => "Jo"})
      assert badge.edited_fields == ["first_name"]

      {:ok, _} = Tournaments.update_player(carlsen, %{"title" => "", "federation" => "FID"})

      {:ok, _} =
        Tournaments.update_player(burssens, %{"name" => "Burssens, Jorian Karel", "title" => "FM"})

      assert {:ok, %{created: 0, updated: 2}} = Badges.import_players(scope, event)

      badges = Badges.list_badges(scope, event)
      assert length(badges) == 3
      assert Enum.find(badges, &(&1.id == manual.id)).first_name == "Press"

      c = Enum.find(badges, &(&1.source_player_id == carlsen.id))
      assert c.federation == "FID"
      assert c.title == ""

      b = Enum.find(badges, &(&1.source_player_id == burssens.id))
      assert b.first_name == "Jo"
      assert b.title == "FM"

      assert {:ok, %{created: 0, updated: 0, unchanged: 2}} = Badges.import_players(scope, event)
    end

    test "revert_to_source forgets hand edits", %{scope: scope, event: event, burssens: burssens} do
      {:ok, _} = Badges.import_players(scope, event)
      badge = Enum.find(Badges.list_badges(scope, event), &(&1.source_player_id == burssens.id))
      {:ok, badge} = Badges.update_badge(scope, badge, %{"first_name" => "Jo"})

      {:ok, badge} = Badges.revert_to_source(scope, badge)
      assert badge.first_name == "Jorian"
      assert badge.edited_fields == []
    end

    test "a player who left keeps the badge; room access is never reset", %{
      scope: scope,
      event: event,
      carlsen: carlsen
    } do
      {:ok, _} = Badges.import_players(scope, event)
      badge = Enum.find(Badges.list_badges(scope, event), &(&1.source_player_id == carlsen.id))
      {:ok, _} = Badges.set_room_access(scope, event, badge, [1, 2, 3])
      {:ok, _} = Tournaments.delete_player(carlsen)

      {:ok, _} = Badges.import_players(scope, event)
      assert Repo.reload!(badge).room_access == [1, 2, 3]
    end

    test "needs a linked tournament the user can still access", %{scope: scope, t: t} do
      assert {:error, :no_tournament} = Badges.import_players(scope, event(scope))

      owner = user_scope_fixture()
      shared = tournament(owner)
      {:ok, invite} = Tournaments.add_collaborator(owner, shared, scope.user.email)
      {:ok, _} = Tournaments.accept_invitation(scope, invite.invite_token)
      linked = event(scope, %{"tournament_id" => shared.id})
      [collab] = Tournaments.list_collaborators(shared)
      :ok = remove_collaborator(owner, shared, collab)

      assert {:error, :unauthorized} = Badges.import_players(scope, linked)
      assert t.id != shared.id
    end
  end

  defp remove_collaborator(owner, t, collab) do
    case Tournaments.remove_collaborator(owner, t, collab.id) do
      {:ok, _} -> :ok
      :ok -> :ok
    end
  end

  describe "importing officials" do
    test "chief, deputies and further arbiters, matched by slot on re-import", %{scope: scope} do
      t =
        tournament(scope, %{
          "chief_arbiter" => "De Vet, Pieter",
          "officials" => %{
            "chief_arbiter_fide_id" => "209848",
            "deputy1_name" => "Janssens, An",
            "deputy1_fide_id" => "231110",
            "extra_arbiters_count" => "2",
            "arbiter1_name" => "Peeters, Tom",
            "arbiter2_name" => ""
          }
        })

      event = event(scope, %{"tournament_id" => t.id})
      assert {:ok, %{created: 3}} = Badges.import_officials(scope, event)

      badges = Badges.list_badges(scope, event)
      by_slot = Map.new(badges, &{&1.source_official_slot, &1})

      assert by_slot["chief"].last_name == "De Vet"
      assert by_slot["chief"].first_name == "Pieter"
      assert by_slot["chief"].fide_id == "209848"
      assert by_slot["chief"].role == "CHIEF ARBITER"
      assert by_slot["deputy1"].role == "DEPUTY CHIEF ARBITER"
      assert by_slot["arbiter1"].role == "ARBITER"
      assert by_slot["chief"].room_access == Enum.to_list(1..event.room_count)

      {:ok, _} =
        Tournaments.update_tournament(t, %{
          "officials" => Map.put(t.officials, "deputy1_name", "Maes, Lien")
        })

      assert {:ok, %{created: 0, updated: 1}} = Badges.import_officials(scope, event)
      deputy = Repo.reload!(by_slot["deputy1"])
      assert deputy.first_name == "Lien"
      assert length(Badges.list_badges(scope, event)) == 3
    end

    test "a FIDE photo goes when the slot's FIDE ID changes; an upload stays", %{scope: scope} do
      t =
        tournament(scope, %{
          "chief_arbiter" => "De Vet, Pieter",
          "officials" => %{"chief_arbiter_fide_id" => "209848", "deputy1_name" => "Janssens, An"}
        })

      event = event(scope, %{"tournament_id" => t.id})
      {:ok, _} = Badges.import_officials(scope, event)
      by_slot = Map.new(Badges.list_badges(scope, event), &{&1.source_official_slot, &1})
      {:ok, _} = Badges.set_photo(scope, by_slot["chief"], png(), "fide")
      {:ok, _} = Badges.set_photo(scope, by_slot["deputy1"], png(), "upload")

      {:ok, _} =
        Tournaments.update_tournament(t, %{
          "chief_arbiter" => "Maes, Lien",
          "officials" => %{
            "chief_arbiter_fide_id" => "231110",
            "deputy1_name" => "Janssens, An",
            "deputy1_fide_id" => "1"
          }
        })

      {:ok, _} = Badges.import_officials(scope, event)
      assert Badges.photo(by_slot["chief"]) == nil
      assert Badges.photo(by_slot["deputy1"]) != nil
    end
  end

  describe "photos and logos" do
    setup %{scope: scope} do
      event = event(scope)
      {:ok, badge} = Badges.create_badge(scope, event)
      %{event: event, badge: badge}
    end

    test "a raster photo is stored and served back", %{scope: scope, badge: badge} do
      assert {:ok, badge} = Badges.set_photo(scope, badge, png())
      assert badge.photo_content_type == "image/png"
      assert badge.photo_source == "upload"
      assert {data, "image/png"} = Badges.photo(badge)
      assert data == png()
    end

    test "SVG, oversized and huge-pixel images are refused", %{scope: scope, badge: badge} do
      svg = ~s[<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>]
      assert {:error, :invalid_image} = Badges.set_photo(scope, badge, svg)

      assert {:error, :too_large} =
               Badges.set_photo(scope, badge, png() <> :binary.copy(<<0>>, 1_000_001))

      assert {:error, :too_many_pixels} = Badges.set_photo(scope, badge, png(5000, 5000))
      assert Badges.photo(badge) == nil
    end

    test "logos go in their slot and come out again", %{scope: scope, event: event} do
      assert {:ok, _} = Badges.set_logo(scope, event, :emblem, png(800, 400))
      assert {_, "image/png"} = Badges.logo(event, :emblem)
      assert Badges.logo(event, :logo_left) == nil
      assert {:ok, _} = Badges.clear_logo(scope, event, :emblem)
      assert Badges.logo(event, :emblem) == nil
    end

    test "another user cannot set or read a photo", %{scope: scope, badge: badge} do
      other = user_scope_fixture()
      assert_raise Ecto.NoResultsError, fn -> Badges.set_photo(other, badge, png()) end

      assert_raise Ecto.NoResultsError, fn ->
        Badges.update_badge(other, badge, %{"first_name" => "x"})
      end

      assert_raise Ecto.NoResultsError, fn -> Badges.delete_badge(other, badge) end
      assert {:ok, _} = Badges.update_badge(scope, badge, %{"first_name" => "x"})
    end

    test "reads JPEG, GIF and WebP dimensions" do
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 17, 8, 600::16, 400::16, 3>>
      gif = <<"GIF89a", 300::little-16, 200::little-16, 0>>

      webp =
        <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0::32, 639::little-24, 479::little-24>>

      assert Image.dimensions(jpeg, "image/jpeg") == {400, 600}
      assert Image.dimensions(gif, "image/gif") == {300, 200}
      assert Image.dimensions(webp, "image/webp") == {640, 480}
    end
  end

  describe "fetching the FIDE photo" do
    setup %{scope: scope} do
      event = event(scope)
      {:ok, badge} = Badges.create_badge(scope, event, %{"fide_id" => "255424"})
      %{event: event, badge: badge}
    end

    defp profile_html(photo_src) do
      """
      <html><body>
        <h1 class="player-title">Burssens, Jorian</h1>
        <div class="profile-info-country">Belgium</div>
        #{if photo_src, do: ~s(<img class="profile-top__photo" src="#{photo_src}">)}
      </body></html>
      """
    end

    defp stub_fide(fun), do: Req.Test.stub(PairingsEngine.Badges.FideProfileTest, fun)

    test "stores an inline photo and fills blank names only", %{scope: scope, badge: badge} do
      data_uri = "data:image/png;base64," <> Base.encode64(png())

      stub_fide(fn conn ->
        assert conn.host == "ratings.fide.com"
        assert conn.request_path == "/profile/255424"
        Plug.Conn.send_resp(conn, 200, profile_html(data_uri))
      end)

      {:ok, badge} = Badges.claim_fide_fetch(scope, badge)
      assert {:ok, badge} = Badges.fetch_fide_photo(scope, badge)
      assert badge.photo_source == "fide"
      assert badge.first_name == "Jorian"
      assert badge.last_name == "Burssens"
      assert badge.federation == "Belgium"
      assert {_, "image/png"} = Badges.photo(badge)
    end

    test "follows a photo link on fide.com only", %{scope: scope, badge: badge} do
      stub_fide(fn conn ->
        case conn.request_path do
          "/profile/255424" ->
            Plug.Conn.send_resp(conn, 200, profile_html("/img/photo/255424.png"))

          "/img/photo/255424.png" ->
            Plug.Conn.send_resp(conn, 200, png())
        end
      end)

      assert {:ok, %{photo_source: "fide"}} = Badges.fetch_fide_photo(scope, badge)

      stub_fide(fn conn ->
        Plug.Conn.send_resp(conn, 200, profile_html("https://evil.example.com/p.png"))
      end)

      {:ok, badge} = Badges.clear_photo(scope, badge)
      assert Badges.photo(badge) == nil
      assert {:error, :bad_photo} = Badges.fetch_fide_photo(scope, badge)
    end

    test "a changed page, a missing player and a missing photo each say so", %{
      scope: scope,
      badge: badge
    } do
      stub_fide(fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><body><main>New design</main></body></html>")
      end)

      assert {:error, :page_changed} = Badges.fetch_fide_photo(scope, badge)

      stub_fide(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, :not_found} = Badges.fetch_fide_photo(scope, badge)

      stub_fide(fn conn -> Plug.Conn.send_resp(conn, 200, profile_html(nil)) end)
      assert {:error, :no_photo} = Badges.fetch_fide_photo(scope, badge)

      stub_fide(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, :unreachable} = Badges.fetch_fide_photo(scope, badge)
    end

    test "the guards: FIDE ID needed, one try a minute, once stored, and a per-user limit", %{
      scope: scope,
      event: event,
      badge: badge
    } do
      {:ok, no_id} = Badges.create_badge(scope, event)
      assert {:error, :no_fide_id} = Badges.claim_fide_fetch(scope, no_id)

      assert {:ok, claimed} = Badges.claim_fide_fetch(scope, badge)
      assert claimed.photo_fetched_at
      assert {:error, :cooldown} = Badges.claim_fide_fetch(scope, badge)

      {:ok, stored} = Badges.set_photo(scope, badge, png(), "fide")
      assert {:error, :already_fetched} = Badges.claim_fide_fetch(scope, stored)

      for n <- 1..9 do
        {:ok, b} = Badges.create_badge(scope, event, %{"fide_id" => "#{1000 + n}"})
        assert {:ok, _} = Badges.claim_fide_fetch(scope, b)
      end

      {:ok, eleventh} = Badges.create_badge(scope, event, %{"fide_id" => "2000"})
      assert {:error, :rate_limited} = Badges.claim_fide_fetch(scope, eleventh)
    end
  end

  test "duplicating makes a manual copy with the photo", %{scope: scope} do
    t = tournament(scope)
    p = player(t, %{"name" => "Doe, Jane"})
    event = event(scope, %{"tournament_id" => t.id})
    {:ok, _} = Badges.import_players(scope, event)
    [badge] = Badges.list_badges(scope, event)
    {:ok, _} = Badges.set_photo(scope, badge, png())

    {:ok, copy} = Badges.duplicate_badge(scope, badge)

    assert copy.source == "manual"
    assert copy.source_player_id == nil
    assert copy.first_name == "Jane"
    assert Badges.photo(copy) != nil
    assert badge.source_player_id == p.id
    assert %Badge{} = Badges.get_badge!(scope, event, copy.id)
  end
end
