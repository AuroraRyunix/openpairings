defmodule PairingsEngine.Build do
  @moduledoc """
  Which build this is, precisely enough to answer "did my deploy land?"

  ## Why a version number was not enough

  `0.18.0` identifies a release, not a build. Between two bumps there can be
  a week of commits and a dozen deploys, all reporting the same string - so
  the one question an operator actually asks after deploying ("is the thing
  I just pushed the thing that is running?") had no answer on the screen.

  It cost a real half-hour on 2026-08-30: a deploy went out, the public site
  still looked wrong, and the version said 0.18.0 on both sides of the
  question. The answer turned out to be that only one of the two
  applications had been deployed - which a build identifier would have shown
  at a glance.

  ## What identifies a build

  Three things, resolved at COMPILE time and frozen into the beam:

    * `version/0` - the release, from `mix.exs`.
    * `ref/0` - the commit. Read from `BUILD_REF` if the environment sets it,
      otherwise from `git` if this tree has any, otherwise `"unknown"`.
    * `built_at/0` - when this beam was compiled, UTC.

  The timestamp matters more than it looks. Two builds of the SAME commit are
  the common case when debugging a deploy - you rebuild without changing
  anything to rule the build out - and the ref alone cannot tell them apart.

  ## The deploy has to pass `BUILD_REF`

  The deploy uploads the source tree WITHOUT `.git` and compiles on the
  target, so `git` is not available where the release is actually built. If
  nothing sets `BUILD_REF` there, `ref/0` reports `"unknown"` - which is
  honest, and is itself the signal that the deploy needs fixing rather than a
  value to be trusted.

  ## Dev builds say so

  In `:dev` and `:test` the beam is recompiled piecemeal, so a captured
  timestamp describes when this one module was last touched rather than when
  anything was built. Reporting that as a build identifier would be worse
  than reporting nothing, so those environments say `dev` and stop.
  """

  @version Mix.Project.config()[:version]

  @env Mix.env()

  # Resolved once, at compile time. `System.cmd/3` is wrapped because there
  # are three ways for it to fail and all of them are normal: no git binary,
  # not a repository, or a repository this user cannot read.
  @ref (case System.get_env("BUILD_REF") do
          ref when is_binary(ref) and ref != "" ->
            String.trim(ref)

          _ ->
            try do
              case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                {out, 0} -> String.trim(out)
                _ -> "unknown"
              end
            rescue
              _ -> "unknown"
            end
        end)

  @built_at DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The release, from `mix.exs` - e.g. `\"0.18.0\"`."
  def version, do: @version

  @doc """
  The commit this was built from, short form - or `\"unknown\"` when nothing
  told the build and `git` was not there to ask.
  """
  def ref, do: @ref

  @doc "When this beam was compiled, as an ISO-8601 UTC string."
  def built_at, do: @built_at

  @doc "Whether this is a release build, as opposed to dev or test."
  def release?, do: @env == :prod

  @doc """
  The short identifier, for a topbar or a footer: `\"0.18.0+3f2a1c9\"`, or
  `\"0.18.0-dev\"` outside a release build.

  Deliberately not just the version. Two deploys a week apart reporting the
  same string is the failure this exists to prevent.
  """
  def id do
    cond do
      not release?() -> "#{@version}-dev"
      @ref == "unknown" -> "#{@version}+unknown"
      true -> "#{@version}+#{@ref}"
    end
  end

  @doc """
  The full identifier, for a tooltip, an about box or a support request:
  `\"0.18.0+3f2a1c9, built 2026-08-30T15:42:07Z\"`.

  Outside a release build it says so instead of quoting a compile time that
  describes one module rather than a build.
  """
  def long do
    if release?() do
      "#{id()}, built #{built_at()}"
    else
      "#{id()} (not a release build)"
    end
  end
end
