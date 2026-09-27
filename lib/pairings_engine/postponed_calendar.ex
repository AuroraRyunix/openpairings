defmodule PairingsEngine.PostponedCalendar do
  @moduledoc """
  An iCalendar file (RFC 5545) for a postponed game's agreed date, so a
  player can put it in their calendar with one tap.

  The agreed date is a date, not a time - the players agree on an evening,
  the club knows when its evenings start - so the event is an all-day one
  (`DTSTART;VALUE=DATE`). It is not a deadline and carries no alarm.

  The words (summary, description, location) come in from the caller, which
  translates them; this module only knows the format: CRLF line ends, text
  escaped and lines folded at 75 octets.
  """

  @doc """
  The `.ics` text for one event on `date`. `uid` must be stable for the
  game, so importing the file again after the date moved updates the event
  instead of adding a second one.
  """
  def ics(%Date{} = date, uid, summary, description, location) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//OpenPairings//Postponed game//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:" <> escape(uid),
      "DTSTAMP:" <> stamp,
      "DTSTART;VALUE=DATE:" <> Calendar.strftime(date, "%Y%m%d"),
      "DTEND;VALUE=DATE:" <> Calendar.strftime(Date.add(date, 1), "%Y%m%d"),
      "SUMMARY:" <> escape(summary),
      location not in [nil, ""] && "LOCATION:" <> escape(location),
      "DESCRIPTION:" <> escape(description),
      "TRANSP:OPAQUE",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join("", &(fold(&1) <> "\r\n"))
  end

  # RFC 5545 3.3.11: backslash, semicolon and comma are escaped, a newline
  # becomes `\n`.
  defp escape(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r\n|\r|\n/, "\\n")
  end

  # RFC 5545 3.1: a line longer than 75 octets continues on the next line,
  # which starts with a space. Split on character boundaries, never inside a
  # multi-byte character.
  defp fold(line) when byte_size(line) <= 75, do: line

  defp fold(line) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], "", 75}, fn g, {done, current, limit} ->
      if byte_size(current) + byte_size(g) > limit,
        do: {[current | done], g, 74},
        else: {done, current <> g, limit}
    end)
    |> then(fn {done, current, _} -> Enum.reverse([current | done]) end)
    |> Enum.join("\r\n ")
  end
end
