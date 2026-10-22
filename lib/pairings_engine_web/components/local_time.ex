defmodule PairingsEngineWeb.Components.LocalTime do
  @moduledoc """
  A stored instant shown in the reader's own time zone.

  The server only knows UTC, and an arbiter in Brussels reading "14:05" for
  something they did at 16:05 is how restore points get picked wrongly. So
  the server renders a `<time>` with the UTC instant in `datetime`, the UTC
  text labelled as such (which is what a reader without JavaScript - or a
  test - sees), and the UTC text again as a tooltip. The hook rewrites the
  text into the browser's zone and leaves the tooltip alone, so the original
  is one hover away.

  Formats:

    * `"datetime"` - `2026-10-22 16:05`
    * `"time"` - `16:05`
    * `"stamp"` - `Today 16:05`, `Yesterday 16:05`, `21 October 2026 16:05`,
      with "today" decided by the reader's calendar, not Greenwich's.

  The element is `phx-update="ignore"`: an instant does not change under a
  given id, and LiveView patching the UTC text back in on every render would
  make the time flicker between zones.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  attr :id, :string, required: true
  attr :at, :any, required: true, doc: "a DateTime or NaiveDateTime (taken as UTC)"
  attr :format, :string, default: "datetime", values: ~w(datetime time stamp)
  attr :class, :any, default: nil

  def local_time(assigns) do
    utc = to_utc(assigns.at)

    assigns =
      assign(assigns,
        iso: utc && DateTime.to_iso8601(utc),
        utc_text: utc && utc_text(utc, assigns.format),
        utc_title: utc && Calendar.strftime(utc, "%Y-%m-%d %H:%M UTC")
      )

    ~H"""
    <time
      :if={@iso}
      id={@id}
      class={@class}
      datetime={@iso}
      title={@utc_title}
      data-format={@format}
      data-today={gettext("Today")}
      data-yesterday={gettext("Yesterday")}
      phx-hook=".LocalTime"
      phx-update="ignore"
    >{@utc_text}</time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() { this.render() },
        render() {
          const el = this.el
          const at = new Date(el.getAttribute("datetime"))
          if (isNaN(at)) return
          const pad = (n) => String(n).padStart(2, "0")
          const hm = `${pad(at.getHours())}:${pad(at.getMinutes())}`
          const format = el.dataset.format

          if (format === "time") {
            el.textContent = hm
          } else if (format === "stamp") {
            const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate())
            const diff = Math.round((day(new Date()) - day(at)) / 86400000)
            let prefix
            if (diff === 0) prefix = el.dataset.today
            else if (diff === 1) prefix = el.dataset.yesterday
            else {
              const lang = document.documentElement.lang || undefined
              try {
                prefix = at.toLocaleDateString(lang, { day: "numeric", month: "long", year: "numeric" })
              } catch (_e) {
                prefix = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
              }
            }
            el.textContent = `${prefix} ${hm}`
          } else {
            el.textContent =
              `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())} ${hm}`
          }
        }
      }
    </script>
    """
  end

  defp to_utc(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(_), do: nil

  # The no-JavaScript text: the same shape the hook produces, in UTC and
  # saying so, because an unlabelled UTC time is the bug this replaced.
  defp utc_text(at, "time"), do: Calendar.strftime(at, "%H:%M UTC")

  defp utc_text(at, "stamp") do
    date = DateTime.to_date(at)

    prefix =
      case Date.diff(Date.utc_today(), date) do
        0 -> gettext("Today")
        1 -> gettext("Yesterday")
        _ -> Calendar.strftime(date, "%-d %B %Y")
      end

    prefix <> " " <> Calendar.strftime(at, "%H:%M UTC")
  end

  defp utc_text(at, _), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
