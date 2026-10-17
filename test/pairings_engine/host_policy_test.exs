defmodule PairingsEngine.HostPolicyTest do
  @moduledoc """
  The hostname settings: which hosts may open the websocket, and the
  opt-in 301 from an old host to the canonical one.

  The runtime half evaluates the real `config/runtime.exs`, as
  `PairingsEngine.LocalModeTest` does, so what is asserted is the file that
  ships.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PairingsEngineWeb.Plugs.CanonicalHost

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @server %{
    "DATABASE_PATH" => "/srv/op.db",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "SMTP_USERNAME" => "someone@example.com",
    "SMTP_PASSWORD" => "hunter2"
  }

  defp boot(vars) do
    all = Map.merge(@server, vars)
    names = Map.keys(all) ++ ["PHX_ALLOWED_HOSTS", "PHX_REDIRECT_HOSTS", "OPENRESULTS_PUBLIC_URL"]
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)
    Enum.each(all, fn {k, v} -> System.put_env(k, v) end)

    try do
      Config.Reader.read!(@runtime, env: :prod)
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp endpoint(config), do: config[:pairings_engine][PairingsEngineWeb.Endpoint]

  describe "check_origin" do
    test "is PHX_HOST alone when nothing else is set" do
      config = boot(%{"PHX_HOST" => "pairings.example.org"})
      assert endpoint(config)[:check_origin] == ["//pairings.example.org"]
      assert config[:pairings_engine][:host_policy][:redirect_hosts] == []
    end

    test "accepts the canonical, the allowed and the redirected hosts" do
      config =
        boot(%{
          "PHX_HOST" => "openpairings.cloud",
          "PHX_ALLOWED_HOSTS" => " Pairings.Old.Example , www.example.org",
          "PHX_REDIRECT_HOSTS" => "legacy.example.org,openpairings.cloud"
        })

      assert endpoint(config)[:check_origin] ==
               [
                 "//openpairings.cloud",
                 "//pairings.old.example",
                 "//www.example.org",
                 "//legacy.example.org"
               ]

      # The canonical host is never its own redirect source.
      assert config[:pairings_engine][:host_policy] ==
               [
                 canonical: "openpairings.cloud",
                 redirect_hosts: ["legacy.example.org"],
                 moved_to: nil
               ]
    end

    test "an entry that is not a hostname stops the boot" do
      for bad <- ["https://old.example.org", "old example", "-x.org"] do
        assert_raise RuntimeError, ~r/PHX_ALLOWED_HOSTS/, fn ->
          boot(%{"PHX_HOST" => "openpairings.cloud", "PHX_ALLOWED_HOSTS" => bad})
        end
      end
    end
  end

  describe "OPENRESULTS_PUBLIC_URL" do
    test "is read, without a trailing slash" do
      config =
        boot(%{
          "PHX_HOST" => "a.example.org",
          "OPENRESULTS_PUBLIC_URL" => "https://openresults.cloud/"
        })

      assert config[:pairings_engine][:openresults_public_url] == "https://openresults.cloud"
    end

    test "unset leaves the compiled default" do
      assert PairingsEngine.Publishing.default_public_server() ==
               "https://openresults.cloud"
    end
  end

  describe "CanonicalHost" do
    setup do
      previous = Application.get_env(:pairings_engine, :host_policy)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:pairings_engine, :host_policy, previous),
          else: Application.delete_env(:pairings_engine, :host_policy)
      end)
    end

    defp policy(redirect_hosts) do
      Application.put_env(:pairings_engine, :host_policy,
        canonical: "openpairings.cloud",
        redirect_hosts: redirect_hosts
      )
    end

    defp run(method, host, path \\ "/tournaments", query \\ "") do
      conn(method, path <> query) |> Map.put(:host, host) |> CanonicalHost.call([])
    end

    test "does nothing when no policy is configured" do
      Application.delete_env(:pairings_engine, :host_policy)
      conn = run(:get, "pairings.zerotwo.cloud")
      refute conn.halted
    end

    test "does nothing while the redirect list is empty (the default)" do
      policy([])
      refute run(:get, "pairings.zerotwo.cloud").halted
    end

    test "301s a GET on a listed old host, keeping path and query" do
      policy(["pairings.zerotwo.cloud"])
      conn = run(:get, "Pairings.ZeroTwo.Cloud", "/tournaments/3", "?tab=rounds")

      assert conn.status == 301
      assert conn.halted

      assert get_resp_header(conn, "location") ==
               ["https://openpairings.cloud/tournaments/3?tab=rounds"]
    end

    test "301s a HEAD too" do
      policy(["pairings.zerotwo.cloud"])
      assert run(:head, "pairings.zerotwo.cloud").status == 301
    end

    test "leaves a POST where it is, since a 301 would turn it into a GET" do
      policy(["pairings.zerotwo.cloud"])
      refute run(:post, "pairings.zerotwo.cloud", "/api/mobile/x").halted
    end

    test "leaves the canonical host and unlisted hosts alone" do
      policy(["pairings.zerotwo.cloud"])
      refute run(:get, "openpairings.cloud").halted
      refute run(:get, "127.0.0.1").halted
      refute run(:get, "localhost").halted
    end
  end
end
