defmodule PairingsEngineWeb.UserAgent do
  @moduledoc """
  "Firefox on Windows" from a `user-agent` header - just enough for the
  account page's list of sessions to tell a phone from a laptop.

  Deliberately crude. It is a label for a person looking at their own
  devices, not a fingerprint and not a security control: the header is
  whatever the client chose to send, and nothing is decided on it. Order
  matters in both lists, because every browser claims to be the ones before
  it - Edge says Chrome and Safari, Chrome says Safari - so the more
  specific name is checked first.
  """

  @browsers [
    {"Edg/", "Edge"},
    {"OPR/", "Opera"},
    {"Firefox/", "Firefox"},
    {"FxiOS/", "Firefox"},
    {"CriOS/", "Chrome"},
    {"Chrome/", "Chrome"},
    {"Safari/", "Safari"}
  ]

  @systems [
    {"iPhone", "iPhone"},
    {"iPad", "iPad"},
    {"Android", "Android"},
    {"CrOS", "ChromeOS"},
    {"Windows", "Windows"},
    {"Mac OS X", "macOS"},
    {"Macintosh", "macOS"},
    {"Linux", "Linux"}
  ]

  @doc """
  `{browser, system}`, either of them `nil` when the header does not say.
  """
  def parse(ua) when is_binary(ua), do: {find(ua, @browsers), find(ua, @systems)}
  def parse(_ua), do: {nil, nil}

  @doc """
  The system alone - `"iPhone"`, `"Windows"` - for choosing an icon.
  """
  def system(ua), do: ua |> parse() |> elem(1)

  @doc "Whether the header describes a phone or a tablet."
  def mobile?(ua), do: system(ua) in ["iPhone", "iPad", "Android"]

  defp find(ua, table) do
    Enum.find_value(table, fn {needle, name} -> if String.contains?(ua, needle), do: name end)
  end
end
