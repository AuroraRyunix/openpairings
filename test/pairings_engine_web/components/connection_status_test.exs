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

  defp arrange(:not_owner) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"not_owner"})) end)
    Publishing.status()
  end

  defp arrange(:installation_suspended) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"installation_suspended"})) end)
    Publishing.status()
  end

  defp arrange(:installation_revoked) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"installation_revoked"})) end)
    Publishing.status()
  end

  defp arrange(:tournament_limit) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"tournament_limit"})) end)
    Publishing.status()
  end

  defp arrange(:snapshot_too_large) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"snapshot_too_large"})) end)
    Publishing.status()
  end

  defp arrange(:tournament_hidden) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"tournament_hidden"})) end)
    Publishing.status()
  end

  defp arrange(:registration_closed) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 503, ~s({"error":"registration_closed"})) end)
    Publishing.status()
  end

  defp arrange(:address_blocked) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 403, ~s({"error":"address_blocked"})) end)
    Publishing.status()
  end

  defp arrange(:rate_limited) do
    stub(fn conn -> Plug.Conn.send_resp(conn, 429, ~s({"error":"rate_limited"})) end)
    Publishing.status()
  end

  # Public mode's credential is a key, not a token - arranged by overriding
  # an already-real status's mode/reason rather than standing up the whole
  # installation/consent dance, the same technique the "no sentence yet"
  # edge cases below already use.
  defp arrange(:key_not_recognised_bare) do
    %{arrange(:token_rejected) | mode: :public, reason: {:refused, {:rejected, 401, nil, nil}}}
  end

  defp arrange(:key_not_recognised_coded) do
    %{
      arrange(:token_rejected)
      | mode: :public,
        reason: {:refused, {:rejected, 401, "unauthorized", nil}}
    }
  end

  describe "every state reads correctly in English and in Dutch" do
    for {name, tone, en, nl} <- [
          {:no_address, "off", {"Not set up", "No address is set."},
           {"Niet ingesteld", "Er is geen adres ingesteld."}},
          {:no_token, "off", {"Not set up", "No token is set."},
           {"Niet ingesteld", "Er is geen token ingesteld."}},
          {:token_rejected, "refused",
           {"Token refused", "Reached the server, but it rejected the token."},
           {"Token geweigerd", "De server antwoordde, maar weigerde de token."}},
          # The token was never the problem here - the server answered, just
          # not as an OpenResults server (docs/audit-2026-09-05.md, "Reasons,
          # not sentences"). "Token refused" over this sentence was the bug.
          {:not_openresults, "refused",
           {"Not an OpenResults server",
            "Reached the server and it answered 200, which is not an OpenResults server."},
           {"Geen OpenResults-server",
            "Er antwoordde iets met 200, maar dat is geen OpenResults-server."}},
          {:not_owner, "down",
           {"Owned by another installation",
            "A different installation owns this tournament on the results site. Ask the operator of the results site to transfer it to this computer."},
           {"Eigendom van een andere installatie",
            "Een andere installatie is eigenaar van dit toernooi op de uitslagensite. Vraag de beheerder van de uitslagensite om het naar deze computer over te dragen."}},
          {:installation_suspended, "down",
           {"Key suspended",
            "The results site has suspended this computer&#39;s key. Contact the operator of the results site."},
           {"Sleutel geschorst",
            "De uitslagensite heeft de sleutel van deze computer geschorst. Neem contact op met de beheerder van de uitslagensite."}},
          {:installation_revoked, "down",
           {"Key revoked",
            "The results site no longer accepts this computer&#39;s key. Publishing has stopped."},
           {"Sleutel niet meer aanvaard",
            "De uitslagensite aanvaardt de sleutel van deze computer niet meer. Publiceren is gestopt."}},
          {:tournament_limit, "down",
           {"Tournament limit reached",
            "This computer has reached the results site&#39;s limit on tournaments. Publishing has stopped for this tournament."},
           {"Toernooilimiet bereikt",
            "Deze computer heeft de limiet van de uitslagensite voor het aantal toernooien bereikt. Publiceren is gestopt voor dit toernooi."}},
          {:snapshot_too_large, "down",
           {"Tournament too large",
            "This tournament is too large for the results site. Publishing has stopped for this tournament."},
           {"Toernooi te groot",
            "Dit toernooi is te groot voor de uitslagensite. Publiceren is gestopt voor dit toernooi."}},
          {:tournament_hidden, "down",
           {"Tournament hidden",
            "The operator of the results site has hidden this tournament. Publishing has stopped for this tournament."},
           {"Toernooi verborgen",
            "De beheerder van de uitslagensite heeft dit toernooi verborgen. Publiceren is gestopt voor dit toernooi."}},
          {:registration_closed, "refused",
           {"Registration closed",
            "The results site is not accepting new installations right now. Nothing has been sent, and it will be tried again later."},
           {"Registratie gesloten",
            "De uitslagensite aanvaardt op dit moment geen nieuwe installaties. Er is niets verzonden, en het wordt later opnieuw geprobeerd."}},
          {:address_blocked, "down",
           {"Address blocked",
            "The results site has blocked this computer&#39;s network address. Contact the operator of the results site."},
           {"Adres geblokkeerd",
            "De uitslagensite heeft het netwerkadres van deze computer geblokkeerd. Neem contact op met de beheerder van de uitslagensite."}},
          {:rate_limited, "refused",
           {"Waiting a moment",
            "The results site asked this computer to wait a moment. It will try again shortly."},
           {"Even wachten",
            "De uitslagensite vroeg deze computer om even te wachten. Er wordt straks opnieuw geprobeerd."}},
          {:key_not_recognised_bare, "down",
           {"Key not recognised",
            "The results site does not recognise this computer&#39;s key. Publishing has stopped until you register again."},
           {"Sleutel niet herkend",
            "De uitslagensite herkent de sleutel van deze computer niet. Publiceren is gestopt tot je opnieuw registreert."}},
          {:key_not_recognised_coded, "down",
           {"Key not recognised",
            "The results site does not recognise this computer&#39;s key. Publishing has stopped until you register again."},
           {"Sleutel niet herkend",
            "De uitslagensite herkent de sleutel van deze computer niet. Publiceren is gestopt tot je opnieuw registreert."}},
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
      # `installation_revoked` was the example here until public publishing
      # gave it a sentence - which is exactly the "one clause and one msgid"
      # this test promised. A code no version has words for stands in now.
      stub(fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"error":"some_future_code","detail":"Whatever."}))
      end)

      status = Publishing.status()

      assert {"refused", "Refused by the results site",
              "Could not confirm the connection (403 some_future_code)."} =
               card(status, "en")

      assert {"refused", "Geweigerd door de uitslagensite",
              "Kon de verbinding niet bevestigen (403 some_future_code)."} =
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

    assert {"refused", "Refused by the results site",
            "Could not confirm the connection (:something_new)."} =
             card(status, "en")
  end
end
