defmodule PairingsEngine.OpenResultsPublishContractTest do
  @moduledoc """
  The consumer's half of OpenResults' `publish-v1`, vendored under
  `priv/contracts/vendor/openresults/publish-v1/` (`mix contracts.sync`;
  `mix contracts.check` in CI says when it is out of date).

  Two directions, both through the real code with the server stubbed:

    * what OpenPairings SENDS - `Snapshot.build/1` on the contract fixtures
      (a team event, byes, forfeits, groups among them), and the installation,
      mint and relay-key bodies as the real callers build them - is valid
      against the provider's request schemas;
    * what OpenResults ANSWERS - every response example the provider ships,
      errors included - is taken by the real handling, and means here what
      the provider says it means.

  Offline: the vendored copy is what is checked, never the network.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures
  import PairingsEngineWeb.ContractHelpers

  alias PairingsEngine.{BoardLink, Publishing, Registrations, Repo, Snapshot, SnapshotFixtures}
  alias PairingsEngine.{TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.BoardLink.RelayKeys
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Publishing.{Failure, Installation}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @contract "vendor/openresults/publish-v1"

  # Every `error` code OpenPairings dispatches on by name somewhere
  # (`Failure`'s tables, `RelayKeys`' temporary codes, the claim check, the
  # pull's sentences, the takedown and the mint). A code the provider renames
  # or drops leaves one of these matching nothing, silently - this list
  # failing is the only notice anyone would get.
  @codes_handled ~w(
    address_blocked installation_key_required installation_revoked installation_suspended
    key_mismatch key_required not_found not_owner publishing_paused rate_limited
    registration_closed relay_key_limit snapshot_too_large storage_low tournament_deleted
    tournament_hidden tournament_limit tournament_not_published unauthorized
  )

  # The HTTP status each example error arrives with: the provider fixes one
  # per code (its docs/public-publishing.md, "Error bodies").
  @status %{
    "board_not_published" => 404,
    "invalid_moves" => 422,
    "rate_limited" => 429,
    "snapshot_too_large" => 413,
    "tournament_hidden" => 403,
    "not_owner" => 403,
    "key_mismatch" => 403
  }

  defp ex(file), do: example(@contract, file)

  # The results site: `answers.(method, path)` gives `{status, body}`; every
  # request is reported to the test as `{:sent, method, path, body}`.
  defp site(answers) do
    test = self()

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, conn.method, conn.request_path, body})
      {status, reply} = answers.(conn.method, conn.request_path)
      Server.json(conn, status, reply)
    end)
  end

  defp sent(method, path) do
    assert_received {:sent, ^method, ^path, body}
    Jason.decode!(body)
  end

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          %Tournament{
            name: "Gent Spring Open",
            type: "swiss",
            rounds_count: 3,
            publish_to_openresults: true,
            standings_through: 0,
            public_slug: "gent-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

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

  defp operator_mode(_context) do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_public_base(nil)
    Publishing.put_token("s3cret")
    :ok
  end

  defp published(t) do
    site(fn "POST", "/api/snapshots" -> {200, ex("snapshot.response.json")} end)
    assert {:ok, _} = Publishing.publish(t)
    Tournaments.get_tournament!(t.id)
  end

  describe "the vendored copy" do
    test "is whole: index.json lists it exactly, and every example fits its schema" do
      assert_index!(@contract)

      for {_file, schema, data} <- examples(@contract), do: assert_valid!(@contract, schema, data)

      # And the schemas have teeth: an empty document is not a snapshot.
      refute valid?(@contract, "snapshot.request.schema.json", %{})
    end

    test "every error code OpenPairings handles by name is one the provider can send" do
      known =
        @contract
        |> dir()
        |> Path.join("common.schema.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["definitions", "errorCode", "enum"])

      assert @codes_handled -- known == []
    end

    test "the stand-in server's own answers are the contract's shapes" do
      body = Jason.encode!(%{"tournament" => %{"slug" => "abcDEF123456"}})

      for {method, path, body, schema} <- [
            {"GET", "/api/server", "", "server.response.schema.json"},
            {"POST", "/api/installations", "", "installation.response.schema.json"},
            {"POST", "/api/tournaments", "", "mint.response.schema.json"},
            {"POST", "/api/snapshots", body, "snapshot.response.schema.json"},
            {"DELETE", "/api/tournaments/abcDEF123456", "", "takedown.response.schema.json"},
            {"GET", "/api/nowhere", "", "error.response.schema.json"}
          ] do
        {_status, answer} = Server.default_answer(method, path, body)
        assert_valid!(@contract, schema, answer)
      end
    end
  end

  describe "what OpenPairings sends" do
    # One test per fixture: they share slugs, so one database each.
    for {name, builder} <- SnapshotFixtures.contract_fixtures() do
      @builder builder
      test "the #{name} snapshot is a valid snapshot request" do
        snapshot = apply(SnapshotFixtures, @builder, []) |> Snapshot.build()
        assert_valid!(@contract, "snapshot.request.schema.json", snapshot)
      end
    end

    test "the team event and the byes are in there, so the check above means something" do
      team = SnapshotFixtures.team_snapshot_fixture_published() |> Snapshot.build()
      assert team["tournament"]["team_event"] || team["teams"] not in [nil, []]

      swiss = SnapshotFixtures.swiss_snapshot_tournament() |> Snapshot.build()
      assert swiss |> Jason.encode!() |> String.contains?("bye")
    end
  end

  describe "public mode: server, installation, mint, publish" do
    setup do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)
      Publishing.put_endpoint(nil)
      Publishing.put_public_base(nil)
      Publishing.put_token(nil)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:pairings_engine, :local_mode),
          else: Application.put_env(:pairings_engine, :local_mode, previous)
      end)
    end

    test "each example answer is taken, and each body sent is the contract's" do
      server = ex("server.response.json")
      installation = ex("installation.response.json")
      mint = ex("mint.response.json")

      site(fn
        "GET", "/api/server" -> {200, server}
        "POST", "/api/installations" -> {201, installation}
        "POST", "/api/tournaments" -> {201, mint}
        "POST", "/api/snapshots" -> {200, ex("snapshot.response.json")}
      end)

      assert {:ok, info} = Installation.server_info()
      assert info.operator == server["operator"]
      assert info.terms_url == server["terms_url"]
      assert info.public_registration == server["public_registration"]
      assert info.public_publishing == server["public_publishing"]

      :ok = Installation.give_consent(info)
      assert {:ok, id} = Installation.register()
      assert id == installation["installation_id"]
      assert Installation.key() == installation["key"]

      assert_valid!(
        @contract,
        "installation.request.schema.json",
        sent("POST", "/api/installations")
      )

      t = tournament()
      assert {:ok, minted} = Installation.mint(t)
      assert minted.public_slug == mint["slug"]
      assert_valid!(@contract, "mint.request.schema.json", sent("POST", "/api/tournaments"))

      assert {:ok, _} = Publishing.publish(Tournaments.get_tournament!(t.id))
      snapshot = sent("POST", "/api/snapshots")
      assert_valid!(@contract, "snapshot.request.schema.json", snapshot)
      assert snapshot["tournament"]["slug"] == mint["slug"]
    end

    test "every server state the contract names is one the consent dialog knows" do
      for registration <- ~w(unavailable open closed),
          publishing <- ~w(unavailable active paused) do
        answer =
          Map.merge(ex("server.response.json"), %{
            "public_registration" => registration,
            "public_publishing" => publishing
          })

        assert_valid!(@contract, "server.response.schema.json", answer)
        site(fn "GET", "/api/server" -> {200, answer} end)

        assert {:ok, %{public_registration: ^registration, public_publishing: ^publishing}} =
                 Installation.server_info()
      end
    end
  end

  describe "operator mode: publish, take down, entries, claim, relay keys" do
    setup :operator_mode

    test "a takedown's answer is taken as done" do
      t = tournament() |> published()
      assert_valid!(@contract, "snapshot.request.schema.json", sent("POST", "/api/snapshots"))

      site(fn "DELETE", _path -> {200, ex("takedown.response.json")} end)
      assert {:ok, _words} = Publishing.take_down(t)
      refute Publishing.published?(Tournaments.get_tournament!(t.id))
    end

    test "the entry queue example is pulled, entry by entry" do
      t = tournament() |> published()
      listing = ex("registrations.response.json")
      path = "/api/tournaments/#{t.public_slug}/registrations"
      site(fn "GET", ^path -> {200, listing} end)

      count = length(listing["registrations"])
      assert {:ok, %{new: ^count, total: ^count}} = Registrations.pull(t)

      stored = t.id |> Registrations.pending() |> Enum.map(& &1.payload["player"]["name"])
      expected = Enum.map(listing["registrations"], & &1["payload"]["player"]["name"])
      assert Enum.sort(stored) == Enum.sort(expected)

      # The id is what de-duplicates: the same listing again is nothing new.
      assert {:ok, %{new: 0, total: ^count}} = Registrations.pull(t)
    end

    test "both claim answers mean what the provider says" do
      for {file, adopted?} <- [
            {"claim.response.json", true},
            {"claim.response.unclaimed.json", false}
          ] do
        source = tournament() |> published()
        envelope = TournamentExport.export_tournament(source)
        assert {:ok, [imported]} = TournamentImport.import(envelope, scope())
        Repo.delete!(source)

        site(fn "GET", _claim -> {200, ex(file)} end)

        if adopted?,
          do: assert({:ok, %Tournament{}} = Publishing.adopt_claim(imported)),
          else: assert({:error, _} = Publishing.adopt_claim(imported))
      end
    end

    test "the relay-key example is held, and the body asked with is the contract's" do
      scope = user_scope_fixture()
      t = keyed(scope)
      answer = ex("relay-key.response.json")
      site(fn "POST", _path -> {201, answer} end)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)

      assert RelayKeys.sweep() == 1
      assert_received {:sent, "POST", _path, body}
      assert_valid!(@contract, "relay-key.request.schema.json", Jason.decode!(body))

      assert Tournaments.get_tournament!(t.id).openresults_relay_key == answer["relay_key"]
      assert %{state: :held, hint: hint} = RelayKeys.status(Tournaments.get_tournament!(t.id))
      assert hint == answer["hint"]
    end

    test "a 409 relay_key_limit stops the asking, under its own name" do
      scope = user_scope_fixture()
      t = keyed(scope)
      refusal = %{"error" => "relay_key_limit", "detail" => "Too many relay keys."}
      assert_valid!(@contract, "error.response.schema.json", refusal)
      site(fn "POST", _path -> {409, refusal} end)
      {:ok, _link, _secret} = BoardLink.create_link(scope, t)

      RelayKeys.sweep()
      assert %{state: :refused, reason: "relay_key_limit"} = RelayKeys.status(t)
    end

    test "every error example is read for its code and its extras" do
      for {"examples/" <> _ = file, "error.response.schema.json", body} <- examples(@contract) do
        status = Map.get(@status, body["error"], 403)

        failure =
          Publishing.failure_of(%Req.Response{status: status, body: body, headers: %{}})

        assert {:refused, {:rejected, ^status, code, _detail}} = failure.reason, file
        assert code == body["error"], file
        assert Failure.effective_code({:rejected, status, code, nil}) == body["error"]

        if seconds = body["retry_after"], do: assert(failure.retry_after == seconds, file)
        if bytes = body["limit_bytes"], do: assert(failure.limit == bytes, file)
      end
    end

    test "a publish refused with an example error is an error, never a crash" do
      t = tournament()

      for {_file, "error.response.schema.json", body} <- examples(@contract) do
        status = Map.get(@status, body["error"], 403)
        site(fn "POST", "/api/snapshots" -> {status, body} end)
        assert {:error, _} = Publishing.publish(Tournaments.get_tournament!(t.id))
      end
    end
  end

  defp keyed(scope) do
    slug = "relay-#{System.unique_integer([:positive])}"

    paired_tournament(scope, %{
      publish_to_openresults: true,
      openresults_key: "tk-#{slug}",
      public_slug: slug
    }).tournament
  end

  defp scope do
    Repo.insert!(%User{
      email: "contract#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Scope.for_user()
  end
end
