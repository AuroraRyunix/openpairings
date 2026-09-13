defmodule PairingsEngine.PublicPublishingTest do
  @moduledoc """
  Public publishing, the desktop side: OpenResults' `docs/public-publishing.md`,
  "OpenPairings desktop". Built against that document with the server stubbed
  (`PairingsEngine.PublicServerStub`), because the server half is being built
  in parallel.

  Most of what is pinned is what must NOT happen: a request before an arbiter
  has switched publishing on, a registration without consent, a registration
  nobody asked for after a revocation, a hosted server registering itself,
  and a key reaching a server that did not issue it.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.{Failure, Installation, Monitor, QueueEntry}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}
  alias PairingsEngineWeb.Components.ConnectionStatus
  alias PairingsEngineWeb.PublicLink

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
    Publishing.put_public_base(nil)
    Publishing.put_token(nil)
    :ok
  end

  defp local_mode(on?), do: Application.put_env(:pairings_engine, :local_mode, on?)

  defp tournament(opts \\ []) do
    t =
      Repo.insert!(%Tournament{
        name: Keyword.get(opts, :name, "Gent Spring Open"),
        type: "swiss",
        rounds_count: 3,
        publish_to_openresults: Keyword.get(opts, :publish, true),
        public_slug: "placeholder#{System.unique_integer([:positive])}"
      })

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1800}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          fide_rating: rating,
          pairing_number: 2001 - rating
        })
      end

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Tournaments.get_tournament!(t.id)
  end

  defp consent! do
    {:ok, info} = Installation.server_info()
    :ok = Installation.give_consent(info)
    info
  end

  # A registered installation, through the real requests.
  defp register! do
    Server.install(self())
    consent!()
    {:ok, _id} = Installation.register()
    Server.requests()
    :ok
  end

  defp make_due(tournament_id) do
    Repo.update_all(
      from(q in QueueEntry, where: q.tournament_id == ^tournament_id),
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp bearer(headers), do: headers["authorization"]

  describe "which mode applies" do
    test "a local run with nothing configured defaults to the public results site" do
      assert Publishing.endpoint() == "https://openresults.zerotwo.cloud"
      assert Publishing.public_base() == "https://openresults.zerotwo.cloud"
      assert Publishing.stored_endpoint() == nil
      assert Publishing.mode() == :public
      assert Publishing.public_mode?()
      assert Publishing.configured?()
    end

    test "hosted mode has no default and never enters public mode" do
      local_mode(false)

      assert Publishing.endpoint() == nil
      assert Publishing.mode() == :unconfigured
      refute Publishing.public_mode?()
      refute Publishing.configured?()

      # Even with an address, and even with a consent somebody planted in the
      # table, a hosted server sends nothing that could register it.
      Publishing.put_endpoint("https://openresults.zerotwo.cloud")
      Installation.give_consent(%{host: "openresults.zerotwo.cloud", operator: nil})
      t = tournament()
      Publishing.enqueue(t)
      Server.install(self())

      assert Publishing.check() == {:error, {:unconfigured, :no_token}}
      assert {:error, "no OpenResults server is configured"} = Publishing.publish(t)
      assert {0, _} = Publishing.drain()
      assert {:error, %Failure{reason: {:unconfigured, :no_token}}} = Installation.register()
      assert {:error, %Failure{}} = Installation.mint(t)

      assert Server.requests() == []
    end

    test "an operator token makes it operator mode, local or not" do
      Publishing.put_token("operators-token")
      assert Publishing.mode() == :operator
      refute Publishing.public_mode?()
    end
  end

  describe "nothing is sent before publishing is turned on" do
    test "the check, the status and the Monitor send nothing" do
      _off = tournament(publish: false)
      Req.Test.set_req_test_to_shared(%{})
      Server.install(self())

      assert Publishing.check() == {:error, {:unconfigured, :public_idle}}
      assert %{state: :unconfigured, mode: :public} = Publishing.status()

      # The Monitor's own tick, run in this process so its task reports here.
      state = %{
        intervals: {60_000, 60_000},
        history: [],
        started_at: DateTime.utc_now(),
        last_failure_at: nil
      }

      Monitor.handle_info(:check_connection, state)
      assert_receive {:connection, %{state: :unconfigured}}, 2_000

      assert Server.requests() == []
    end

    test "what runs at boot - the backfill, the drain, the registration poll - sends nothing" do
      # Switched on by something other than an arbiter answering the consent
      # dialog - the 2026-08-29 migration did exactly that.
      t = tournament()
      Server.install(self())

      assert Publishing.backfill() == 1
      assert Publishing.queued(t.id)
      assert {0, 0} = Publishing.drain()
      assert PairingsEngine.Registrations.Poll.poll_now() == {0, 0}

      refute Publishing.can_send?()
      assert Publishing.check() == {:error, {:unconfigured, :consent_required}}
      assert Server.requests() == []
    end

    test "without consent there is nothing a publish may send" do
      t = tournament()
      Server.install(self())

      assert {:error, %Failure{reason: {:unconfigured, :consent_required}}} =
               Publishing.publish(t)

      assert Server.requests() == []
    end
  end

  describe "the whole way through" do
    test "server, consent, installation, mint, publish - in that order, with the right credentials" do
      t = tournament()
      Server.install(self())

      # 1. The question for the dialog, with no credential.
      info = consent!()
      assert info.operator == "ZeroTwo"
      assert info.terms_url == "https://openresults.zerotwo.cloud/terms"
      assert info.host == "openresults.zerotwo.cloud"

      assert [{"GET", "/api/server", headers, _}] = Server.requests()
      refute bearer(headers)

      # 2-5, from the queue.
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()

      assert [
               {"POST", "/api/installations", register_headers, register_body},
               {"POST", "/api/tournaments", mint_headers, "{}"},
               {"POST", "/api/snapshots", publish_headers, snapshot}
             ] = Server.requests()

      refute bearer(register_headers)

      assert %{"client" => "OpenPairings", "client_version" => version} =
               Jason.decode!(register_body)

      assert is_binary(version)
      assert bearer(mint_headers) == "Bearer " <> Server.key()
      assert bearer(publish_headers) == "Bearer " <> Server.key()

      minted = Tournaments.get_tournament!(t.id)
      refute minted.public_slug == t.public_slug
      assert minted.public_slug_minted_at
      assert publish_headers["x-openresults-key"] == minted.openresults_key
      assert Jason.decode!(snapshot)["tournament"]["slug"] == minted.public_slug

      assert Installation.id() == Server.installation_id()
      assert PublicLink.url(minted) == "https://openresults.zerotwo.cloud/t/#{minted.public_slug}"

      # Once per installation, once per tournament: the next publish is just
      # the publish.
      Publishing.enqueue(minted)
      assert {1, 0} = Publishing.drain()
      assert [{"POST", "/api/snapshots", _, _}] = Server.requests()
    end

    test "offline at a step keeps publishing requested, retried later, with no link meanwhile" do
      t = tournament()
      register!()

      Server.install(self(), %{
        {"POST", "/api/tournaments"} => &Req.Test.transport_error(&1, :econnrefused)
      })

      Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()

      entry = Publishing.queued(t.id)
      refute entry.stopped_at
      assert %Failure{reason: {:unreachable, :econnrefused}} = Failure.decode(entry.last_reason)
      assert DateTime.compare(entry.next_attempt_at, DateTime.utc_now()) == :gt

      waiting = Tournaments.get_tournament!(t.id)
      refute PublicLink.public?(waiting)
      assert PublicLink.pending?(waiting)
      assert %{step: :first_copy} = Publishing.public_state(waiting)

      Server.install(self())
      make_due(t.id)
      assert {1, 0} = Publishing.drain()
      assert PublicLink.public?(Tournaments.get_tournament!(t.id))
    end

    test "several queued tournaments register once, then mint and publish each" do
      tournaments = for _ <- 1..3, do: tournament()
      Server.install(self())
      consent!()
      Server.requests()

      Enum.each(tournaments, &Publishing.enqueue/1)
      assert {3, 0} = Publishing.drain()

      calls = Server.calls()
      assert Enum.count(calls, &(&1 == {"POST", "/api/installations"})) == 1
      assert Enum.count(calls, &(&1 == {"POST", "/api/tournaments"})) == 3
      assert Enum.count(calls, &(&1 == {"POST", "/api/snapshots"})) == 3
    end

    for what <- [:registration_closed, :rate_limited, :offline] do
      @what what

      test "#{what}: asked once for the whole pass, not once per queued tournament" do
        tournaments = for _ <- 1..3, do: tournament()
        Server.install(self())
        consent!()
        Server.requests()

        answer =
          case @what do
            :registration_closed -> Server.error(503, "registration_closed")
            :rate_limited -> Server.error(429, "rate_limited", %{"retry_after" => 60})
            :offline -> &Req.Test.transport_error(&1, :econnrefused)
          end

        Server.install(self(), %{{"POST", "/api/installations"} => answer})
        Enum.each(tournaments, &Publishing.enqueue/1)
        capture_log(fn -> assert {0, 3} = Publishing.drain() end)

        assert Server.calls() == [{"POST", "/api/installations"}]

        # Every row carries the answer and a backoff, so none of them is
        # sent again on the next tick.
        for t <- tournaments do
          entry = Publishing.queued(t.id)
          assert entry.attempts == 1
          assert Failure.decode(entry.last_reason)
          assert DateTime.compare(entry.next_attempt_at, DateTime.utc_now()) == :gt
        end
      end
    end

    test "a per-tournament refusal does not stop the others in the pass" do
      too_big = tournament(name: "Too Big Open")
      fine = tournament(name: "Fine Open")
      register!()

      Publishing.enqueue(too_big)
      Publishing.enqueue(fine)

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => fn conn ->
          if Jason.decode!(conn.assigns.raw_body)["tournament"]["name"] == "Too Big Open",
            do: Server.error(413, "snapshot_too_large", %{"limit_bytes" => 3_145_728}).(conn),
            else: Server.json(conn, 200, %{"ok" => true})
        end
      })

      capture_log(fn -> assert {1, 1} = Publishing.drain() end)
      assert Publishing.queued(too_big.id).stopped_at
      refute Publishing.queued(fine.id)
    end

    test "consent given offline is kept, and registration is retried by the drain" do
      t = tournament()
      Server.install(self())
      consent!()
      Server.requests()

      Server.install(self(), %{
        {"POST", "/api/installations"} => &Req.Test.transport_error(&1, :timeout)
      })

      Publishing.enqueue(t)
      assert {0, 1} = Publishing.drain()
      assert %{step: :register} = Publishing.public_state(Tournaments.get_tournament!(t.id))

      Server.install(self())
      make_due(t.id)
      assert {1, 0} = Publishing.drain()
      assert Installation.registered?()
    end
  end

  describe "every refusal, in the contract's table" do
    # {code, status, where, extra body fields, expected stop, en, nl}
    @cases [
      {"rate_limited", 429, "/api/snapshots", %{"retry_after" => 900}, nil,
       "The results site asked this computer to wait a moment. It will try again shortly.",
       "De uitslagensite vroeg deze computer om even te wachten. Er wordt straks opnieuw geprobeerd."},
      {"publishing_paused", 503, "/api/snapshots", %{}, nil,
       "The results site has paused publishing. Everything waiting is sent when it resumes.",
       "De uitslagensite heeft publiceren gepauzeerd. Alles wat wacht, wordt verzonden zodra het weer kan."},
      {"installation_suspended", 403, "/api/snapshots", %{}, nil,
       "The results site has suspended this computer's key. Contact the operator of the results site.",
       "De uitslagensite heeft de sleutel van deze computer geschorst. Neem contact op met de beheerder van de uitslagensite."},
      {"installation_revoked", 403, "/api/snapshots", %{}, :installation,
       "The results site no longer accepts this computer's key. Publishing has stopped.",
       "De uitslagensite aanvaardt de sleutel van deze computer niet meer. Publiceren is gestopt."},
      {"tournament_limit", 403, "/api/tournaments", %{"limit" => 50}, :tournament,
       "This computer already has 50 tournaments on the results site, which is its limit. Publishing has stopped for this tournament.",
       "Deze computer heeft al 50 toernooien op de uitslagensite, en dat is de limiet. Publiceren is gestopt voor dit toernooi."},
      {"snapshot_too_large", 413, "/api/snapshots", %{"limit_bytes" => 1_048_576}, :tournament,
       "This tournament is too large for the results site, which accepts at most 1.0 MB. Publishing has stopped for this tournament.",
       "Dit toernooi is te groot voor de uitslagensite, die hoogstens 1.0 MB aanvaardt. Publiceren is gestopt voor dit toernooi."},
      {"not_owner", 403, "/api/snapshots", %{}, :tournament,
       "A different installation owns this tournament on the results site. Ask the operator of the results site to transfer it to this computer.",
       "Een andere installatie is eigenaar van dit toernooi op de uitslagensite. Vraag de beheerder van de uitslagensite om het naar deze computer over te dragen."},
      {"tournament_hidden", 403, "/api/snapshots", %{}, :tournament,
       "The operator of the results site has hidden this tournament. Publishing has stopped for this tournament.",
       "De beheerder van de uitslagensite heeft dit toernooi verborgen. Publiceren is gestopt voor dit toernooi."},
      {"registration_closed", 503, "/api/installations", %{}, nil,
       "The results site is not accepting new installations right now. Nothing has been sent, and it will be tried again later.",
       "De uitslagensite aanvaardt op dit moment geen nieuwe installaties. Er is niets verzonden, en het wordt later opnieuw geprobeerd."},
      {"address_blocked", 403, "/api/snapshots", %{}, :installation,
       "The results site has blocked this computer's network address. Contact the operator of the results site.",
       "De uitslagensite heeft het netwerkadres van deze computer geblokkeerd. Neem contact op met de beheerder van de uitslagensite."},
      {"unauthorized", 401, "/api/snapshots", %{}, :installation,
       "The results site does not recognise this computer's key. Publishing has stopped until you register again.",
       "De uitslagensite herkent de sleutel van deze computer niet. Publiceren is gestopt tot je opnieuw registreert."}
    ]

    for {code, status, path, extra, stop, en, nl} <- @cases do
      @code code
      @status status
      @path path
      @extra extra
      @stop stop
      @en en
      @nl nl

      test "#{code}" do
        t = tournament()

        if @path == "/api/installations" do
          Server.install(self())
          consent!()
        else
          register!()
        end

        Server.install(self(), %{{"POST", @path} => Server.error(@status, @code, @extra)})
        Publishing.enqueue(t)

        capture_log(fn -> assert {0, 1} = Publishing.drain() end)

        # Never further than the step that was refused.
        calls = Server.calls()
        assert List.last(calls) == {"POST", @path}

        if @path != "/api/snapshots", do: refute({"POST", "/api/snapshots"} in calls)

        entry = Publishing.queued(t.id)
        failure = Failure.decode(entry.last_reason)
        assert failure.stop == @stop
        assert Failure.effective_code(elem(failure.reason, 1)) == @code

        # The words, in both languages, with the number the server sent.
        extras = %{limit: failure.limit}

        assert Gettext.with_locale(PairingsEngineWeb.Gettext, "en", fn ->
                 ConnectionStatus.describe_public(failure.reason, extras)
               end) == @en

        assert Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
                 ConnectionStatus.describe_public(failure.reason, extras)
               end) == @nl

        # The queue, as the table says.
        case @stop do
          :tournament ->
            assert entry.stopped_at
            assert Publishing.due() == []

          :installation ->
            refute entry.stopped_at
            assert Installation.halted?()
            make_due(t.id)
            assert {0, 0} = Publishing.drain()
            assert Server.requests() == []

          nil ->
            refute entry.stopped_at
        end
      end
    end

    test "rate_limited backs off at least retry_after, from the body or the header" do
      t = tournament()
      register!()

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(429, "rate_limited", %{"retry_after" => 900})
      })

      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)

      entry = Publishing.queued(t.id)
      # The ordinary first backoff is 30 seconds; the server asked for 900.
      assert DateTime.diff(entry.next_attempt_at, DateTime.utc_now()) >= 890
      assert Failure.decode(entry.last_reason).stop == nil

      # A header, with no field in the body.
      Server.install(self(), %{
        {"POST", "/api/snapshots"} => fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "600")
          |> Server.json(429, %{"error" => "rate_limited"})
        end
      })

      make_due(t.id)
      capture_log(fn -> Publishing.drain() end)
      assert DateTime.diff(Publishing.queued(t.id).next_attempt_at, DateTime.utc_now()) >= 590

      # Not a state the top bar shows: "nothing unless it persists".
      refute Installation.state()
    end

    for {code, status, extra} <- [
          {"rate_limited", 429, %{"retry_after" => 300}},
          {"publishing_paused", 503, %{}}
        ] do
      @code code
      @status status
      @extra extra

      test "minting shares the publish budget and its refusals: #{code} on the mint keeps the row" do
        t = tournament()
        register!()

        Server.install(self(), %{
          {"POST", "/api/tournaments"} => Server.error(@status, @code, @extra)
        })

        Publishing.enqueue(t)
        capture_log(fn -> assert {0, 1} = Publishing.drain() end)

        assert Server.calls() == [{"POST", "/api/tournaments"}]
        entry = Publishing.queued(t.id)
        refute entry.stopped_at

        assert %Failure{stop: nil, reason: {:refused, {:rejected, @status, @code, _}}} =
                 Failure.decode(entry.last_reason)

        if @extra["retry_after"],
          do: assert(DateTime.diff(entry.next_attempt_at, DateTime.utc_now()) >= 290)

        refute PublicLink.public?(Tournaments.get_tournament!(t.id))
      end
    end

    test "a gated-off server's own 404, with no error code, means no public publishing - not a crash" do
      not_found = &Server.json(&1, 404, %{"errors" => %{"detail" => "Not Found"}})

      # At registration.
      t = tournament()
      Server.install(self())
      consent!()
      Server.install(self(), %{{"POST", "/api/installations"} => not_found})
      Publishing.enqueue(t)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      assert %Failure{reason: {:unconfigured, :token_required}} =
               Failure.decode(Publishing.queued(t.id).last_reason)

      # At the mint, for an installation registered before the gate went off.
      Server.install(self())
      {:ok, _} = Installation.register()
      Server.install(self(), %{{"POST", "/api/tournaments"} => not_found})
      make_due(t.id)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      assert %Failure{reason: {:unconfigured, :token_required}} =
               Failure.decode(Publishing.queued(t.id).last_reason)

      assert Gettext.with_locale(PairingsEngineWeb.Gettext, "en", fn ->
               ConnectionStatus.describe_public({:unconfigured, :token_required})
             end) ==
               "This results site only publishes tournaments sent with a token from its operator."
    end

    test "a hidden tournament's owner can still take it down" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      Publishing.drain()

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(403, "tournament_hidden")
      })

      published = Tournaments.get_tournament!(t.id)
      Publishing.enqueue(published)
      make_due(t.id)
      capture_log(fn -> Publishing.drain() end)
      assert Publishing.queued(t.id).stopped_at

      Server.install(self())
      assert {:ok, _} = Publishing.take_down(Tournaments.get_tournament!(t.id))
    end

    test "a stopped tournament goes again only when the arbiter tries again" do
      t = tournament()
      register!()

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)
      Server.requests()

      # More results keep being entered: still stopped, still nothing sent.
      Publishing.enqueue(Tournaments.get_tournament!(t.id))
      make_due(t.id)
      assert {0, 0} = Publishing.drain()
      assert Server.requests() == []

      Server.install(self())
      assert Publishing.retry(t.id)
      assert {1, 0} = Publishing.drain()
      refute Publishing.queued(t.id)
    end

    test "address_blocked is answered by trying again, not by registering again" do
      t = tournament()
      register!()

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "address_blocked")})

      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)
      assert Installation.halted?()
      assert Installation.registered?()

      Server.install(self())
      Publishing.retry(t.id)
      refute Installation.halted?()
      assert {1, 0} = Publishing.drain()
      refute {"POST", "/api/installations"} in Server.calls()
    end

    test "a pause that is over is noticed by the check, and what waited is made due" do
      t = tournament()
      register!()

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(503, "publishing_paused")
      })

      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)

      Server.install(self(), %{
        {"GET", "/api/server"} =>
          &Server.json(&1, 200, Server.server_body(%{"public_publishing" => "paused"}))
      })

      assert Publishing.check() ==
               {:error, {:refused, {:rejected, 503, "publishing_paused", nil}}}

      Server.install(self())
      assert Publishing.check() == :ok
      refute Installation.state()
      assert Publishing.due() != []
    end
  end

  describe "pulling entries in public mode" do
    defp published!(t) do
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      Server.requests()
      Tournaments.get_tournament!(t.id)
    end

    test "nothing is pulled before the first copy has arrived - minted or not" do
      t = tournament()
      register!()

      assert {:error, message} = PairingsEngine.Registrations.pull(t)
      assert message =~ "has reached the results site yet"

      # Minted, and the first publish refused: the entry form was never
      # reachable, so there is still nothing to collect.
      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(503, "publishing_paused")
      })

      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)
      minted = Tournaments.get_tournament!(t.id)
      assert Publishing.public_slug_state(minted) == :minted
      Server.requests()

      assert {:error, _} = PairingsEngine.Registrations.pull(minted)
      assert Server.requests() == []
    end

    test "a blocked address may still read what it owns; a dead key may not" do
      t = tournament()
      register!()
      published = published!(t)

      Server.install(self(), %{
        {"GET", "/api/tournaments/#{published.public_slug}/registrations"} =>
          &Server.json(&1, 200, %{"registrations" => []})
      })

      # The contract lists `address_blocked` for registration, mint and
      # publish only - so the pull still goes, under this computer's key.
      Installation.put_state({:rejected, 403, "address_blocked", nil})
      assert Installation.halted?()
      assert {:ok, _} = PairingsEngine.Registrations.pull(published)

      assert [{"GET", _, headers, _}] = Server.requests()
      assert headers["authorization"] == "Bearer " <> Server.key()

      for code <- ["installation_revoked", "unauthorized"] do
        Installation.put_state({:rejected, 403, code, nil})
        assert {:error, _} = PairingsEngine.Registrations.pull(published)
      end

      assert Server.requests() == []
    end

    test "a refused pull is worded by its code, not called 'a different machine'" do
      t = tournament()
      register!()
      published = published!(t)

      Server.install(self(), %{
        {"GET", "/api/tournaments/#{published.public_slug}/registrations"} =>
          Server.error(403, "installation_suspended")
      })

      assert {:error, message} = PairingsEngine.Registrations.pull(published)
      # A real sentence for this code now (PairingsEngine.Registrations
      # reuses Publishing.rejection_of/1 and Failure.effective_code/1
      # instead of wording every answer from the HTTP status alone) - not
      # just the bare "answered 403: installation_suspended" this used to
      # fall back to, and still never "a different machine", which is
      # key_mismatch/key_required's sentence, not this code's.
      assert message ==
               "the results site has suspended this computer's key (403) - " <>
                 "contact the operator of the results site"

      refute message =~ "different machine"
    end
  end

  describe "the indicator in public mode" do
    test "a refusal remembered from a send shows no round trip, because none was made" do
      t = tournament()
      register!()
      Publishing.enqueue(t)
      Installation.put_state({:rejected, 403, "installation_revoked", nil})
      Server.requests()

      status = Publishing.status()
      assert status.state == :refused
      assert status.latency_ms == nil
      assert Server.requests() == []
    end

    test "registration reopening is noticed by the check, and what waited is made due" do
      t = tournament()
      Server.install(self())
      consent!()

      Server.install(self(), %{
        {"POST", "/api/installations"} => Server.error(503, "registration_closed")
      })

      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)
      assert {:rejected, 503, "registration_closed", nil} = Installation.state()

      Server.install(self(), %{
        {"GET", "/api/server"} =>
          &Server.json(&1, 200, Server.server_body(%{"public_registration" => "closed"}))
      })

      assert Publishing.check() ==
               {:error, {:refused, {:rejected, 503, "registration_closed", nil}}}

      Server.install(self())
      assert Publishing.check() == :ok
      refute Installation.state()
      assert Publishing.due() != []
    end
  end

  describe "never re-registered silently" do
    for {code, status} <- [{"installation_revoked", 403}, {"unauthorized", 401}] do
      @code code
      @status status

      test "after #{code}, nothing registers until the arbiter agrees again" do
        t = tournament()
        register!()
        old_key = Installation.key()

        Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(@status, @code)})
        Publishing.enqueue(t)
        capture_log(fn -> Publishing.drain() end)
        Server.requests()

        refute Installation.consented?()
        assert Installation.stopping_state?()

        # The drain, the check and a direct publish all leave it alone.
        make_due(t.id)
        assert {0, 0} = Publishing.drain()

        assert {:error, %Failure{stop: :installation}} =
                 Publishing.publish(Tournaments.get_tournament!(t.id))

        assert {:error, {:refused, {:rejected, _, @code, _}}} = Publishing.check()

        assert {:error, %Failure{reason: {:unconfigured, :consent_required}}} =
                 Installation.register()

        assert Server.requests() == []

        # "Register again": the dialog, then start over.
        Server.install(self())
        {:ok, info} = Installation.server_info()
        Installation.start_over(info)
        Server.requests()

        make_due(t.id)
        assert {1, 0} = Publishing.drain()
        assert {"POST", "/api/installations"} in Server.calls()
        assert Installation.key() == Server.key()
        refute Installation.state()
        # The stub hands out the same key; what matters is that the old one
        # was discarded rather than retried.
        assert is_binary(old_key)
      end
    end
  end

  describe "the key belongs to one server" do
    test "pointing this machine elsewhere hides the key rather than sending it there" do
      register!()
      assert Installation.registered?()

      Publishing.put_endpoint("https://results.somewhere-else.example")
      refute Installation.registered?()
      refute Installation.consented?()
      assert Installation.key() == nil

      Publishing.put_endpoint(nil)
      assert Installation.key() == Server.key()
    end
  end

  describe "an operator token entered later" do
    test "takes precedence: the token is sent, the key is not, and the minted address stays" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      minted = Tournaments.get_tournament!(t.id)
      Server.requests()

      Publishing.put_token("operators-token")
      assert Publishing.mode() == :operator

      assert {:ok, _} = Publishing.publish(minted)
      assert [{"POST", "/api/snapshots", headers, _}] = Server.requests()
      assert bearer(headers) == "Bearer operators-token"
      refute bearer(headers) =~ "orik_"

      assert Tournaments.get_tournament!(t.id).public_slug == minted.public_slug
      assert PublicLink.url(minted) =~ minted.public_slug
    end
  end

  describe "an operator token removed later" do
    test "a tournament published with it keeps its address - it is not silently moved" do
      t = tournament()
      Publishing.put_token("operators-token")
      Server.install(self())
      assert {:ok, _} = Publishing.publish(t)
      published = Tournaments.get_tournament!(t.id)
      assert published.openresults_key
      refute published.public_slug_minted_at

      # Back to no token: public mode, and a registered installation.
      Publishing.put_token(nil)
      register!()

      # The copy at the old slug is real, so its link stays, and there is
      # nothing to wait for.
      assert PublicLink.public?(published)
      refute PublicLink.pending?(published)

      # Minting instead would move it and strand the old copy. The publish
      # goes to the slug it has; the site binds it to no installation, says
      # so, and the arbiter is sent to the operator for a transfer.
      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      Publishing.enqueue(published)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      assert Server.calls() == [{"POST", "/api/snapshots"}]
      assert Tournaments.get_tournament!(t.id).public_slug == published.public_slug
      assert Publishing.queued(t.id).stopped_at
    end
  end

  describe "the link waits for the first copy, not the mint" do
    test "minted and refused: no link anywhere this module decides; the first success shows it" do
      t = tournament()
      register!()

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => Server.error(503, "publishing_paused")
      })

      Publishing.enqueue(t)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      minted = Tournaments.get_tournament!(t.id)
      assert minted.public_slug_minted_at
      refute minted.public_slug_published_at
      assert Publishing.public_slug_state(minted) == :minted

      # The server answers this slug like an unknown one, so a link now would
      # be dead.
      refute PublicLink.public?(minted)
      assert PublicLink.url(minted) == nil
      assert PublicLink.pending?(minted)
      refute Publishing.on_site?(minted)
      assert %{step: :first_copy} = Publishing.public_state(minted)

      Server.install(self())
      make_due(t.id)
      assert {1, 0} = Publishing.drain()

      published = Tournaments.get_tournament!(t.id)
      assert published.public_slug == minted.public_slug
      assert published.public_slug_published_at
      assert Publishing.public_slug_state(published) == :published
      assert PublicLink.url(published) =~ published.public_slug
    end
  end

  describe "a minted slug the server released" do
    # Minted, and the first publish lost to a dead connection: the shape a
    # tournament is in when the server releases its slug 30 days later.
    defp minted_never_published! do
      t = tournament()
      register!()

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => &Req.Test.transport_error(&1, :econnrefused)
      })

      Publishing.enqueue(t)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)
      Server.requests()

      minted = Tournaments.get_tournament!(t.id)
      assert Publishing.public_slug_state(minted) == :minted
      make_due(t.id)
      minted
    end

    test "never published and not_owner: a new slug is minted and the publish carries on, silently" do
      minted = minted_never_published!()
      released = minted.public_slug

      Server.install(self(), %{
        {"POST", "/api/snapshots"} => fn conn ->
          if Jason.decode!(conn.assigns.raw_body)["tournament"]["slug"] == released,
            do: Server.error(403, "not_owner").(conn),
            else: Server.json(conn, 200, %{"ok" => true})
        end
      })

      log = capture_log(fn -> assert {1, 0} = Publishing.drain() end)

      assert Server.calls() == [
               {"POST", "/api/snapshots"},
               {"POST", "/api/tournaments"},
               {"POST", "/api/snapshots"}
             ]

      carried_on = Tournaments.get_tournament!(minted.id)
      refute carried_on.public_slug == released
      assert Publishing.public_slug_state(carried_on) == :published
      # The tournament key is kept: it was never accepted under the old slug.
      assert carried_on.openresults_key == minted.openresults_key
      assert PublicLink.url(carried_on) =~ carried_on.public_slug

      # Nothing for the arbiter: no queue row, no stop, no state to show.
      refute Publishing.queued(minted.id)
      refute Installation.state()
      refute log =~ "publish failed"
    end

    test "re-minted once: if the new slug is refused too, that refusal is the answer" do
      minted = minted_never_published!()

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      calls = Server.calls()
      assert Enum.count(calls, &(&1 == {"POST", "/api/tournaments"})) == 1
      assert Publishing.queued(minted.id).stopped_at
    end

    test "published, then not_owner: never re-minted - the arbiter is sent to the operator" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      published = Tournaments.get_tournament!(t.id)
      assert Publishing.public_slug_state(published) == :published
      Server.requests()

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      Publishing.enqueue(published)

      # Several rounds of it - a first refusal, then the arbiter's Try again -
      # and not one mint among them.
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)
      assert Publishing.retry(t.id)
      capture_log(fn -> assert {0, 1} = Publishing.drain() end)

      refute {"POST", "/api/tournaments"} in Server.calls()

      after_refusals = Tournaments.get_tournament!(t.id)
      assert after_refusals.public_slug == published.public_slug
      assert Publishing.queued(t.id).stopped_at

      state = Publishing.public_state(after_refusals)
      assert {:refused, {:rejected, 403, "not_owner", _}} = state.failure.reason
      # Its link stays: the copy is real, only its ownership is in question.
      assert PublicLink.public?(after_refusals)
    end

    test "a takedown of a released, never-published slug has nothing to withdraw, and says so" do
      minted = minted_never_published!()

      Server.install(self(), %{{"DELETE", :any} => Server.error(403, "not_owner")})
      assert {:ok, message} = Publishing.take_down(minted)
      assert message =~ "Nothing of this tournament was on the results site"

      down = Tournaments.get_tournament!(minted.id)
      refute down.openresults_key
      refute down.public_slug_minted_at
      refute down.publish_to_openresults

      # And the bin's "Delete permanently" is no longer stuck behind it.
      assert :ok = Publishing.retract(down)
    end

    test "a published slug's takedown refused not_owner is still an error" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()

      Server.install(self(), %{{"DELETE", :any} => Server.error(403, "not_owner")})
      assert {:error, message} = Publishing.take_down(Tournaments.get_tournament!(t.id))
      assert message =~ "ask the operator"
      assert Tournaments.get_tournament!(t.id).openresults_key
    end
  end

  describe "a slug belongs to the server that minted it" do
    test "pointed elsewhere: no link, and a new slug there once the arbiter agrees" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      on_first = Tournaments.get_tournament!(t.id)
      assert on_first.public_slug_server == "https://openresults.zerotwo.cloud"
      Server.requests()

      Publishing.put_endpoint("https://results.club.example")
      assert Publishing.public_slug_state(on_first) == :elsewhere
      refute PublicLink.public?(on_first)
      assert PublicLink.pending?(on_first)

      # No key and no consent for this server: nothing is sent.
      Publishing.enqueue(on_first)
      assert {0, 0} = Publishing.drain()
      assert %{step: :consent} = Publishing.public_state(on_first)
      assert Server.requests() == []

      consent!()
      Server.requests()
      assert {1, 0} = Publishing.drain()

      assert Server.calls() == [
               {"POST", "/api/installations"},
               {"POST", "/api/tournaments"},
               {"POST", "/api/snapshots"}
             ]

      on_second = Tournaments.get_tournament!(t.id)
      refute on_second.public_slug == on_first.public_slug
      assert on_second.public_slug_server == "https://results.club.example"
      assert Publishing.public_slug_state(on_second) == :published

      assert PublicLink.url(on_second) ==
               "https://results.club.example/t/#{on_second.public_slug}"
    end

    test "a tournament published with an operator token is not bound to a server" do
      t = tournament()
      Publishing.put_token("operators-token")
      Server.install(self())
      assert {:ok, _} = Publishing.publish(t)
      Publishing.put_token(nil)

      keyed = Tournaments.get_tournament!(t.id)
      Publishing.put_endpoint("https://results.club.example")

      assert Publishing.public_slug_state(keyed) == :keyed
      assert PublicLink.url(keyed) == "https://results.club.example/t/#{keyed.public_slug}"
    end
  end

  describe "moving to a new address" do
    test "mints a new slug and deletes the copy under the old one" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      assert {1, 0} = Publishing.drain()
      published = Tournaments.get_tournament!(t.id)
      Server.requests()

      assert {:ok, moved, _message} = Publishing.rotate_address(published)

      assert [
               {"DELETE", delete_path, delete_headers, _},
               {"POST", "/api/tournaments", _, _},
               {"POST", "/api/snapshots", _, snapshot}
             ] = Server.requests()

      assert delete_path == "/api/tournaments/#{published.public_slug}"
      assert bearer(delete_headers) == "Bearer " <> Server.key()
      assert delete_headers["x-openresults-key"] == published.openresults_key

      refute moved.public_slug == published.public_slug
      assert moved.public_slug_minted_at
      assert Jason.decode!(snapshot)["tournament"]["slug"] == moved.public_slug
      assert PublicLink.url(moved) =~ moved.public_slug
    end

    test "a takedown forgets the minted address, so publishing again mints another" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      Publishing.drain()
      published = Tournaments.get_tournament!(t.id)

      assert {:ok, _} = Publishing.take_down(published)
      down = Tournaments.get_tournament!(t.id)
      refute down.public_slug_minted_at
      refute PublicLink.public?(down)
    end

    test "a revoked key can still withdraw its own tournament" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      Publishing.drain()
      published = Tournaments.get_tournament!(t.id)
      Installation.put_state({:rejected, 403, "installation_revoked", nil})
      Server.requests()

      assert {:ok, _} = Publishing.take_down(published)
      assert [{"DELETE", _, headers, _}] = Server.requests()
      assert bearer(headers) == "Bearer " <> Server.key()
    end

    test "not_owner on a takedown sends the arbiter to the operator" do
      t = tournament()
      register!()
      Server.install(self())
      Publishing.enqueue(t)
      Publishing.drain()
      published = Tournaments.get_tournament!(t.id)

      Server.install(self(), %{{"DELETE", :any} => Server.error(403, "not_owner")})
      assert {:error, message} = Publishing.take_down(published)
      assert message =~ "ask the operator"
    end
  end

  describe "a hand-off in public mode" do
    test "the receiving copy, having taken the key over, is told to ask for a transfer" do
      t = tournament()
      register!()

      adopted =
        t
        |> Ecto.Changeset.change(
          openresults_claim: %{"key" => "tk", "slug" => "OtherInstall1", "endpoint" => ""}
        )
        |> Repo.update!()

      assert {:ok, adopted} = Publishing.adopt_claim(adopted)
      # A claimed slug is a real address, not a placeholder to replace - and
      # not this installation's minting, so it is never re-minted silently:
      # that would abandon the very copy being taken over.
      refute adopted.public_slug_minted_at
      assert Publishing.public_slug_state(adopted) == :keyed

      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      Publishing.enqueue(adopted)
      capture_log(fn -> Publishing.drain() end)

      refute {"POST", "/api/tournaments"} in Server.calls()
      state = Publishing.public_state(Tournaments.get_tournament!(t.id))
      assert state.stopped?
      assert state.installation_id == Server.installation_id()
      assert {:refused, {:rejected, 403, "not_owner", nil}} = state.failure.reason
    end
  end

  describe "custody, where the key goes and does not" do
    test "never in a log line" do
      t = tournament()

      log =
        capture_log(fn ->
          register!()

          Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
          Publishing.enqueue(t)
          Publishing.drain()
        end)

      assert log =~ Server.installation_id() or log =~ "403 not_owner"
      refute log =~ Server.key()
      refute log =~ "orik_"
    end

    test "never in the queue row" do
      t = tournament()
      register!()
      Server.install(self(), %{{"POST", "/api/snapshots"} => Server.error(403, "not_owner")})
      Publishing.enqueue(t)
      capture_log(fn -> Publishing.drain() end)

      entry = Publishing.queued(t.id)
      refute inspect(entry) =~ "orik_"
    end
  end
end
