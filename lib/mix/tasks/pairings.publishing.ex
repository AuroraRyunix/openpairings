defmodule Mix.Tasks.Pairings.Publishing do
  @shortdoc "Show or configure where this installation publishes"

  @moduledoc """
  Where this installation sends, where spectators go, and the token between.

      mix pairings.publishing                       # what is configured now
      mix pairings.publishing --ensure \\
        --endpoint http://localhost:4004 \\
        --public https://openresults.example \\
        --token SECRET

  ## Why a deploy needs this

  The deploy script already knows **both halves of this link**: it installs
  OpenResults with the ingest token that side accepts, and it knows the port
  and the public hostname. OpenPairings needs the same token to send. Without
  this task those two facts are deployed and then wired together by hand, in
  a browser, using a secret already sitting in the deploy configuration -
  which is exactly the gap `ADMIN_EMAILS` had before it was closed.

  ## `--ensure` fills blanks and will not overwrite

  A role can be re-granted every deploy without argument, because the deploy
  configuration is the source of truth for who administers. These settings
  are not like that: an operator may have repointed an installation on
  purpose, and a deploy silently stamping over that would undo a deliberate
  act with no trace.

  So `--ensure` sets any value that is **unset**, and when a value is already
  set and differs it says so loudly, changes nothing, and prints the command
  that would. `--force` is that command. The token is compared without ever
  being printed - "differs" is the whole report.

  ## The two addresses

  `--endpoint` is where this machine POSTs. On a box that hosts both
  applications it should be loopback, so publishing does not depend on DNS
  and a CDN to reach a process one hop away.

  `--public` is what spectators are handed - share links, QR codes, printed
  URLs. It must be an address that resolves on the open internet.

  Setting only `--endpoint` keeps the old single-address behaviour, because
  `PairingsEngine.Publishing.public_base/0` falls back to it.
  """
  use Mix.Task

  alias PairingsEngine.Publishing

  @requirements ["app.config"]

  @switches [
    ensure: :boolean,
    force: :boolean,
    endpoint: :string,
    public: :string,
    token: :string
  ]

  @impl Mix.Task
  def run(argv) do
    start_repo()
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    # `||`, not `or`: an absent switch is nil, and `or` demands a boolean on
    # the left rather than treating nil as false.
    cond do
      opts[:ensure] || opts[:force] -> apply_settings(opts)
      opts == [] -> show()
      true -> Mix.raise("nothing to do: pass --ensure (or --force) with the values to set")
    end
  end

  defp start_repo do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case PairingsEngine.Repo.start_link(pool_size: 1) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Mix.raise("could not reach the database: #{inspect(reason)}")
    end
  end

  defp show do
    Mix.shell().info("")
    Mix.shell().info(["  sends to      ", :reset, value(Publishing.endpoint())])
    Mix.shell().info(["  spectators go ", :reset, value(Publishing.public_base())])

    Mix.shell().info([
      "  token         ",
      :reset,
      if(Publishing.token(), do: "set", else: "not set")
    ])

    unless Publishing.configured?() do
      Mix.shell().info([
        "\n",
        :yellow,
        "Nothing is published until both an address and a token are set.\n",
        :reset
      ])
    end

    Mix.shell().info("")
  end

  defp value(nil), do: "not set"
  defp value(""), do: "not set"
  defp value(v), do: v

  defp apply_settings(opts) do
    force? = opts[:force] == true

    settle(
      force?,
      "address to send to",
      Publishing.endpoint(),
      opts[:endpoint],
      &Publishing.put_endpoint/1
    )

    # `stored_public_base/0`, never `public_base/0`: the latter falls back to
    # the endpoint, so it would report every installation as already having a
    # public address and `--ensure` would never fill the blank it exists for.
    settle(
      force?,
      "public address",
      Publishing.stored_public_base(),
      opts[:public],
      &Publishing.put_public_base/1
    )

    settle_token(force?, opts[:token])
  end

  defp settle(_force?, _label, _current, nil, _put), do: :ok

  defp settle(force?, label, current, wanted, put) do
    cond do
      blank?(current) ->
        put.(wanted)
        Mix.shell().info([:green, "· #{label} set to ", :reset, wanted])

      current == wanted or normalised_match?(current, wanted) ->
        Mix.shell().info([:green, "· #{label} already ", :reset, current])

      force? ->
        put.(wanted)
        Mix.shell().info([:yellow, "· #{label} CHANGED from ", :reset, current, " to ", wanted])

      true ->
        refuse(label, current, wanted)
    end
  end

  # Compared without printing: the whole point of a token is that it does not
  # appear in a deploy log.
  defp settle_token(force?, wanted) when is_binary(wanted) do
    current = Publishing.token()

    cond do
      blank?(current) ->
        Publishing.put_token(wanted)
        Mix.shell().info([:green, "· token set", :reset])

      current == wanted ->
        Mix.shell().info([:green, "· token already matches", :reset])

      force? ->
        Publishing.put_token(wanted)
        Mix.shell().info([:yellow, "· token CHANGED", :reset])

      true ->
        Mix.shell().info([
          :yellow,
          "· token differs from the one in the deploy configuration, and was NOT changed.\n",
          :reset,
          "  Publishing will fail with a 401 if the stored one is wrong. To replace it:\n",
          "    mix pairings.publishing --force --token ...\n"
        ])
    end
  end

  defp settle_token(_force?, _wanted), do: :ok

  defp refuse(label, current, wanted) do
    Mix.shell().info([
      :yellow,
      "· #{label} is already set and was NOT changed.\n",
      :reset,
      "    now:    #{current}\n",
      "    deploy: #{wanted}\n",
      "  Somebody may have set this deliberately. To replace it:\n",
      "    mix pairings.publishing --force ...\n"
    ])
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # `put_endpoint/1` normalises (adds a scheme, drops a trailing slash), so a
  # deploy passing "openresults.example" must not read as different from the
  # stored "https://openresults.example" and warn on every single deploy.
  defp normalised_match?(current, wanted) do
    String.trim_trailing(current, "/") ==
      wanted |> String.trim() |> String.trim_trailing("/") |> ensure_scheme()
  end

  defp ensure_scheme(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "https://" <> url
  end
end
