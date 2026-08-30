defmodule PairingsEngine.ConsoleMailer do
  @moduledoc """
  A Swoosh adapter that prints an email to the terminal instead of sending it.

  Used only in local mode (`OPENPAIRINGS_LOCAL=1`), where the app is a
  single-user program on somebody's own machine and there is no mail server
  to talk to - see `config/runtime.exs`.

  ## What this is for, now that local mode does log you in

  This moduledoc used to argue at length that a local build deliberately does
  NOT log the first visitor in automatically, because a bypass that
  authenticates whoever asks is one environment variable away from being on
  somewhere it should not be. The app went the other way:
  `PairingsEngineWeb.UserAuth.local_owner_session/2` signs the local owner in
  on sight, and has for some time. The argument stayed here describing a
  design that had been replaced - corrected 2026-08-30.

  What the app actually does, and why it is not the blanket bypass the old
  text feared, is three conditions ANDed together (`user_auth.ex:106`):
  local mode is on, the connection physically came from loopback
  (`conn.remote_ip`, never `X-Forwarded-For`, which is attacker-controlled),
  and no session exists yet - so an explicit log out stays logged out.
  `config/runtime.exs` pins local mode to the loopback interface as well, so
  a machine that sets the variable by mistake is not serving this to anyone.

  That leaves this adapter with a narrower job than it once had, and a real
  one. The login flow still exists in full - same magic-link token, same
  expiry, same verification - for every path `local_owner_session/2` does not
  cover: a second account on the same machine, an invited collaborator, a
  password reset. When one of those needs to send mail there is no mail
  server on a single-user local run, so the link is printed in the terminal
  the person is already looking at, which is a strictly better mailbox than
  email they cannot receive.
  """

  use Swoosh.Adapter

  @impl Swoosh.Adapter
  def deliver(%Swoosh.Email{} = email, _config) do
    body = email.text_body || email.html_body || ""

    links =
      ~r{https?://[^\s<>"'\)\]]+}
      |> Regex.scan(body)
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    IO.puts(render(email, links))

    {:ok, %{id: "console"}}
  end

  @impl Swoosh.Adapter
  def deliver_many(emails, config) do
    results = Enum.map(emails, fn email -> {:ok, _} = deliver(email, config) end)
    {:ok, Enum.map(results, fn {:ok, r} -> r end)}
  end

  defp render(email, links) do
    rule = String.duplicate("-", 68)

    header = [
      "",
      rule,
      "  OpenPairings - local mode: this email was NOT sent, it is printed.",
      rule,
      "  to:      #{recipients(email.to)}",
      "  subject: #{email.subject}"
    ]

    body =
      case links do
        [] ->
          ["", "  (no link in this message - full text below)", "", indent(email.text_body || "")]

        [one] ->
          ["", "  Open this to sign in:", "", "    #{one}"]

        many ->
          ["", "  Links in this message:", ""] ++ Enum.map(many, &"    #{&1}")
      end

    Enum.join(header ++ body ++ ["", rule, ""], "\n")
  end

  defp recipients(list) when is_list(list),
    do: list |> Enum.map_join(", ", &address/1)

  defp recipients(other), do: address(other)

  defp address({name, addr}) when is_binary(name) and name != "", do: "#{name} <#{addr}>"
  defp address({_name, addr}), do: addr
  defp address(addr) when is_binary(addr), do: addr
  defp address(other), do: inspect(other)

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end
end
