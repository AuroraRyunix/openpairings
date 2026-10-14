defmodule PairingsEngine.LauncherDetailsTest do
  @moduledoc """
  `PairingsEngine.LauncherDetails` - the secret and its file - and
  `openpairings.sh details` (`PairingsEngine.LauncherDetails.CLI`) asking a
  real listener on loopback.
  """
  use PairingsEngine.DataCase, async: false

  import ExUnit.CaptureIO

  alias PairingsEngine.LauncherDetails
  alias PairingsEngine.LauncherDetails.CLI

  @name :launcher_details_under_test

  setup do
    dir = Path.join(System.tmp_dir!(), "op_details_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:pairings_engine, :launcher_token)
    end)

    %{dir: dir}
  end

  defp start(opts) do
    start_supervised!({LauncherDetails, [name: @name, local?: true] ++ opts})
  end

  describe "the secret" do
    test "without a launcher: made here, written for the owner only, gone on a clean stop",
         %{dir: dir} do
      start(env_token: nil, data_dir: dir)
      file = LauncherDetails.token_file(dir)

      assert [token, port] = file |> File.read!() |> String.split("\n", trim: true)
      assert token == LauncherDetails.token()
      assert byte_size(token) >= 32
      assert {_port, ""} = Integer.parse(port)

      if match?({:unix, _}, :os.type()) do
        assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
        assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700
      end

      assert LauncherDetails.authorized?(token)
      refute LauncherDetails.authorized?(token <> "x")
      refute LauncherDetails.authorized?(nil)

      stop_supervised!(LauncherDetails)

      refute File.exists?(file)
      assert LauncherDetails.token() == nil
      refute LauncherDetails.authorized?(token)
    end

    test "a launcher's secret is used as given, and no file is written", %{dir: dir} do
      start(env_token: "the-launcher-made-this-one-1234", data_dir: dir)

      assert LauncherDetails.token() == "the-launcher-made-this-one-1234"
      refute File.exists?(LauncherDetails.token_file(dir))
    end

    test "a hosted server has none" do
      start_supervised!({LauncherDetails, name: @name, local?: false})
      assert LauncherDetails.token() == nil
      refute LauncherDetails.authorized?("anything-at-all-really")
    end
  end

  describe "the numbers it keeps" do
    test "CPU: nothing to compare the first time, a percentage after", %{dir: dir} do
      start(env_token: nil, data_dir: dir)

      assert LauncherDetails.cpu_percent(@name) == nil
      assert percent = LauncherDetails.cpu_percent(@name)
      assert is_float(percent) and percent >= 0
    end

    test "slow queries: the slow ones, newest first, five at most", %{dir: dir} do
      pid = start(env_token: nil, data_dir: dir)
      fast = System.convert_time_unit(5, :millisecond, :native)

      LauncherDetails.handle_query([], %{total_time: fast}, %{source: "players", query: "q"}, pid)

      for ms <- 101..107 do
        native = System.convert_time_unit(ms, :millisecond, :native)

        LauncherDetails.handle_query(
          [],
          %{total_time: native},
          %{source: "games", query: "q"},
          pid
        )
      end

      slow = LauncherDetails.slow_queries(@name)
      assert length(slow) == 5
      assert [%{ms: newest, source: "games"} | _] = slow
      assert_in_delta newest, 107, 1
      refute Enum.any?(slow, &(&1.source == "players"))
    end
  end

  describe "openpairings.sh details" do
    setup do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, true)
      Application.put_env(:pairings_engine, :launcher_token, "a-secret-for-the-command-test")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:pairings_engine, :local_mode)
          value -> Application.put_env(:pairings_engine, :local_mode, value)
        end
      end)

      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      start_supervised!(
        {Bandit,
         plug: PairingsEngineWeb.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
      )

      %{port: port}
    end

    test "--json prints what the endpoint answered", %{port: port} do
      out =
        capture_io(fn ->
          assert CLI.run(["--json"], port: port, token: "a-secret-for-the-command-test") == 0
        end)

      assert %{"app" => "openpairings", "summary" => [_ | _]} = Jason.decode!(out)
    end

    test "--once prints the summary in words, and where the log is", %{port: port} do
      out =
        capture_io(fn ->
          assert CLI.run(["--once"],
                   port: port,
                   token: "a-secret-for-the-command-test",
                   lang: "en"
                 ) ==
                   0
        end)

      assert out =~ ~r/^Version: +OpenPairings /m
      assert out =~ ~r/^Database: +[0-9.]+ ms/m
      assert out =~ "-- log --"
    end

    test "a wrong secret is said, with a non-zero exit", %{port: port} do
      err =
        capture_io(:stderr, fn ->
          assert CLI.run(["--once"], port: port, token: "not-it-not-it-not-it", lang: "en") == 1
        end)

      assert err =~ "not to this secret"
    end

    test "nothing listening is said, with a non-zero exit" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, free} = :inet.port(socket)
      :gen_tcp.close(socket)

      err =
        capture_io(:stderr, fn ->
          assert CLI.run(["--json"], port: free, token: "a-secret-for-the-command-test") == 1
        end)

      assert err =~ "not answering"
    end

    test "the log tail reads only the end of a file", %{} do
      dir = Path.join(System.tmp_dir!(), "op_tail_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "launcher.log")
      File.write!(path, Enum.map_join(1..5000, "\r\n", &"line #{&1}"))

      assert CLI.tail_file(path, 3) == ["line 4998", "line 4999", "line 5000"]
      assert CLI.tail_file(Path.join(dir, "missing.log"), 3) == []
    end
  end
end
