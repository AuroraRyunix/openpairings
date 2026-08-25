defmodule PairingsEngine.LocalModeTest do
  @moduledoc """
  What `OPENPAIRINGS_LOCAL=1` actually does to `config/runtime.exs`.

  Read by evaluating the real file with `Config.Reader` rather than by
  asserting on a copy of the logic, because the thing worth guarding is the
  file that ships. In particular the loopback pin: local mode prints login
  links to a terminal, so the day it starts answering on `0.0.0.0` is the
  day it hands anyone on the network a way in.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "openpairings_local_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # `Config.Reader` needs the env vars in the real process environment, and
  # restores them afterwards so one test cannot leak into the next.
  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read_prod(env), do: Config.Reader.read!(@runtime, env: :prod)

  describe "local mode" do
    test "binds to loopback, never to every interface", %{dir: dir} do
      config =
        with_env(%{"OPENPAIRINGS_LOCAL" => "1", "OPENPAIRINGS_DATA_DIR" => dir}, fn ->
          read_prod(:prod)
        end)

      endpoint = config[:pairings_engine][PairingsEngineWeb.Endpoint]

      assert endpoint[:http][:ip] == {127, 0, 0, 1}
      assert endpoint[:url][:scheme] == "http"
      assert endpoint[:url][:host] == "localhost"
      assert endpoint[:server] == true
    end

    test "starts without SMTP, and prints the login link instead of sending it", %{dir: dir} do
      config =
        with_env(
          %{
            "OPENPAIRINGS_LOCAL" => "1",
            "OPENPAIRINGS_DATA_DIR" => dir,
            "SMTP_USERNAME" => "",
            "SMTP_PASSWORD" => ""
          },
          fn -> read_prod(:prod) end
        )

      assert config[:pairings_engine][PairingsEngine.Mailer][:adapter] ==
               PairingsEngine.ConsoleMailer
    end

    test "generates a secret once and reuses it, so a restart keeps sessions", %{dir: dir} do
      env = %{"OPENPAIRINGS_LOCAL" => "1", "OPENPAIRINGS_DATA_DIR" => dir}

      first = with_env(env, fn -> read_prod(:prod) end)
      second = with_env(env, fn -> read_prod(:prod) end)

      secret = first[:pairings_engine][PairingsEngineWeb.Endpoint][:secret_key_base]

      assert is_binary(secret)
      assert byte_size(secret) >= 64
      assert second[:pairings_engine][PairingsEngineWeb.Endpoint][:secret_key_base] == secret
    end

    test "puts the database in the data directory", %{dir: dir} do
      config =
        with_env(%{"OPENPAIRINGS_LOCAL" => "1", "OPENPAIRINGS_DATA_DIR" => dir}, fn ->
          read_prod(:prod)
        end)

      assert config[:pairings_engine][PairingsEngine.Repo][:database] ==
               Path.join(dir, "openpairings.db")
    end

    test "an explicit setting still wins over every default", %{dir: dir} do
      config =
        with_env(
          %{
            "OPENPAIRINGS_LOCAL" => "1",
            "OPENPAIRINGS_DATA_DIR" => dir,
            "DATABASE_PATH" => "/somewhere/else.db",
            "SECRET_KEY_BASE" => String.duplicate("k", 64),
            "PHX_HOST" => "chess.example"
          },
          fn -> read_prod(:prod) end
        )

      assert config[:pairings_engine][PairingsEngine.Repo][:database] == "/somewhere/else.db"

      endpoint = config[:pairings_engine][PairingsEngineWeb.Endpoint]
      assert endpoint[:secret_key_base] == String.duplicate("k", 64)
      assert endpoint[:url][:host] == "chess.example"
      # ...but not over the loopback pin, which is the one thing local mode
      # does not let you talk it out of.
      assert endpoint[:http][:ip] == {127, 0, 0, 1}
    end
  end

  describe "the console mailer" do
    import ExUnit.CaptureIO

    test "prints the sign-in link where the person running the binary will see it" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"Ann", "ann@example.com"})
        |> Swoosh.Email.from({"OpenPairings", "no-reply@example.com"})
        |> Swoosh.Email.subject("Log in to OpenPairings")
        |> Swoosh.Email.text_body("""
        Hi Ann,

        Use this link to log in: http://localhost:4000/users/log-in/abc123DEF

        If you did not request it, ignore this email.
        """)

      output = capture_io(fn -> {:ok, _} = PairingsEngine.ConsoleMailer.deliver(email, []) end)

      assert output =~ "http://localhost:4000/users/log-in/abc123DEF"
      assert output =~ "ann@example.com"
      assert output =~ "Log in to OpenPairings"
      # Says plainly that nothing was sent, so nobody waits on an inbox.
      assert output =~ "NOT sent"
    end

    test "falls back to the whole body when there is no link to pull out" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to("ann@example.com")
        |> Swoosh.Email.from("no-reply@example.com")
        |> Swoosh.Email.subject("Plain")
        |> Swoosh.Email.text_body("Nothing clickable in here.")

      output = capture_io(fn -> {:ok, _} = PairingsEngine.ConsoleMailer.deliver(email, []) end)

      assert output =~ "Nothing clickable in here."
    end
  end

  describe "without it, nothing changes" do
    test "a server run still binds every interface and still demands SMTP" do
      config =
        with_env(
          %{
            "OPENPAIRINGS_LOCAL" => "0",
            "DATABASE_PATH" => "/srv/op.db",
            "SECRET_KEY_BASE" => String.duplicate("k", 64),
            "SMTP_USERNAME" => "someone@example.com",
            "SMTP_PASSWORD" => "hunter2"
          },
          fn -> read_prod(:prod) end
        )

      endpoint = config[:pairings_engine][PairingsEngineWeb.Endpoint]

      assert endpoint[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 0}
      assert endpoint[:url][:scheme] == "https"
      assert config[:pairings_engine][PairingsEngine.Mailer][:adapter] == Swoosh.Adapters.SMTP
    end

    test "and a server run with no SMTP credentials refuses to boot" do
      assert_raise RuntimeError, ~r/SMTP_USERNAME and SMTP_PASSWORD/, fn ->
        with_env(
          %{
            "OPENPAIRINGS_LOCAL" => "0",
            "PHX_SERVER" => "true",
            "DATABASE_PATH" => "/srv/op.db",
            "SECRET_KEY_BASE" => String.duplicate("k", 64),
            "SMTP_USERNAME" => "",
            "SMTP_PASSWORD" => ""
          },
          fn -> read_prod(:prod) end
        )
      end
    end
  end
end
