defmodule PairingsEngine.ConsoleMailer do
  @moduledoc """
  A Swoosh adapter that prints an email to the terminal instead of sending it.

  Used only in local mode (`OPENPAIRINGS_LOCAL=1`), where the app is a
  single-user program on somebody's own machine and there is no mail server
  to talk to - see `config/runtime.exs`.

  ## Why login is not simply skipped

  The obvious shortcut for a local build is to log the first visitor in
  automatically. This deliberately does not: a bypass that authenticates
  whoever asks is one environment variable away from being on in a place it
  should not be, and the failure is total rather than partial.

  So the login flow is untouched - same magic-link token, same expiry, same
  verification. The only thing that changes is DELIVERY: the link is printed
  in the terminal the person running the binary is already looking at, which
  in a single-user local run is a strictly better mailbox than email.

  `config/runtime.exs` additionally pins local mode to the loopback
  interface, so even a machine that sets the variable by mistake is not
  serving this to anyone else.
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
