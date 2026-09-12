defmodule PairingsEngineWeb.LiveMarkupTest do
  @moduledoc """
  Static checks on the markup that a LiveView test cannot make.

  `render_change/2` raises its event straight at the element it is given, so
  a control wired the wrong way round passes every LiveView test in this
  suite and does nothing at all in a browser. That is not hypothetical: on
  2026-09-12 the category selector on the standings page and the arbiter
  picker on the norms page were both a select carrying phx-change with no
  form around it, fully covered by passing tests, and neither did anything
  when a person changed it.
  """
  use ExUnit.Case, async: true

  @sources Path.wildcard("lib/pairings_engine_web/**/*.ex")

  test "a select carrying phx-change always sits inside a form" do
    offenders =
      for path <- @sources,
          {line, number} <- code_lines(path),
          String.contains?(line, "<select"),
          String.contains?(line, "phx-change"),
          not inside_form?(path, number),
          do: "#{path}:#{number}"

    assert offenders == [],
           """
           These selects carry phx-change with no enclosing form:

           #{Enum.join(offenders, "\n")}

           LiveView serialises a change event from the closest enclosing form,
           so the browser never sends anything for a bare select. Put the
           phx-change on a form around it (style="display: contents" keeps the
           layout) and leave the select with just its name.
           """
  end

  # Comments are skipped: the HEEx comment explaining this very rule names
  # both a select and phx-change, and so does the moduledoc above.
  defp code_lines(path) do
    path
    |> lines()
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, number}, {kept, in_comment?} ->
      opens? = String.contains?(line, "<%!--")
      closes? = String.contains?(line, "--%>")
      trimmed = String.trim_leading(line)
      skip? = in_comment? or opens? or String.starts_with?(trimmed, "#")

      next? =
        cond do
          closes? -> false
          opens? -> true
          true -> in_comment?
        end

      {if(skip?, do: kept, else: [{line, number} | kept]), next?}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A form can open many lines above, and several can open and close before
  # it, so this counts depth rather than looking for the nearest tag.
  defp inside_form?(path, line_number) do
    path
    |> lines()
    |> Enum.take(line_number)
    |> Enum.reduce(0, fn line, depth ->
      depth + count(line, ~r/<\.?form\b/) - count(line, ~r/<\/\.?form>/)
    end)
    |> Kernel.>(0)
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n")
  defp count(line, regex), do: regex |> Regex.scan(line) |> length()
end
