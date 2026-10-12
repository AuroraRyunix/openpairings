defmodule PairingsEngine.BoardLink.RelayKeysTest do
  @moduledoc """
  The hall box's permission for the results site, fetched by this machine:
  when it asks, what it sends, what it does with each answer, and what the
  box is told. The results site is a `Req.Test` stub throughout.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, Publishing, Repo, TournamentExport, TournamentGroups}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.BoardLink.{Document, RelayKeys, RelayRequest}
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.Installation
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.Tournament

  @key_a "orrk_" <> String.duplicate("a", 39) <> "AAAA"
  @key_b "orrk_" <> String.duplicate("b", 39) <> "BBBB"
  @path_prefix "/api/tournaments/"

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_public_base(nil)
    Publishing.put_token("s3cret")
    scope = user_scope_fixture()
    {:ok, scope: scope}
  end

  # A tournament that is on the results site, as far as this machine knows.
  defp published(scope, attrs \\ %{}) do
    slug = "relay-#{System.unique_integer([:positive])}"

    paired_tournament(
      scope,
      Map.merge(
        %{publish_to_openresults: true, openresults_key: "tk-#{slug}", public_slug: slug},
        attrs
      )
    ).tournament
  end

  # The results site: hands out `keys` in order, one per request, and tells
  # the test what it was asked.
  defp site(keys) when is_list(keys) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> keys end)

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:asked, conn.method, conn.request_path, Map.new(conn.req_headers), body})

      case Agent.get_and_update(agent, fn
             [key | rest] -> {key, rest}
             [] -> {nil, []}
           end) do
        nil ->
          Server.json(conn, 409, %{"error" => "relay_key_limit", "detail" => "Test."})

        key ->
          Server.json(conn, 201, %{
            "status" => "ok",
            "relay_key" => key,
            "hint" => String.slice(key, -4, 4),
            "replaced" => 0
          })
      end
    end)
  end

  defp site(fun) when is_function(fun, 1), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  defp answers(status, body, headers \\ []) do
    site(fn conn ->
      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Server.json(status, body)
    end)
  end

  defp offline, do: site(&Req.Test.transport_error(&1, :econnrefused))

  defp asked do
    receive do
      {:asked, method, path, headers, body} -> [{method, path, headers, body} | asked()]
    after
      0 -> []
    end
  end

  defp reload(%Tournament{id: id}), do: Tournaments.get_tournament!(id)
  defp row(%Tournament{id: id}), do: RelayKeys.get(id)

  defp actions(%Tournament{id: id}),
    do: Repo.all(from a in AuditLog, where: a.tournament_id == ^id, select: a.action)

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  describe "when it asks" do
    test "not for a tournament nobody has a box for", %{scope: scope} do
      t = published(scope)
      site([@key_a])

      assert RelayKeys.sweep() == 0
      assert asked() == []
      assert %{state: :idle, fallback?: false} = RelayKeys.status(t)
    end

    test "after a connect code is made, with the publishing credentials", %{scope: scope} do
      t = published(scope)
      site([@key_a])
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)

      assert %{state: :fetching, reason: nil} = RelayKeys.status(t)
      assert RelayKeys.sweep() == 1

      assert [{"POST", path, headers, body}] = asked()
      assert path == @path_prefix <> t.public_slug <> "/relay-keys"
      assert headers["authorization"] == "Bearer s3cret"
      assert headers[Publishing.key_header()] == t.openresults_key
      assert Jason.decode!(body) == %{"label" => "openpairings"}

      t = reload(t)
      assert t.openresults_relay_key == @key_a

      assert %{state: :held, origin: :fetched, hint: "AAAA", at: %DateTime{}} =
               RelayKeys.status(t)

      assert %RelayRequest{state: "held", slug: slug} = row(t)
      assert slug == t.public_slug

      # Once is enough.
      assert RelayKeys.sweep() == 0
      assert asked() == []
    end

    test "for a tournament reached through a group code made on another one", %{scope: scope} do
      first = published(scope)
      second = published(scope, %{name: "The B group"})
      {:ok, group} = TournamentGroups.create_group(scope, first, "The Event")
      {:ok, _group} = TournamentGroups.join_group(scope, second, group.id)
      site([@key_a, @key_b])

      assert RelayKeys.sweep() == 0

      {:ok, _link, "oplg_" <> _} = BoardLink.create_group_link(scope, first)
      assert RelayKeys.sweep() == 2

      assert [{"POST", one, _, _}, {"POST", two, _, _}] = asked()

      assert Enum.sort([one, two]) ==
               Enum.sort(
                 for t <- [first, second], do: "#{@path_prefix}#{t.public_slug}/relay-keys"
               )

      assert reload(first).openresults_relay_key in [@key_a, @key_b]
      assert reload(second).openresults_relay_key in [@key_a, @key_b]
      refute reload(first).openresults_relay_key == reload(second).openresults_relay_key
    end

    test "a tournament added to the group later gets one without a new code", %{scope: scope} do
      first = published(scope)
      {:ok, group} = TournamentGroups.create_group(scope, first, "The Event")
      {:ok, _link, _secret} = BoardLink.create_group_link(scope, first)
      site([@key_a, @key_b])
      assert RelayKeys.sweep() == 1

      later = published(scope, %{name: "Added Later"})
      {:ok, _group} = TournamentGroups.join_group(scope, later, group.id)
      assert RelayKeys.sweep() == 1
      assert reload(later).openresults_relay_key == @key_b
    end

    test "when the live link is switched on", %{scope: scope} do
      t = published(scope)
      site([@key_a])
      {:ok, t} = Tournaments.set_live_boards(t, true)

      assert RelayKeys.sweep() == 1
      assert reload(t).openresults_relay_key == @key_a
    end

    test "when a box has reported a game, whatever became of its code", %{scope: scope} do
      %{tournament: t, boards: [board | _]} =
        paired_tournament(scope, %{
          publish_to_openresults: true,
          openresults_key: "tk",
          public_slug: "relay-reported-#{System.unique_integer([:positive])}"
        })

      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      {:ok, _} = BoardLink.report(link, t, report_for(board))
      {:ok, _} = BoardLink.revoke_link(scope, t, link.id)
      site([@key_a])

      assert RelayKeys.sweep() == 1
    end

    test "on publish, when the code was there first", %{scope: scope} do
      # Not on the results site yet: a code, and nothing to ask.
      t = published(scope, %{openresults_key: nil})
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a])
      assert %{state: :no_site} = RelayKeys.status(t)
      assert RelayKeys.sweep() == 0
      assert asked() == []

      # The first publish lands (`Publishing.ensure_key/1` writes this).
      t |> Ecto.Changeset.change(openresults_key: "tk-first") |> Repo.update!()
      assert RelayKeys.sweep() == 1
      assert reload(t).openresults_relay_key == @key_a
    end

    test "never for an archived tournament or one in the recycle bin", %{scope: scope} do
      archived = published(scope)
      binned = published(scope, %{name: "Binned"})
      for t <- [archived, binned], do: {:ok, _, _} = BoardLink.create_link(scope, t)
      {:ok, _} = Tournaments.archive_tournament(archived)
      binned |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second)) |> Repo.update!()
      site([@key_a, @key_b])

      assert RelayKeys.sweep() == 0
      assert asked() == []
    end

    test "nothing is sent while this machine has no credential it may send", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a])
      Publishing.put_token(nil)

      assert RelayKeys.sweep() == 0
      assert asked() == []
    end
  end

  describe "the box" do
    test "sees the document's version change when the key arrives, and the key in it", %{
      scope: scope
    } do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      before = Document.version(t)
      assert Document.document(t)["openresults"]["relay_key"] == nil

      site([@key_a, @key_b])
      RelayKeys.sweep()
      t = reload(t)

      refute Document.version(t) == before
      assert Document.document(t)["openresults"]["relay_key"] == @key_a

      # And again when it is replaced.
      with_key = Document.version(t)
      {:ok, _} = BoardLink.replace_relay_key(scope, t)
      RelayKeys.sweep()
      t = reload(t)
      refute Document.version(t) == with_key
      assert Document.document(t)["openresults"]["relay_key"] == @key_b
    end

    test "the settings page is told", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      BoardLink.subscribe(t.id)
      site([@key_a])
      RelayKeys.sweep()

      id = t.id
      assert_received {:board_link, ^id}
    end
  end

  describe "an older results site" do
    test "404 with no code of the API: said so, and not asked every pass", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      # Phoenix's own answer for a route that does not exist.
      answers(404, %{"errors" => %{"detail" => "Not Found"}})

      assert RelayKeys.sweep() == 0
      assert %{state: :refused, reason: "unsupported", fallback?: true} = RelayKeys.status(t)
      assert "boards.relay_key_refused" in actions(t)

      site(fn _conn -> flunk("asked again within the hour") end)
      assert RelayKeys.sweep() == 0
      assert RelayKeys.sweep(later(3_600)) == 0
    end

    test "pasting a key still works there, and the box gets it", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      answers(404, %{"error" => "not_found"})
      RelayKeys.sweep()

      {:ok, t} = BoardLink.set_relay_key(scope, t, @key_b)

      assert %{state: :held, origin: :pasted, hint: "BBBB", fallback?: true} =
               RelayKeys.status(t)

      assert Document.document(t)["openresults"]["relay_key"] == @key_b

      # A held key is not asked for again.
      site(fn _conn -> flunk("asked although a key is held") end)
      assert RelayKeys.sweep(later(7 * 3_600)) == 0
    end

    test "once it is upgraded, the next slow retry or Try again gets one", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      answers(404, %{"error" => "not_found"})
      RelayKeys.sweep()

      site([@key_a])
      assert RelayKeys.sweep(later(7 * 3_600)) == 1
      assert %{state: :held, origin: :fetched, fallback?: false} = RelayKeys.status(reload(t))
    end
  end

  describe "offline" do
    test "waits without a word, backs off, and fetches when the site is back", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      before = actions(t)
      offline()

      log = capture_log(fn -> assert RelayKeys.sweep() == 0 end)
      refute log =~ "error"

      assert %{state: :fetching, reason: "unreachable"} = RelayKeys.status(t)
      assert %RelayRequest{state: "wanted", attempts: 1, next_attempt_at: next} = row(t)
      assert DateTime.diff(next, DateTime.utc_now()) in 25..35
      # Nothing for the audit trail: a hall without network is not an event.
      assert actions(t) == before

      # Not asked again before it is due.
      site(fn _conn -> flunk("asked before the backoff ran out") end)
      assert RelayKeys.sweep() == 0

      offline()
      assert RelayKeys.sweep(later(40)) == 0
      assert %RelayRequest{attempts: 2} = row(t)

      site([@key_a])
      assert RelayKeys.sweep(later(200)) == 1
      assert reload(t).openresults_relay_key == @key_a
      assert %RelayRequest{state: "held", attempts: 0, reason: nil} = row(t)
    end

    test "one silence ends the pass for every tournament", %{scope: scope} do
      for name <- ["One", "Two", "Three"] do
        t = published(scope, %{name: name})
        {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      end

      test = self()

      site(fn conn ->
        send(test, :dialled)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert RelayKeys.sweep() == 0
      assert_received :dialled
      refute_received :dialled
    end
  end

  describe "other answers" do
    test "not there yet, paused, rate limited: asked again by itself", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)

      answers(404, %{"error" => "tournament_not_published"})
      RelayKeys.sweep()

      assert %{state: :fetching, reason: "tournament_not_published", fallback?: false} =
               RelayKeys.status(t)

      answers(429, %{"error" => "rate_limited", "retry_after" => 500}, [{"retry-after", "500"}])
      RelayKeys.sweep(later(40))

      assert %RelayRequest{state: "wanted", reason: "rate_limited", next_attempt_at: next} =
               row(t)

      assert DateTime.diff(next, DateTime.utc_now()) > 500

      answers(503, %{"error" => "publishing_paused"})
      RelayKeys.sweep(later(600))
      assert %{state: :fetching, reason: "publishing_paused"} = RelayKeys.status(t)
      refute "boards.relay_key_refused" in actions(t)
    end

    test "a refusal is kept as the site's code, audited once, and Try again asks", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      answers(403, %{"error" => "not_owner", "detail" => "Test."})

      RelayKeys.sweep()
      RelayKeys.sweep(later(7 * 3_600))

      assert %{state: :refused, reason: "not_owner", fallback?: false} = RelayKeys.status(t)
      assert Enum.count(actions(t), &(&1 == "boards.relay_key_refused")) == 1

      stranger = user_scope_fixture()
      assert {:error, :not_found} = BoardLink.retry_relay_key(stranger, t)

      site([@key_a])
      assert {:ok, _} = BoardLink.retry_relay_key(scope, t)
      assert %{state: :fetching} = RelayKeys.status(t)
      assert RelayKeys.sweep() == 1
    end

    test "a 200 that is not this API's is not a key", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      answers(200, %{"relay_key" => "something else entirely"})

      assert RelayKeys.sweep() == 0
      assert reload(t).openresults_relay_key == nil
      assert %{state: :refused, reason: "unsupported"} = RelayKeys.status(t)
    end
  end

  describe "replacing" do
    setup %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a, @key_b])
      RelayKeys.sweep()
      asked()
      {:ok, t: reload(t)}
    end

    test "asks again; the new key replaces the old", %{scope: scope, t: t} do
      assert {:ok, _} = BoardLink.replace_relay_key(scope, t)
      assert %{state: :held, hint: "AAAA", replacing?: true} = RelayKeys.status(t)

      assert RelayKeys.sweep() == 1
      assert [{"POST", _path, _headers, _body}] = asked()

      t = reload(t)
      assert t.openresults_relay_key == @key_b
      assert %{state: :held, hint: "BBBB", replacing?: false, problem: nil} = RelayKeys.status(t)

      log = Repo.all(from a in AuditLog, where: a.tournament_id == ^t.id, order_by: a.id)
      assert "boards.relay_key_replace" in Enum.map(log, & &1.action)

      assert [%{"replaced" => false}, %{"replaced" => true}] =
               for(%{action: "boards.relay_key_fetched", details: d} <- log, do: d)
    end

    test "offline, the old key is kept until the new one is here", %{scope: scope, t: t} do
      {:ok, _} = BoardLink.replace_relay_key(scope, t)
      offline()
      RelayKeys.sweep()

      assert reload(t).openresults_relay_key == @key_a
      assert %{state: :held, hint: "AAAA", replacing?: true} = RelayKeys.status(reload(t))

      site([@key_b])
      assert RelayKeys.sweep(later(40)) == 1
      assert reload(t).openresults_relay_key == @key_b
    end

    test "refused, the old key is kept and it is not asked again by itself", %{scope: scope, t: t} do
      {:ok, _} = BoardLink.replace_relay_key(scope, t)
      answers(403, %{"error" => "tournament_hidden"})
      RelayKeys.sweep()

      t = reload(t)
      assert t.openresults_relay_key == @key_a

      assert %{state: :held, hint: "AAAA", replacing?: false, problem: "tournament_hidden"} =
               RelayKeys.status(t)

      site(fn _conn -> flunk("asked again by itself") end)
      assert RelayKeys.sweep(later(7 * 3_600)) == 0
    end

    test "only somebody who may edit the tournament", %{t: t} do
      assert {:error, :not_found} = BoardLink.replace_relay_key(user_scope_fixture(), t)
      refute row(t).replace
    end

    test "a tournament that moved to another address gets a key for that one", %{t: t} do
      moved =
        t |> Ecto.Changeset.change(public_slug: "moved-#{t.id}") |> Repo.update!()

      assert %{state: :held, replacing?: true} = RelayKeys.status(moved)
      assert RelayKeys.sweep() == 1
      assert [{"POST", path, _headers, _body}] = asked()
      assert path == "#{@path_prefix}moved-#{t.id}/relay-keys"
      assert %RelayRequest{slug: slug} = row(t)
      assert slug == "moved-#{t.id}"
    end
  end

  describe "leaving the results site" do
    test "a takedown drops the key here; the site deletes its half itself", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a])
      RelayKeys.sweep()
      asked()

      site(fn conn -> Server.json(conn, 200, %{"status" => "deleted"}) end)
      assert {:ok, _message} = Publishing.take_down(reload(t))

      t = reload(t)
      assert t.openresults_relay_key == nil
      assert row(t) == nil
      assert %{state: :no_site} = RelayKeys.status(t)

      # And nothing asks for a new one for a tournament that is not there.
      site(fn _conn -> flunk("asked for a tournament that was taken down") end)
      assert RelayKeys.sweep() == 0
    end
  end

  describe "what does not travel, and what is not written down" do
    test "the key is in no export, and neither is the bookkeeping", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a])
      RelayKeys.sweep()

      json = t |> reload() |> TournamentExport.export_tournament() |> Jason.encode!()
      refute json =~ @key_a
      refute json =~ "orrk_"
      assert :board_relay_requests in TournamentExport.excluded_tables()
    end

    test "the key is in no log line and not in the audit trail", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site([@key_a])

      log =
        capture_log([level: :debug], fn ->
          RelayKeys.sweep()
          # What a careless `inspect` in a log line would print.
          require Logger
          Logger.info(inspect(reload(t)))
        end)

      assert reload(t).openresults_relay_key == @key_a
      refute log =~ @key_a
      refute log =~ String.slice(@key_a, 5, 20)

      trail = Repo.all(from a in AuditLog, where: a.tournament_id == ^t.id) |> inspect()
      assert trail =~ "boards.relay_key_fetched"
      assert trail =~ "AAAA"
      refute trail =~ @key_a
    end

    test "a sweep that trips over something does not raise, and logs no row", %{scope: scope} do
      t = published(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      site(fn _conn -> raise "the stub fell over" end)

      log = capture_log(fn -> assert RelayKeys.sweep() == 0 end)
      assert log =~ "relay key sweep failed"
      refute log =~ t.openresults_key
    end
  end

  describe "a desktop copy" do
    setup do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)

      Publishing.put_endpoint(nil)
      Publishing.put_token(nil)
      :ok
    end

    defp on_public_site(scope) do
      published(scope, %{
        public_slug_minted_at: DateTime.utc_now(:second),
        public_slug_server: Publishing.endpoint(),
        public_slug_published_at: DateTime.utc_now(:second)
      })
    end

    test "asks under its installation key, once it has one", %{scope: scope} do
      relay = fn conn -> Server.json(conn, 201, %{"relay_key" => @key_a}) end

      # Before the arbiter agreed to anything: nothing is sent at all.
      Server.install(self())
      t = on_public_site(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      assert RelayKeys.sweep() == 0
      assert Server.calls() == []

      {:ok, info} = Installation.server_info()
      :ok = Installation.give_consent(info)
      {:ok, _id} = Installation.register()
      Server.requests()

      Server.install(self(), %{{"POST", "#{@path_prefix}#{t.public_slug}/relay-keys"} => relay})
      assert RelayKeys.sweep() == 1

      assert [{"POST", _path, headers, _body}] = Server.requests()
      assert headers["authorization"] == "Bearer " <> Server.key()
      assert headers[Publishing.key_header()] == t.openresults_key
      assert reload(t).openresults_relay_key == @key_a
    end

    test "offline it just waits", %{scope: scope} do
      Server.install(self())
      {:ok, info} = Installation.server_info()
      :ok = Installation.give_consent(info)
      {:ok, _id} = Installation.register()

      t = on_public_site(scope)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)
      offline()

      assert RelayKeys.sweep() == 0
      assert %{state: :fetching, reason: "unreachable"} = RelayKeys.status(t)
    end
  end
end
