defmodule PairingsEngineWeb.FideLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.Accounts
  alias PairingsEngine.Repo
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Federations.BEL.Sync, as: KbsbSync

  setup :register_and_log_in_user

  # Connections moved behind `PairingsEngineWeb.RequireRole` on 2026-08-29:
  # gating its buttons had left the page readable by any account, and what it
  # shows - the publishing address, the backup filenames, the sync state - is
  # the operator's business. So the signed-in user here is an administrator,
  # and the tests below that care about a lesser role build their own.
  setup %{conn: conn, user: user} do
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    {:ok, conn: log_in_user(conn, admin), user: admin}
  end

  # The Belgian half of this page belongs to the pack and is absent for an
  # account that has not switched it on. Most of the file is about that half,
  # so it is enabled module-wide here; the "switched off" state has its own
  # describe at the bottom, which overrides this by clearing it again.
  setup :enable_federation_features

  test "renders every outbound connection under the 'Connections' heading", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    # Renamed from "Rating lists" when the OpenResults settings landed here.
    # The page stopped being only about rating lists the moment it also held
    # where this machine publishes to.
    assert html =~ "Connections</h1>"
    assert html =~ "FIDE database"
    assert html =~ "Belgian national rating list (KBSB/FRBE)"
    assert html =~ "players in the local database."
    assert html =~ "Public results site (OpenResults)"
  end

  test "the nav still points here", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    assert html =~ ~s(href="/fide")
    assert html =~ "Connections"
  end

  describe "the OpenResults settings" do
    alias PairingsEngine.Publishing

    # Saving now tests the connection, so every test in here makes a request
    # whether it means to or not. A default stub keeps a test about token
    # handling from failing on the network; the ones that care about the
    # connection re-stub with what they need.
    setup do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      :ok
    end

    defp sso_conn(conn) do
      {:ok, user} =
        Accounts.find_or_create_from_keycloak(%{
          sub: "sso-sub-#{System.unique_integer()}",
          email: "sso-user-#{System.unique_integer()}@example.com"
        })

      log_in_user(conn, user)
    end

    # The extra account these build is a fresh one, so it starts with no
    # federation features - and the tests that use it are about the ROLE
    # gate, not the feature gate. Switch the pack on so the Belgian controls
    # are on their page at all and the role check is what is being measured.
    defp role_conn(conn, role) do
      user = PairingsEngine.AccountsFixtures.user_fixture()
      {:ok, user} = Accounts.set_role(user.email, role)
      {:ok, user} = PairingsEngine.Features.set_enabled(user, PairingsEngine.Features.keys())
      log_in_user(conn, user)
    end

    defp admin_conn(conn), do: role_conn(conn, "admin")
    defp support_conn(conn), do: role_conn(conn, "support")

    defp local_mode(on?) do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, on?)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)
    end

    test "support cannot change where this machine publishes", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")

      # Repointing this at another server would quietly ship player names,
      # ratings and clubs there, so it is an operator's decision rather than
      # an account holder's - and the guard is on the HANDLER, not just the
      # markup, because a hidden button still accepts a crafted event.
      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://somewhere-else.example",
        "token" => "attackers-token"
      })
      |> render_submit()

      assert Publishing.endpoint() == "https://openresults.example"
      assert Publishing.token() == "operators-token"
    end

    test "support cannot remove the token either", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")

      html = lv |> element("button[phx-click=clear_publishing_token]") |> render_click()

      assert Publishing.token() == "operators-token"
      assert html =~ "needs an administrator"
    end

    test "says nothing is published until both halves are set", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "Nothing is published until both an address and a token are set."
    end

    test "saving tests the connection, and says so when it answers", %{conn: conn} do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => "s3cret"
        })
        |> render_submit()

      # "Saved" on its own answers the wrong question. Nobody types an address
      # to find out whether it was stored.
      assert html =~ "the results site answered"
    end

    test "a saved address that does not answer says so, and still saves", %{conn: conn} do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => "s3cret"
        })
        |> render_submit()

      assert html =~ "did not answer"
      assert html =~ "refused"

      # Saved anyway: a typo you cannot correct because the form threw it away
      # is worse than one that is stored and reported.
      assert Publishing.endpoint() == "https://openresults.example"
    end

    test "saving half the settings says nothing is published yet", %{conn: conn} do
      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      html =
        lv
        |> form("form[phx-submit=save_publishing]", %{
          "endpoint" => "https://openresults.example",
          "token" => ""
        })
        |> render_submit()

      assert html =~ "Nothing is published until both"
    end

    test "saving an address normalises it and keeps it", %{conn: conn} do
      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "openresults.example/",
        "token" => "s3cret"
      })
      |> render_submit()

      assert Publishing.endpoint() == "https://openresults.example"
      assert Publishing.token() == "s3cret"
    end

    test "an empty token box keeps the stored token instead of wiping it", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("keep-me")

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      # The token is a secret and is never rendered back, so the box is
      # always empty on load. Treating that as "clear it" would delete a
      # working token every time somebody edited the address beside it.
      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "token" => ""
      })
      |> render_submit()

      assert Publishing.token() == "keep-me"
      _ = lv
    end

    test "the token can be removed deliberately", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("remove-me")

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      lv |> element("button[phx-click=clear_publishing_token]") |> render_click()

      refute Publishing.token()
      refute Publishing.configured?()
    end

    test "the stored token is never rendered to the page", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("super-secret-value")

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ "super-secret-value"
      assert html =~ "a token is set"
    end
  end

  # These acts have the widest reach of anything the app does, and used to
  # reach only `Logger` - see `PairingsEngine.Audit.log_system/3`.
  describe "machine-wide acts get a durable audit row" do
    alias PairingsEngine.{Audit, Publishing}
    alias PairingsEngine.Fide.Sync, as: FideSync

    setup do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      # "starting a FIDE sync logs it" below triggers the real `FideSync`
      # singleton (see `PairingsEngine.Fide.SyncTest`'s own moduledoc note: a
      # named GenServer, shared process-wide state, not reset by the DB
      # sandbox). Reset around every test in this block so a real sync this
      # block starts cannot leave the button "busy" for a later test file.
      :sys.replace_state(FideSync, fn _ -> struct(FideSync) end)
      on_exit(fn -> :sys.replace_state(FideSync, fn _ -> struct(FideSync) end) end)

      :ok
    end

    test "saving a new address logs the change and the token separately, never the secret", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "token" => "s3cret"
      })
      |> render_submit()

      rows = Audit.list_machine_wide()

      assert endpoint_row = Enum.find(rows, &(&1.action == "publishing.endpoint_changed"))
      assert endpoint_row.tournament_id == nil

      assert endpoint_row.details["changed_fields"]["endpoint"] == [
               nil,
               "https://openresults.example"
             ]

      assert token_row = Enum.find(rows, &(&1.action == "publishing.token_replaced"))
      refute inspect(token_row.details) =~ "s3cret"
    end

    test "saving with the address unchanged logs no endpoint row", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "token" => ""
      })
      |> render_submit()

      refute Enum.any?(Audit.list_machine_wide(), &(&1.action == "publishing.endpoint_changed"))
    end

    test "leaving the token box blank (\"keep it\") logs no token row", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("keep-me")

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "token" => ""
      })
      |> render_submit()

      refute Enum.any?(Audit.list_machine_wide(), &(&1.action == "publishing.token_replaced"))
    end

    test "clearing the token logs that it happened, not the value that was cleared", %{
      conn: conn
    } do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_token("remove-me")

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")
      lv |> element("button[phx-click=clear_publishing_token]") |> render_click()

      assert [row] =
               Enum.filter(Audit.list_machine_wide(), &(&1.action == "publishing.token_cleared"))

      assert row.tournament_id == nil
      refute inspect(row.details) =~ "remove-me"
    end

    test "starting a FIDE sync logs it", %{conn: conn} do
      # `FideSync.start_sync/0` is a real, network-calling singleton (see
      # `PairingsEngine.Fide.SyncTest`'s moduledoc) - not something to let
      # loose in this test. Marking it already busy makes the cast a no-op
      # (its own `handle_cast(:start_sync, ...)` guard for exactly this),
      # while the audit row - written unconditionally by the handler here,
      # same as the click itself - still happens.
      :sys.replace_state(FideSync, fn s -> %{s | status: :downloading} end)

      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")
      render_click(lv, "sync", %{})

      assert Enum.any?(Audit.list_machine_wide(), &(&1.action == "fide.sync_started"))
    end

    test "a refusal (wrong role) logs nothing", %{conn: conn} do
      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://somewhere-else.example",
        "token" => "attackers-token"
      })
      |> render_submit()

      render_click(lv, "sync", %{})

      assert Audit.list_machine_wide() == []
    end
  end

  test "the KBSB list has no manual file upload any more", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/fide")

    refute html =~ ~s(id="kbsb-import-form")
    refute html =~ "Import file"
    refute html =~ "drag and drop"
  end

  test "searching the local KBSB database returns matches", %{conn: conn} do
    Repo.insert!(%Member{
      national_id: "12345",
      last_name: "Peeters",
      first_name: "Jan",
      national_rating: 1850,
      club_number: 42,
      club_name: "KSK Antwerpen",
      federation: "VSF",
      birth_year: 1990
    })

    {:ok, lv, _html} = live(conn, ~p"/fide")

    # Driven through the actual form element rather than by synthesising the
    # event: `render_change(lv, "kbsb_search", ...)` proves the handler
    # works, not that the PAGE can reach it. The search input once carried
    # phx-change on a bare <input> with no wrapping form, so LiveView sent
    # %{"value" => ...}, the handler never matched, and the whole LiveView
    # crashed and silently reconnected - indistinguishable from "no
    # results". A synthesised event cannot see that; this can.
    html = lv |> form("form.search-wrap", %{"q" => "Peet"}) |> render_change()

    assert html =~ "Peeters"
    assert html =~ "KSK Antwerpen"
  end

  test "an unknown KBSB search query returns no results", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/fide")

    html = lv |> form("form.search-wrap", %{"q" => "Nobody"}) |> render_change()

    refute html =~ "kbsb-result-row"
  end

  describe "the FIDE download is gated on the role" do
    test "support sees the button disabled and can't trigger sync", %{conn: conn} do
      # Support is the role that can OPEN this page without being able to act
      # on it, so it is what proves the button-level gate. An ordinary
      # account never gets this far - see `admin_access_test.exs`.
      {:ok, lv, html} = live(support_conn(conn), ~p"/fide")

      assert html =~ "needs an administrator"
      assert lv |> element("button[phx-click='sync'][disabled]") |> has_element?()

      # The guard is on the HANDLER, not just the markup: a disabled button
      # still accepts a crafted event.
      html = render_click(lv, "sync", %{})
      assert html =~ "needs an administrator"
    end

    test "an SSO account is not an administrator, and cannot even open the page",
         %{conn: conn} do
      # This is the change of 2026-08-29 and the reason the role exists.
      # Signing in through 02cloud says how somebody authenticated; it does
      # not say they may spend forty megabytes of somebody else's bandwidth
      # on this installation's behalf. Every account in a federated
      # directory used to pass this gate.
      assert {:error, {:redirect, %{to: "/"}}} = live(sso_conn(conn), ~p"/fide")
    end

    test "an administrator sees the button enabled, no restriction message", %{conn: conn} do
      {:ok, lv, html} = live(admin_conn(conn), ~p"/fide")

      refute html =~ "needs an administrator"
      refute lv |> element("button[phx-click='sync'][disabled]") |> has_element?()
    end

    test "a local run needs no role", %{conn: conn} do
      # An arbiter's laptop has no accounts at all. Requiring a role there
      # would not add a check, it would remove the feature - and there is
      # nobody to withhold it from, because the listener is on loopback and
      # the person at the keyboard already owns the machine.
      local_mode(true)

      {:ok, lv, html} = live(conn, ~p"/fide")

      refute html =~ "needs an administrator"
      refute lv |> element("button[phx-click='sync'][disabled]") |> has_element?()
    end
  end

  describe "what support may do" do
    setup do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      :ok
    end

    test "run the connection check, because that is the whole job", %{conn: conn} do
      # "Why did publishing stop" is the question support exists to answer,
      # and needing admin to answer it would mean the person diagnosing the
      # fault has to be the person able to cause it.
      PairingsEngine.Publishing.put_endpoint("https://openresults.example")
      PairingsEngine.Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")
      html = lv |> element("button[phx-click=test_publishing]") |> render_click()

      # The check's own answer, not the absence of a refusal: this page still
      # says "needs an administrator" to a support user about the FIDE
      # download beside it, so refuting that string would pass for the wrong
      # reason and would keep passing if the check silently did nothing.
      assert html =~ "Connected. The address and token are both accepted."
    end

    test "but not change where this machine publishes", %{conn: conn} do
      PairingsEngine.Publishing.put_endpoint("https://openresults.example")
      PairingsEngine.Publishing.put_token("operators-token")

      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://somewhere-else.example",
        "token" => "attackers-token"
      })
      |> render_submit()

      assert PairingsEngine.Publishing.endpoint() == "https://openresults.example"
      assert PairingsEngine.Publishing.token() == "operators-token"
    end
  end

  describe "KBSB data-platform sync button" do
    setup do
      original = Application.get_env(:pairings_engine, :kbsb)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pairings_engine, :kbsb, original),
          else: Application.delete_env(:pairings_engine, :kbsb)
      end)

      :ok
    end

    test "is offered when the API is configured", %{conn: conn} do
      Application.put_env(:pairings_engine, :kbsb, api_url: "https://kbsb.test", api_key: "k")

      {:ok, _lv, html} = live(conn, ~p"/fide")

      assert html =~ "Sync from data platform"
      assert html =~ "phx-click=\"sync_kbsb_api\""
      # The empty-state copy should point at the button, not at a file.
      assert html =~ "sync it from the data platform to get started"
    end

    # Offering a button whose only possible outcome is an error message is
    # worse than not offering it: the arbiter cannot fix server config from
    # here, so the page tells them what to set instead.
    test "is hidden when it is not configured, with the setting named", %{conn: conn} do
      Application.delete_env(:pairings_engine, :kbsb)

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ "Sync from data platform"
      assert html =~ "KBSB_API_URL"
      assert html =~ "no source is configured"
    end
  end

  describe "the public address" do
    alias PairingsEngine.Publishing

    setup do
      Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"}))
      end)

      :ok
    end

    test "is saved separately from the address this machine sends to", %{conn: conn} do
      # The whole point: on a box hosting both applications the send target
      # can be loopback while spectators still get a name that resolves.
      {:ok, lv, _html} = live(conn, ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "http://localhost:4004",
        "public_base" => "https://openresults.example",
        "token" => "s3cret"
      })
      |> render_submit()

      assert Publishing.endpoint() == "http://localhost:4004"
      assert Publishing.public_base() == "https://openresults.example"
    end

    test "emptying it goes back to using the send address", %{conn: conn} do
      Publishing.put_endpoint("https://openresults.example")
      Publishing.put_public_base("https://elsewhere.example")

      {:ok, lv, _html} = live(conn, ~p"/fide")

      lv
      |> form("form[phx-submit=save_publishing]", %{
        "endpoint" => "https://openresults.example",
        "public_base" => "",
        "token" => ""
      })
      |> render_submit()

      # Not stored as an empty string, which would be an address that is not
      # one - it clears, and the fallback takes over.
      assert Publishing.stored_public_base() == nil
      assert Publishing.public_base() == "https://openresults.example"
    end

    test "the box shows blank rather than the send address when none is set", %{conn: conn} do
      # `public_base/0` falls back, which is right for building a link and
      # wrong for a form: showing the send target in a box nobody filled in
      # would make the fallback permanent the first time somebody pressed
      # Save.
      Publishing.put_endpoint("https://openresults.example")

      {:ok, _lv, html} = live(conn, ~p"/fide")

      refute html =~ ~s(name="public_base" value="https://openresults.example")
    end
  end

  describe "the KBSB import is an act, not a look" do
    # The button is HIDDEN, not disabled, when no API is configured - the
    # page refuses to offer an action that could only fail. So a test about
    # who may press it has to configure one first, or it asserts against a
    # control that was never rendered for an unrelated reason.
    setup do
      original = Application.get_env(:pairings_engine, :kbsb)
      Application.put_env(:pairings_engine, :kbsb, api_url: "https://kbsb.test", api_key: "k")

      on_exit(fn ->
        if original,
          do: Application.put_env(:pairings_engine, :kbsb, original),
          else: Application.delete_env(:pairings_engine, :kbsb)
      end)

      :ok
    end

    test "support cannot start it, and is not offered the button", %{conn: conn} do
      # It pulls the whole Belgian roster over somebody else's API and
      # rewrites the local rating table. Every sibling handler on this page
      # checked the role; this one did not until 2026-08-29, and the page
      # became readable by support the same day.
      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")

      # Both halves, because they fail differently: a disabled button is what
      # an honest page looks like, and the handler guard is what survives a
      # crafted event aimed at it anyway.
      assert lv |> element("button[phx-click='sync_kbsb_api'][disabled]") |> has_element?()

      html = render_click(lv, "sync_kbsb_api", %{})
      assert html =~ "needs an administrator"
    end

    test "and cannot cancel one an administrator started", %{conn: conn} do
      # Cancelling is a mutation too: it stops an import somebody else
      # started, which is not support's call.
      #
      # Driven by seeding the real singleton busy - the same pattern
      # `Fide.SyncTest` uses - because the honest assertion is "the import is
      # still running", and against an idle server a cancel is a no-op
      # whether or not the guard exists. A test that passes with the bug
      # present is worse than none.
      :sys.replace_state(KbsbSync, fn state -> %{state | status: :importing} end)
      on_exit(fn -> :sys.replace_state(KbsbSync, fn s -> %{s | status: :idle} end) end)

      {:ok, lv, _html} = live(support_conn(conn), ~p"/fide")
      render_click(lv, "cancel_kbsb", %{})

      assert KbsbSync.status().status == :importing
    end

    test "an administrator is offered it", %{conn: conn} do
      # The control is guarded, not removed - an administrator must still be
      # able to press it, or the guard has broken the feature instead of
      # protecting it.
      {:ok, lv, _html} = live(admin_conn(conn), ~p"/fide")

      refute lv |> element("button[phx-click='sync_kbsb_api'][disabled]") |> has_element?()
    end
  end
end
