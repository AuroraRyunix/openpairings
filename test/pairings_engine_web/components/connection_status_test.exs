defmodule PairingsEngineWeb.Components.ConnectionStatusTest do
  @moduledoc """
  The Connections panel, in both languages, from what `Publishing.status/0`
  actually returns.

  It used to print `Publishing`'s own English sentence under a translated
  headline, and strip the headline off the front of that sentence with a
  regex that could only ever match in English. In Dutch the card read
  "Verbonden" above "Connected. The address and token are both accepted." -
  the repetition the strip existed to remove, plus a language switch in the
  middle of the card an arbiter reads when publishing is failing mid-event.

  Every state is driven through a stubbed server and the real `status/0`
  rather than a hand-built map, so what is pinned is the whole chain: the
  reason the check produces, the state that reason is sorted into, and the
  words. A map written for the test could agree with the component while
  disagreeing with the producer.
  """
  use PairingsEngine.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.Publishing
  alias PairingsEngineWeb.Components.ConnectionStatus

  setup do
    Publishing.put_endpoint("https://openresults.example")
    Publishing.put_token("s3cret")
    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  # The full indicator for `status`, rendered in `locale`, as what the reader
  # sees: {colour, headline, the sentence under it}.
  defp card(status, locale) do
    html =
      Gettext.with_locale(PairingsEngineWeb.Gettext, locale, fn ->
        render_component(&ConnectionStatus.connection_status/1, status: status)
      end)

    [_, tone] = Regex.run(~r/class="conn-status is-(\w+)/, html)
    [_, headline] = Regex.run(~r/<strong>([^<]*)<\/strong>/, html)
    [_, detail] = Regex.run(~r/<p class="conn-detail">([^<]*)<\/p>/, html)

    {tone, String.trim(headline), String.trim(detail)}
  end

  defp arrange(:no_address) do
    Publishing.put_endpoint(nil)
    Publishing.status()
  end

  defp arrange(:no_token) do
    Publishing.put_token(nil)
    Publishing.status()
  end

  defp arrange(:token_rejected) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)
    Publishing.status()
  end

  defp arrange(:not_openresults) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "<html>hello</html>") end)
    Publishing.status()
  end

  defp arrange(:unreachable) do
    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    Publishing.status()
  end

  defp arrange(:connected) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 404, ~s({"error":"not_found"})) end)
    Publishing.status()
  end

  defp arrange(:sending), do: %{arrange(:connected) | pending: 3}

  describe "every state reads correctly in English and in Dutch" do
    for {name, tone, en, nl} <- [
          {:no_address, "off", {"Not set up", "No address is set."},
           {"Niet ingesteld", "Er is geen adres ingesteld."}},
          {:no_token, "off", {"Not set up", "No token is set."},
           {"Niet ingesteld", "Er is geen token ingesteld."}},
          {:token_rejected, "refused",
           {"Token refused", "Reached the server, but it rejected the token."},
           {"Token geweigerd", "De server antwoordde, maar weigerde de token."}},
          {:not_openresults, "refused",
           {"Token refused",
            "Reached the server and it answered 200, which is not an OpenResults server."},
           {"Token geweigerd", "Er antwoordde iets met 200, maar dat is geen OpenResults-server."}},
          {:unreachable, "down",
           {"Cannot reach the results site",
            "The connection was refused - is the server running?"},
           {"Kan de uitslagensite niet bereiken",
            "De verbinding werd geweigerd - draait de server wel?"}},
          {:connected, "ok", {"Connected", "The address and token are both accepted."},
           {"Verbonden", "Het adres en de token worden allebei aanvaard."}},
          # Not a repeat here: the headline says the queue is moving, the
          # sentence says the connection under it is fine.
          {:sending, "busy", {"Sending", "Connected. The address and token are both accepted."},
           {"Bezig met verzenden", "Verbonden. Het adres en de token worden allebei aanvaard."}}
        ] do
      @name name
      @tone tone
      @en en
      @nl nl

      test "#{name}" do
        status = arrange(@name)

        {en_headline, en_detail} = @en
        {nl_headline, nl_detail} = @nl

        assert card(status, "en") == {@tone, en_headline, en_detail}
        assert card(status, "nl") == {@tone, nl_headline, nl_detail}
      end
    end
  end

  test "the status carries a reason, and no sentence at all" do
    # A sentence built in `Publishing` is English whatever the arbiter chose,
    # and a `message` key left on the map is an invitation to render it.
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end)
    status = Publishing.status()

    assert status.reason == {:refused, {:rejected, 401, "unauthorized", nil}}
    refute Map.has_key?(status, :message)
  end

  describe "an answer is worded by the server's code, and by the status only without one" do
    # OpenResults' contract: every error body carries a code, and clients
    # dispatch on it - two 403s can mean two different things.
    test "a bare 401 with no code still reads as a token problem" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "Unauthorized") end)

      assert {"refused", "Token refused", "Reached the server, but it rejected the token."} =
               card(Publishing.status(), "en")
    end

    test "a code with no sentence yet is shown by name, not called 'not an OpenResults server'" do
      # A body carrying a code IS an OpenResults server. Until the code has a
      # sentence, the card says which code - technical on purpose, so the gap
      # is visible - and the top bar still renders.
      stub(fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"error":"installation_revoked","detail":"Revoked."}))
      end)

      status = Publishing.status()

      assert {"refused", "Token refused",
              "Could not confirm the connection (403 installation_revoked)."} =
               card(status, "en")

      assert {"refused", "Token geweigerd",
              "Kon de verbinding niet bevestigen (403 installation_revoked)."} =
               card(status, "nl")
    end
  end

  describe "a network that does not answer says how it failed" do
    # Each of these used to be a lowercase English phrase passed through from
    # `Publishing.describe_transport/1`. They want different fixes - a typo
    # in the address, a server that is down, a wifi that is dropping - so
    # each keeps a sentence of its own rather than one "offline".
    for {reason, en, nl} <- [
          {:timeout, "The connection timed out.", "De verbinding kreeg een time-out."},
          {:closed, "The connection was closed.", "De verbinding werd verbroken."},
          {:nxdomain, "The address did not resolve.", "Het adres werd niet gevonden."},
          {:ehostunreach, "Could not connect (:ehostunreach).",
           "Kon geen verbinding maken (:ehostunreach)."}
        ] do
      @reason reason
      @en en
      @nl nl

      test "#{reason}" do
        stub(fn conn -> Req.Test.transport_error(conn, @reason) end)
        status = Publishing.status()

        assert status.state == :unreachable
        assert status.reason == {:unreachable, @reason}
        assert {"down", _, @en} = card(status, "en")
        assert {"down", _, @nl} = card(status, "nl")
      end
    end
  end

  test "the Test connection answer reads on its own, in the arbiter's language" do
    # Nothing above it has said "Connected", so unlike the card's detail line
    # it says so itself.
    assert Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
             ConnectionStatus.describe_check(:ok)
           end) == "Verbonden. Het adres en de token worden allebei aanvaard."

    assert Gettext.with_locale(PairingsEngineWeb.Gettext, "nl", fn ->
             ConnectionStatus.describe_check({:error, {:unconfigured, :no_token}})
           end) == "Er is geen token ingesteld."
  end

  test "a reason with no sentence yet still renders, rather than taking every page down" do
    # The indicator is in the top bar of every page. A reason added to
    # `Publishing.check/0` before its sentence exists must show up as a gap -
    # visibly technical - and not as a FunctionClauseError on every render.
    status = %{arrange(:token_rejected) | reason: {:refused, :something_new}}

    assert {"refused", "Token refused", "Could not confirm the connection (:something_new)."} =
             card(status, "en")
  end
end
