defmodule PairingsEngineWeb.RequestLoggingTest do
  @moduledoc """
  The routes that carry a bearer token in the path must not put it in the
  log. Production logs at `:info`, which is the level the endpoint's request
  line is written at, so the level is raised here for the length of each test
  rather than asserted at the suite's quieter default.

  `async: false` for the same reason: `Logger.configure/1` is global.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # Shaped like the real thing (24 bytes, url-safe) and distinctive enough
  # that a substring match cannot pass by accident.
  @token "3fXK9pQ2mZtL7vB1nR4sW8yC6dH0jE5a"

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  describe "paths that carry a bearer token" do
    test "the magic-link log-in token never reaches the log", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/users/log-in/#{@token}") end)

      refute log =~ @token
      assert log =~ "GET /users/log-in/[FILTERED]"
    end

    test "the confirm-email token never reaches the log", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/users/settings/confirm-email/#{@token}") end)

      refute log =~ @token
      assert log =~ "GET /users/settings/confirm-email/[FILTERED]"
    end

    test "the invite token never reaches the log", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/invites/#{@token}") end)

      refute log =~ @token
      assert log =~ "GET /invites/[FILTERED]"
    end

    test "the tools download token never reaches the log, but the form does", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/tools/download/#{@token}/it3") end)

      refute log =~ @token
      assert log =~ "GET /tools/download/[FILTERED]/it3"
    end

    # A form segment is written by whoever typed the URL, so only the known
    # three are echoed - anything else is dropped rather than logged.
    test "an unknown form is not echoed either", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/tools/download/#{@token}/not-a-form") end)

      refute log =~ @token
      refute log =~ "not-a-form"
      assert log =~ "GET /tools/download/[FILTERED]"
    end

    test "the phone enrolment token never reaches the log", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/m/e/#{@token}") end)

      refute log =~ @token
      assert log =~ "GET /m/e/[FILTERED]"
    end
  end

  describe "everything else" do
    test "an ordinary path is still logged in full", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/users/log-in") end)

      assert log =~ "GET /users/log-in"
      refute log =~ "[FILTERED]"
    end

    # The response line carries no path, so it is left to Phoenix even on a
    # redacted route - without it the redacted line has no outcome next to it.
    test "the response is still logged for a redacted path", %{conn: conn} do
      log = capture_log(fn -> get(conn, ~p"/users/log-in/#{@token}") end)

      assert log =~ "Sent "
    end
  end
end
