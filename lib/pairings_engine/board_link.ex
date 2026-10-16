defmodule PairingsEngine.BoardLink do
  @moduledoc """
  The link with a box in the playing hall that reads electronic boards
  (Alnasl). The box is told who sits where; it tells back what the boards
  saw. The wire format is `docs/board-link-api.md`, and that document, not
  this one, is what the other half is built against.

  ## The one rule

  **A board never enters a result.** What a board reports is stored beside
  the pairing (`PairingsEngine.BoardLink.Game`) and shown to the arbiter,
  who types the result as before. When the two disagree the page says so in
  red and blocks nothing. A sensor board is a witness; it is not the arbiter.

  ## Codes

  A connect code is a server address and a secret. The box always calls us;
  we never call the box, so the hall opens no port and a desktop copy on the
  same PC works without a network.

    * a code for one tournament (`create_link/2`);
    * a code for a tournament group (`create_group_link/2`): every member
      its maker may open, read at the moment the box asks. A tournament
      added to the group next week reaches the box without a new scan; one
      the maker loses access to stops reaching it.
    * a code for an account (`connect/2`): every tournament that account
      may edit and that is still current, read the same way. It is not
      typed or scanned: the box sends the arbiter's browser to a consent
      page here, and gets the code back through a one-time grant
      (`redeem_grant/1`). It is the group code with the account as the
      group, and goes through the same paths.

  The secret is random, shown once and kept as a SHA-256. Losing it costs a
  click (`create_link/2` again); having it in a readable column would cost
  more. Several codes may exist side by side, one per box.

  A desktop copy that lets boxes on the hall network connect
  (`PairingsEngineWeb.BoardLan`) makes a second kind, `reach: "lan"`: it
  carries the PC's network address, it is the only kind the network
  listener accepts, and it stops working thirty days after it was made,
  because its secret crosses the hall in plain http.

  ## Current, for an account code

  An account code would otherwise hand a box every tournament its owner
  ever ran. It reaches the ones that are still current: not finished, or
  finished no more than fourteen days ago (by the last round's date, or by
  the last change to a tournament that has no dates). A tournament without
  a round yet is current; so is one that is "running" because a postponed
  game is still to be played, however old.

  ## Who may

  Whoever may edit the tournament - its owner or an accepted collaborator,
  the rule every other tournament page uses - and never on an archived or
  handed-off one. The group has no owner (`PairingsEngine.TournamentGroups`),
  so a group code is made from one of its tournaments by somebody who may
  edit that one.

  ## Games are keyed by the game, not by the board number

  `pairings.game_uid`. Board 7 of round 4 is a seat; after a swap somebody
  else sits there. A report names the game and the two players it believes
  are playing it, and a report for a game that is gone, or whose players
  changed, is refused by name (`:pairing_gone`, `:pairing_changed`) rather
  than filed under whoever sits there now.
  """

  import Ecto.Query

  alias PairingsEngine.{Audit, Publishing, Repo, Results, TournamentGroups, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.BoardLink.{Document, Game, Grant, Link, RelayKeys}
  alias PairingsEngine.TournamentGroups.Member
  alias PairingsEngine.Tournaments.{Collaborator, Pairing, Round, Tournament}

  @tournament_prefix "oplt_"
  @group_prefix "oplg_"
  @account_prefix "oplu_"

  # How long a grant waits for the box to trade it in. The browser carries
  # it straight back, so the box asks within seconds; two minutes covers a
  # slow hall network and nothing else.
  @grant_seconds 120

  # A finished tournament stays on an account code this long: long enough
  # for a late correction, short enough that last season is not on the box.
  @finished_days 14

  # 256 bits, like the publishing key next door: it is sized against
  # guessing, not against enumeration.
  @secret_bytes 32

  # One per box, and nobody runs nine boxes. A ceiling so that a stuck
  # "New code" button cannot fill a table.
  @max_links 8

  # A row is touched at most this often for "last contact". The box polls
  # every few seconds, and a write per poll would be a SQLite write lock per
  # poll, to keep a timestamp nobody reads to the second.
  @touch_every_s 30

  @max_plies 1000
  @max_pgn_bytes 100_000
  @san ~r/\A[A-Za-z0-9+#=\-]{2,10}\z/

  ## ---------- codes ----------

  @doc "How many codes one tournament, one group, or one account may have at a time."
  def max_links, do: @max_links

  @doc "How long a grant is good for, in seconds."
  def grant_seconds, do: @grant_seconds

  @doc "How many days after it finished a tournament still reaches an account code."
  def finished_days, do: @finished_days

  @doc """
  Makes a connect code for `tournament`. `{:ok, link, secret}` - the secret
  is in the caller's hands and nowhere else from here on.
  """
  @spec create_link(Scope.t(), Tournament.t(), keyword()) ::
          {:ok, Link.t(), String.t()} | {:error, atom()}
  def create_link(%Scope{} = scope, %Tournament{} = tournament, opts \\ []) do
    with {:ok, tournament} <- editable(scope, tournament),
         :ok <- room(from(l in Link, where: l.tournament_id == ^tournament.id)) do
      {link, secret} =
        insert_link(scope, @tournament_prefix, [tournament_id: tournament.id] ++ reach(opts))

      Audit.log(
        tournament.id,
        scope,
        "boards.code_created",
        Map.merge(%{hint: link.secret_hint}, lan_details(link))
      )

      notify(tournament.id)
      # A box is coming: have its permission for the results site waiting.
      Publishing.Drain.nudge()
      {:ok, link, secret}
    end
  end

  @doc """
  Makes a connect code for the group `tournament` is in. See the moduledoc
  for what it reaches.
  """
  @spec create_group_link(Scope.t(), Tournament.t(), keyword()) ::
          {:ok, Link.t(), String.t()} | {:error, atom()}
  def create_group_link(%Scope{} = scope, %Tournament{} = tournament, opts \\ []) do
    with {:ok, tournament} <- editable(scope, tournament),
         %Member{} = member <-
           TournamentGroups.membership(tournament.id) || {:error, :not_grouped},
         :ok <- room(from(l in Link, where: l.group_id == ^member.group_id)) do
      {link, secret} =
        insert_link(scope, @group_prefix, [group_id: member.group_id] ++ reach(opts))

      Audit.log(
        tournament.id,
        scope,
        "boards.group_code_created",
        Map.merge(%{hint: link.secret_hint, group: member.group.name}, lan_details(link))
      )

      notify(tournament.id)
      # For every member that is on the results site, not only this one -
      # `RelayKeys.sweep/1` looks at them all.
      Publishing.Drain.nudge()
      {:ok, link, secret}
    end
  end

  ## ---------- account codes ----------

  @doc """
  "Allow" on the consent page: makes an account code for `scope`'s account
  and a grant for it. `{:ok, link, grant}` - the grant goes back to the box
  in the browser's address bar and is traded for the code by
  `redeem_grant/1`, once, within #{@grant_seconds} seconds.

  `label: "Alnasl - Hall A"` is what the box asked to be called, kept for
  the account page. `{:error, :too_many_codes}` past #{@max_links}.
  """
  @spec connect(Scope.t(), keyword()) :: {:ok, Link.t(), String.t()} | {:error, atom()}
  def connect(%Scope{user: %User{} = user} = scope, opts \\ []) do
    label = clip(Keyword.get(opts, :label), 80)

    with :ok <- room(from(l in Link, where: l.user_id == ^user.id)) do
      {link, secret} = insert_link(scope, @account_prefix, user_id: user.id, label: label)
      grant = issue_grant(link, secret)

      Audit.log_system(scope, "boards.account_code_created", %{
        hint: link.secret_hint,
        box: label
      })

      Publishing.Drain.nudge()
      {:ok, link, grant}
    end
  end

  @doc "The account codes of `scope`'s account, oldest first."
  def list_account_links(%Scope{user: %User{id: user_id}}),
    do: Repo.all(from l in Link, where: l.user_id == ^user_id, order_by: l.id)

  def list_account_links(_scope), do: []

  @doc """
  Withdraws account code `link_id`, which must be `scope`'s own. The box
  holding it is refused from the next request on.
  """
  @spec revoke_account_link(Scope.t(), term()) :: {:ok, Link.t()} | {:error, :not_found}
  def revoke_account_link(%Scope{user: %User{id: user_id}} = scope, link_id) do
    with id when is_integer(id) <- to_id(link_id),
         %Link{} = link <-
           Repo.one(from l in Link, where: l.id == ^id and l.user_id == ^user_id) do
      reached = covered_ids(link)
      Repo.delete!(link)

      Audit.log_system(scope, "boards.account_code_revoked", %{
        hint: link.secret_hint,
        box: link.label || link.box_name
      })

      Enum.each(reached, &notify/1)
      {:ok, link}
    else
      _none -> {:error, :not_found}
    end
  end

  # The secret, sealed under a key only the grant can make. The grant itself
  # is kept as a hash, like every secret here.
  defp issue_grant(%Link{} = link, secret) do
    grant = Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Grant{
      grant_hash: hash(grant),
      link_id: link.id,
      sealed: seal(secret, grant),
      expires_at: DateTime.add(now, @grant_seconds, :second)
    })

    grant
  end

  @doc """
  Trades a grant for the secret of the account code it stands for:
  `{:ok, secret}` the first time, within #{@grant_seconds} seconds, and
  `:error` ever after - used, run out, never issued, or for a code that has
  been withdrawn since. Like `authenticate/2`, it does not say which.
  """
  @spec redeem_grant(term()) :: {:ok, String.t()} | :error
  def redeem_grant(grant) when is_binary(grant) and byte_size(grant) in 20..200 do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    # Whatever has run out goes first, so an old grant is not merely
    # refused but gone.
    Repo.delete_all(from g in Grant, where: g.expires_at <= ^now)

    with %Grant{} = row <- Repo.get_by(Grant, grant_hash: hash(grant)),
         # The delete is the use: of two requests with the same grant, the
         # one whose delete removed the row is the one that gets the code.
         {1, _} <- Repo.delete_all(from g in Grant, where: g.id == ^row.id),
         %Link{} <- Repo.get(Link, row.link_id),
         {:ok, secret} <- unseal(row.sealed, grant) do
      {:ok, secret}
    else
      _refused -> :error
    end
  end

  def redeem_grant(_other), do: :error

  @grant_aad "board-link-grant"

  defp grant_key(grant), do: :crypto.hash(:sha256, "board-link-grant-key:" <> grant)

  defp seal(secret, grant) do
    iv = :crypto.strong_rand_bytes(12)

    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, grant_key(grant), iv, secret, @grant_aad, true)

    iv <> tag <> cipher
  end

  defp unseal(<<iv::binary-12, tag::binary-16, cipher::binary>>, grant) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           grant_key(grant),
           iv,
           cipher,
           @grant_aad,
           tag,
           false
         ) do
      secret when is_binary(secret) -> {:ok, secret}
      :error -> :error
    end
  end

  defp unseal(_other, _grant), do: :error

  @doc """
  Withdraws code `link_id`, which must be one of `tournament`'s own or one
  of its group's. The box holding it is refused from the next request on.
  """
  @spec revoke_link(Scope.t(), Tournament.t(), integer()) :: {:ok, Link.t()} | {:error, atom()}
  def revoke_link(%Scope{} = scope, %Tournament{} = tournament, link_id) do
    with {:ok, tournament} <- editable(scope, tournament),
         %Link{} = link <- find_link(tournament, link_id) || {:error, :not_found} do
      Repo.delete!(link)

      Audit.log(tournament.id, scope, "boards.code_revoked", %{
        hint: link.secret_hint,
        group: not is_nil(link.group_id),
        box: link.box_name
      })

      notify(tournament.id)
      {:ok, link}
    end
  end

  @doc """
  The codes that reach `tournament`: `%{tournament: [link], group: [link]}`,
  oldest first. `group` is empty for a tournament in no group.
  """
  def list_links(%Tournament{id: id}) do
    group_id = group_id(id)

    %{
      tournament: Repo.all(from l in Link, where: l.tournament_id == ^id, order_by: l.id),
      group:
        if(group_id,
          do: Repo.all(from l in Link, where: l.group_id == ^group_id, order_by: l.id),
          else: []
        )
    }
  end

  @doc """
  Whether `tournament_id` has live boards as far as this machine can tell: a
  code reaches it, or a board has reported a game of it. The Pairings page
  draws its board column on this and on nothing else.
  """
  def connected?(tournament_id) when is_integer(tournament_id) do
    Repo.exists?(reaching(tournament_id)) or
      Repo.exists?(from g in Game, where: g.tournament_id == ^tournament_id) or
      account_reaches?(tournament_id)
  end

  @doc """
  The account codes that reach `tournament_id` now: those of its owner and
  of its accepted collaborators, while it is current (see the moduledoc).
  """
  def account_links(tournament_id) when is_integer(tournament_id) do
    if current?(tournament_id),
      do: Repo.all(account_links_query(tournament_id) |> order_by([l], l.id) |> preload(:user)),
      else: []
  end

  defp account_reaches?(tournament_id),
    do: Repo.exists?(account_links_query(tournament_id)) and current?(tournament_id)

  defp current?(tournament_id),
    do: Repo.exists?(current(live_tournaments()) |> where([t], t.id == ^tournament_id))

  # The rule `Tournaments.authorized_tournament_ids/1` applies, turned round:
  # not "which tournaments may this account open" but "which accounts may
  # open this tournament". The tests hold the two against each other.
  defp account_links_query(tournament_id) do
    from l in Link,
      join: u in User,
      as: :user,
      on: u.id == l.user_id,
      join: t in Tournament,
      on: t.id == ^tournament_id,
      where: is_nil(t.deleted_at),
      where:
        t.user_id == u.id or
          exists(
            from c in Collaborator,
              where:
                c.tournament_id == ^tournament_id and c.status == "accepted" and
                  (c.user_id == parent_as(:user).id or c.email == parent_as(:user).email)
          )
  end

  # The codes that reach a tournament: its own, and its group's if it is in
  # one. Two queries' worth of `where`, because Ecto will not compare a
  # column with a nil it was handed, and is right not to.
  defp reaching(tournament_id) do
    case group_id(tournament_id) do
      nil ->
        from l in Link, where: l.tournament_id == ^tournament_id

      group_id ->
        from l in Link, where: l.tournament_id == ^tournament_id or l.group_id == ^group_id
    end
  end

  defp group_id(tournament_id) do
    case TournamentGroups.membership(tournament_id) do
      %Member{group_id: group_id} -> group_id
      nil -> nil
    end
  end

  defp find_link(%Tournament{id: id}, link_id) when is_integer(link_id),
    do: Repo.one(from l in reaching(id), where: l.id == ^link_id)

  defp find_link(_tournament, _link_id), do: nil

  defp room(query) do
    if Repo.aggregate(query, :count, :id) < @max_links, do: :ok, else: {:error, :too_many_codes}
  end

  defp insert_link(%Scope{user: user}, prefix, target) do
    secret = prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)

    link =
      %Link{
        secret_hash: hash(secret),
        secret_hint: String.slice(secret, -4, 4),
        created_by_id: user && user.id
      }
      |> struct!(target)
      |> Repo.insert!()

    {link, secret}
  end

  # `lan: "http://192.168.1.20:4747"` makes a code for a box on the network.
  # Only a desktop copy has such a thing; anywhere else the option is not
  # an option and the code is an ordinary one.
  defp reach(opts) do
    case Keyword.get(opts, :lan) do
      address when is_binary(address) and address != "" ->
        if PairingsEngine.Authz.local_mode?() do
          # No date: a weekly club competition must not be cut off
          # mid-season. The owner withdraws the code when the event is over.
          [reach: "lan", address: address, expires_at: nil]
        else
          []
        end

      _none ->
        []
    end
  end

  defp lan_details(%Link{reach: "lan", address: address}), do: %{lan: true, address: address}
  defp lan_details(%Link{}), do: %{}

  @doc "Whether `link` has run out. Only a row that carries a date ever does."
  def expired?(link, now \\ DateTime.utc_now())
  def expired?(%Link{expires_at: nil}, _now), do: false
  def expired?(%Link{expires_at: at}, now), do: DateTime.compare(at, now) != :gt

  @doc """
  Whether a code for a box on the network exists that can still open
  something: not run out, and not for a tournament that is deleted, archived
  or handed off. The network listener is up while this is true and down
  while it is not (`PairingsEngineWeb.BoardLan`).
  """
  def lan_codes? do
    now = DateTime.utc_now()

    Repo.exists?(
      from l in Link,
        left_join: t in Tournament,
        on: t.id == l.tournament_id,
        where: l.reach == "lan" and (is_nil(l.expires_at) or l.expires_at > ^now),
        where:
          not is_nil(l.group_id) or
            (is_nil(t.deleted_at) and is_nil(t.archived_at) and is_nil(t.handed_off_at))
    )
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  # The page loaded the tournament through `get_authorized_tournament!/2`;
  # this asks again, because a function that hands out credentials should
  # not take the caller's word for who the caller is.
  defp editable(%Scope{} = scope, %Tournament{id: id}) do
    case Tournaments.get_authorized_tournament(scope, id) do
      %Tournament{} = tournament ->
        with :ok <- Tournaments.ensure_writable(tournament), do: {:ok, tournament}

      nil ->
        {:error, :not_found}
    end
  end

  ## ---------- the box's side ----------

  @doc """
  The link `secret` opens, or `:error`. A secret is looked up by its hash.

  A code that has run out opens nothing. With `lan: true` - the request came
  in on the network listener - only a code that was made for the network
  does: a code for a box on this PC never crossed a wire, and is not
  accepted from one. Every refusal is the same `:error`; the caller is told
  that the code does not work, not which rule it broke.
  """
  @spec authenticate(term(), keyword()) :: {:ok, Link.t()} | :error
  def authenticate(secret, opts \\ [])

  def authenticate(secret, opts) when is_binary(secret) and byte_size(secret) in 20..200 do
    case Repo.get_by(Link, secret_hash: hash(secret)) do
      %Link{} = link ->
        cond do
          expired?(link) -> :error
          Keyword.get(opts, :lan, false) and link.reach != "lan" -> :error
          true -> {:ok, link}
        end

      nil ->
        :error
    end
  end

  def authenticate(_other, _opts), do: :error

  @doc """
  Notes that the box called, and what it calls itself. Written at most every
  #{@touch_every_s} seconds unless the name or version changed.
  """
  def touch(%Link{} = link, box \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    name = clip(box[:name], 80) || link.box_name
    version = clip(box[:version], 40) || link.box_version

    due? =
      is_nil(link.last_seen_at) or DateTime.diff(now, link.last_seen_at) >= @touch_every_s or
        name != link.box_name or version != link.box_version

    if due? do
      first? = is_nil(link.last_seen_at)

      link =
        link
        |> Ecto.Changeset.change(last_seen_at: now, box_name: name, box_version: version)
        |> Repo.update!()

      # The first call is news - to the settings page, where "never used"
      # becomes a box with a name, and to the audit trail, which should know
      # that a machine started reading this tournament. The calls after it
      # are not.
      if first? do
        for id <- covered_ids(link) do
          Audit.log(id, nil, "boards.box_connected", %{
            box: name,
            version: version,
            hint: link.secret_hint
          })

          notify(id)
        end

        Publishing.Drain.nudge()
      end

      link
    else
      link
    end
  end

  @doc """
  Stores how many boards the box says it has on each tournament:
  `%{tournament_id => count}`. Counts for tournaments the link does not
  reach are dropped.
  """
  def put_box_boards(%Link{} = link, counts) when is_map(counts) do
    ids = covered_ids(link)

    boards =
      for {key, count} <- counts,
          id = to_id(key),
          id in ids,
          is_integer(count) and count >= 0 and count <= 9999,
          into: %{},
          do: {Integer.to_string(id), count}

    link = link |> Ecto.Changeset.change(box_boards: boards) |> Repo.update!()
    Enum.each(ids, &notify/1)
    link
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _other -> nil
    end
  end

  defp to_id(_other), do: nil

  defp clip(value, max) when is_binary(value) do
    case value |> String.replace(~r/[\x00-\x1F\x7F]/, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, max)
    end
  end

  defp clip(_other, _max), do: nil

  @doc """
  The tournaments `link` reaches, in order, each as
  `%{tournament: %Tournament{}, label: String.t() | nil}`.

  Never one in the recycle bin, archived or handed off: those are finished
  business here, and a box has no use for a tournament it may not report to.
  A group code reaches the members its maker may open - the switcher's rule
  (`TournamentGroups.switcher/2`) with a box in the place of a person.
  """
  def covered(%Link{tournament_id: id}) when is_integer(id) do
    case Repo.one(live_tournaments() |> where([t], t.id == ^id)) do
      %Tournament{} = tournament -> [%{tournament: tournament, label: nil}]
      nil -> []
    end
  end

  def covered(%Link{group_id: group_id, created_by_id: user_id})
      when is_integer(group_id) and is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        allowed = Tournaments.authorized_tournament_ids(Scope.for_user(user))

        Repo.all(
          from t in live_tournaments(),
            join: m in Member,
            on: m.tournament_id == t.id,
            where: m.group_id == ^group_id and t.id in subquery(allowed),
            order_by: [asc: m.position, asc: m.id],
            select: %{tournament: t, label: m.label}
        )

      nil ->
        []
    end
  end

  # An account code: the group code's rule with the account as the group -
  # every tournament the account may open, as it stands at this request -
  # and only the current ones.
  def covered(%Link{user_id: user_id}) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        allowed = Tournaments.authorized_tournament_ids(Scope.for_user(user))

        Repo.all(
          from t in current(live_tournaments()),
            where: t.id in subquery(allowed),
            order_by: [asc: t.id],
            select: %{tournament: t, label: nil}
        )

      nil ->
        []
    end
  end

  # A group code whose maker's account is gone reaches nothing: there is
  # nobody left whose access it could be borrowing.
  def covered(%Link{}), do: []

  defp live_tournaments do
    from t in Tournament,
      where: is_nil(t.deleted_at) and is_nil(t.archived_at) and is_nil(t.handed_off_at)
  end

  # Not finished, or finished recently. `end_date` is the last round's date
  # as ISO text, which compares as a date; a tournament without dates is
  # judged by when it last changed - and finishing it was a change.
  defp current(query) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@finished_days * 86_400, :second)
      |> DateTime.truncate(:second)

    cutoff_date = cutoff |> DateTime.to_date() |> Date.to_iso8601()

    from t in query,
      where:
        t.status != "finished" or
          (t.end_date != "" and t.end_date >= ^cutoff_date) or
          ((is_nil(t.end_date) or t.end_date == "") and t.updated_at >= ^cutoff)
  end

  defp covered_ids(%Link{} = link), do: Enum.map(covered(link), & &1.tournament.id)

  @doc "The tournament `id` if `link` reaches it, else `:error`."
  def fetch_covered(%Link{} = link, id) do
    case Enum.find(covered(link), &(&1.tournament.id == to_id(id))) do
      %{tournament: tournament} -> {:ok, tournament}
      nil -> :error
    end
  end

  @doc """
  What `link` gives access to: the kind of code, the group's name for a group
  code, and each tournament with its `version` (`Document.version/1`).
  """
  def listing(%Link{} = link) do
    group = link.group_id && Repo.get(TournamentGroups.Group, link.group_id)

    %{
      "kind" => kind(link),
      "group" => group && %{"name" => group.name},
      "tournaments" =>
        Enum.map(covered(link), fn %{tournament: t, label: label} ->
          %{
            "id" => t.id,
            "name" => t.name,
            "label" => label,
            "state" => t.status,
            "version" => Document.version(t)
          }
        end)
    }
  end

  defp kind(%Link{group_id: id}) when is_integer(id), do: "group"
  defp kind(%Link{user_id: id}) when is_integer(id), do: "account"
  defp kind(%Link{}), do: "tournament"

  ## ---------- the relay key ----------

  @doc """
  "Try again", after the results site refused to hand out a key for
  `tournament`'s box. See `PairingsEngine.BoardLink.RelayKeys`.
  """
  @spec retry_relay_key(Scope.t(), Tournament.t()) :: {:ok, Tournament.t()} | {:error, atom()}
  def retry_relay_key(%Scope{} = scope, %Tournament{} = tournament) do
    with {:ok, tournament} <- editable(scope, tournament) do
      RelayKeys.ask_again(tournament)
      {:ok, tournament}
    end
  end

  @doc """
  Asks the results site for a new key for `tournament`'s box. The site stops
  accepting the old one the moment it hands out the new one; until then the
  old one is kept, so a site that cannot be reached costs nothing.
  """
  @spec replace_relay_key(Scope.t(), Tournament.t()) :: {:ok, Tournament.t()} | {:error, atom()}
  def replace_relay_key(%Scope{} = scope, %Tournament{} = tournament) do
    with {:ok, tournament} <- editable(scope, tournament) do
      Audit.log(tournament.id, scope, "boards.relay_key_replace", %{})
      RelayKeys.ask_again(tournament, replace: true)
      {:ok, tournament}
    end
  end

  @doc """
  Stores a relay key somebody pasted for `tournament` (nil or blank clears
  it), to be handed to the box over the link. The fallback for a results
  site that cannot hand one out by itself - see
  `PairingsEngine.BoardLink.RelayKeys` for the normal way.
  """
  @spec set_relay_key(Scope.t(), Tournament.t(), String.t() | nil) ::
          {:ok, Tournament.t()} | {:error, atom()}
  def set_relay_key(%Scope{} = scope, %Tournament{} = tournament, key) do
    key = if is_binary(key), do: String.trim(key), else: ""

    with {:ok, tournament} <- editable(scope, tournament),
         :ok <- relay_key_shape(key) do
      tournament =
        tournament
        |> Ecto.Changeset.change(openresults_relay_key: if(key == "", do: nil, else: key))
        |> Repo.update!()

      if key == "",
        do: Audit.log(tournament.id, scope, "boards.relay_key_cleared", %{}),
        else: Audit.log(tournament.id, scope, "boards.relay_key_saved", %{})

      RelayKeys.pasted(tournament.id)
      notify(tournament.id)
      {:ok, tournament}
    end
  end

  # Not "is this a relay key" - only the results site knows that. Just "is
  # this something that can go in an Authorization header".
  defp relay_key_shape(""), do: :ok

  defp relay_key_shape(key) do
    if byte_size(key) in 16..200 and key =~ ~r/\A[\x21-\x7E]+\z/,
      do: :ok,
      else: {:error, :relay_key_shape}
  end

  @doc """
  Where the box sends the moves, or nil while this tournament is not on a
  results site: `%{"server_url", "slug", "relay_key"}`. The address is the
  one spectators are given (`Publishing.public_base/0`), never the loopback
  one a server that hosts both uses for itself. `relay_key` is nil until one
  has been fetched (`PairingsEngine.BoardLink.RelayKeys`) or pasted.
  """
  def openresults_target(%Tournament{} = tournament) do
    base = Publishing.public_base()

    if tournament.publish_to_openresults and is_binary(base) and
         is_binary(tournament.public_slug) and Publishing.on_site?(tournament) do
      %{
        "server_url" => String.trim_trailing(base, "/"),
        "slug" => tournament.public_slug,
        "relay_key" => tournament.openresults_relay_key
      }
    end
  end

  ## ---------- reports ----------

  @doc """
  One board's report of one game. The whole game each time; `seq` decides
  which of two reports is the newer.

  `{:ok, %{applied: boolean, seq: integer, reason: atom | nil}}`, or
  `{:error, code, detail}` with `code` one of `:invalid_request`,
  `:pairing_gone`, `:pairing_changed`, `:not_a_game`. Nothing is written on
  an error. The tournament's result is not touched by any of it.
  """
  @spec report(Link.t(), Tournament.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def report(%Link{} = link, %Tournament{} = tournament, params) when is_map(params) do
    with {:ok, attrs} <- cast_report(params),
         {:ok, pairing} <- pairing_for(tournament.id, attrs.game_uid),
         :ok <- same_players(pairing, attrs) do
      store(link, tournament, attrs)
    end
  end

  def report(_link, _tournament, _params),
    do: {:error, :invalid_request, "a game is a JSON object"}

  defp pairing_for(tournament_id, game_uid) do
    pairing =
      Repo.one(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and p.game_uid == ^game_uid,
          limit: 1
      )

    cond do
      is_nil(pairing) ->
        {:error, :pairing_gone,
         "no game #{game_uid} in this tournament: the round was paired again or the board removed"}

      is_nil(pairing.white_player_id) or is_nil(pairing.black_player_id) or
          pairing.result == "bye" ->
        {:error, :not_a_game, "game #{game_uid} is a bye or an empty board"}

      true ->
        {:ok, pairing}
    end
  end

  defp same_players(%Pairing{} = pairing, attrs) do
    if pairing.white_player_id == attrs.white and pairing.black_player_id == attrs.black,
      do: :ok,
      else:
        {:error, :pairing_changed,
         "game #{attrs.game_uid} is no longer between these two players, or the colours changed"}
  end

  defp store(%Link{} = link, %Tournament{id: tournament_id}, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, outcome} =
      Repo.transaction(fn ->
        held = Repo.get_by(Game, tournament_id: tournament_id, game_uid: attrs.game_uid)

        cond do
          held && not attrs.replace && attrs.seq < held.seq ->
            {%{applied: false, seq: held.seq, reason: :stale}, nil}

          held && not attrs.replace && attrs.seq == held.seq ->
            {%{applied: false, seq: held.seq, reason: :duplicate}, nil}

          true ->
            game =
              (held || %Game{tournament_id: tournament_id, game_uid: attrs.game_uid})
              |> Ecto.Changeset.change(
                attrs
                |> Map.take(
                  ~w(seq status result moves move_clocks white_ms black_ms running start_fen pgn
                     reconstructed guessed rewritten)a
                )
                |> Map.merge(%{
                  link_id: link.id,
                  reported_at: now,
                  first_reported_at: (held && held.first_reported_at) || now,
                  finished_at:
                    if(attrs.status == "finished",
                      do: (held && held.finished_at) || now
                    )
                })
              )
              |> Repo.insert_or_update!()

            kind =
              if is_nil(held) or held.status != game.status or held.result != game.result,
                do: :state,
                else: :moves

            {%{applied: true, seq: game.seq, reason: nil}, kind}
        end
      end)

    case outcome do
      {answer, nil} ->
        {:ok, answer}

      {answer, kind} ->
        Phoenix.PubSub.broadcast(
          PairingsEngine.PubSub,
          topic(tournament_id),
          {:board_game, tournament_id, attrs.game_uid, kind}
        )

        {:ok, answer}
    end
  end

  # --- reading a report ---
  #
  # No chess is checked here: this repository has no move generator, and a
  # half-right one would refuse real games. A move is kept as the box wrote
  # it, provided it is shaped like one - the character set of SAN and
  # nothing else, which is also what keeps a move from carrying a quote or a
  # brace into a PGN file. The box checks legality; that is its job.

  defp cast_report(p) do
    with {:ok, game_uid} <- uid(p["game"]),
         {:ok, white} <- player_id(p["white"], "white"),
         {:ok, black} <- player_id(p["black"], "black"),
         {:ok, seq} <- bounded_int(p["seq"], "seq", 0, 9_007_199_254_740_991, :required),
         {:ok, moves} <- moves(Map.get(p, "moves", [])),
         {:ok, move_clocks} <- move_clocks(Map.get(p, "move_clocks"), length(moves)),
         {:ok, white_ms} <- bounded_int(p["white_ms"], "white_ms", 0, 360_000_000, nil),
         {:ok, black_ms} <- bounded_int(p["black_ms"], "black_ms", 0, 360_000_000, nil),
         {:ok, running} <- one_of(p["running"], "running", ~w(white black none), nil),
         {:ok, status} <- one_of(p["status"], "status", Game.statuses(), "live"),
         {:ok, result} <- result(p["result"]),
         {:ok, reconstructed} <- bounded_int(p["reconstructed"], "reconstructed", 0, 2000, 0),
         {:ok, guessed} <- bounded_int(p["guessed"], "guessed", 0, 2000, 0),
         {:ok, rewritten} <- bounded_int(p["rewritten"], "rewritten", 0, 2000, 0),
         {:ok, start_fen} <- text(p["start_fen"], "start_fen", 100),
         {:ok, pgn} <- text(p["pgn"], "pgn", @max_pgn_bytes) do
      {:ok,
       %{
         game_uid: game_uid,
         white: white,
         black: black,
         seq: seq,
         moves: moves,
         move_clocks: move_clocks,
         white_ms: white_ms,
         black_ms: black_ms,
         running: if(running == "none", do: nil, else: running),
         status: status,
         result: result,
         reconstructed: reconstructed,
         guessed: guessed,
         rewritten: rewritten,
         start_fen: start_fen,
         pgn: pgn,
         replace: p["replace"] == true
       }}
    end
  end

  defp invalid(detail), do: {:error, :invalid_request, detail}

  defp uid(value) when is_binary(value) and byte_size(value) in 1..64, do: {:ok, value}
  defp uid(_other), do: invalid("game: the game's id, as the tournament document gives it")

  defp player_id(value, _side) when is_integer(value) and value > 0, do: {:ok, value}
  defp player_id(_other, side), do: invalid("#{side}: the player's id, an integer")

  defp bounded_int(nil, name, _min, _max, :required), do: invalid("#{name} is required")
  defp bounded_int(nil, _name, _min, _max, default), do: {:ok, default}

  defp bounded_int(value, _name, min, max, _default)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_int(_other, name, min, max, _default),
    do: invalid("#{name}: an integer from #{min} to #{max}")

  defp one_of(nil, _name, _allowed, default), do: {:ok, default}

  defp one_of(value, name, allowed, _default) do
    if value in allowed,
      do: {:ok, value},
      else: invalid("#{name}: one of #{Enum.join(allowed, ", ")}")
  end

  # `*` and null both mean "the board saw no result".
  defp result(value) when value in [nil, "*", ""], do: {:ok, nil}

  defp result(value) do
    if value in Game.results(),
      do: {:ok, value},
      else: invalid("result: 1-0, 1/2-1/2, 0-1, or null")
  end

  defp text(nil, _name, _max), do: {:ok, nil}

  defp text(value, name, max) when is_binary(value) do
    if byte_size(value) <= max and String.valid?(value),
      do: {:ok, value},
      else: invalid("#{name}: text of at most #{max} bytes")
  end

  defp text(_other, name, _max), do: invalid("#{name}: text")

  defp moves(list) when is_list(list) and length(list) <= @max_plies do
    case Enum.find_index(list, &(not (is_binary(&1) and &1 =~ @san))) do
      nil -> {:ok, list}
      index -> invalid("moves: ply #{index + 1} is not a move in SAN")
    end
  end

  defp moves(_other), do: invalid("moves: a list of at most #{@max_plies} moves in SAN")

  defp move_clocks(nil, _plies), do: {:ok, []}

  defp move_clocks(list, plies) when is_list(list) and length(list) == plies do
    if Enum.all?(list, &(is_nil(&1) or (is_integer(&1) and &1 >= 0 and &1 <= 360_000_000))),
      do: {:ok, list},
      else: invalid("move_clocks: milliseconds or null, one per move")
  end

  defp move_clocks(_other, _plies),
    do: invalid("move_clocks: as many entries as there are moves")

  ## ---------- what the arbiter's pages read ----------

  @doc "The PubSub topic a tournament's board reports are announced on."
  def topic(tournament_id), do: "board_link:#{tournament_id}"

  @doc "Subscribes the caller to `topic/1`."
  def subscribe(tournament_id),
    do: Phoenix.PubSub.subscribe(PairingsEngine.PubSub, topic(tournament_id))

  @doc false
  # For `PairingsEngine.BoardLink.RelayKeys`: a key arrived, or did not.
  def announce(tournament_id), do: notify(tournament_id)

  # A code made or withdrawn, a relay key saved, a box seen for the first
  # time: the settings page and the Pairings page's column both care.
  defp notify(tournament_id) do
    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      topic(tournament_id),
      {:board_link, tournament_id}
    )
  end

  @doc """
  The pairing `game_uid` names in `tournament_id`, with its round and both
  players, or nil - also nil for a bye, which is not a game.
  """
  def get_pairing(tournament_id, game_uid) when is_binary(game_uid) do
    Repo.one(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.game_uid == ^game_uid,
        where: not is_nil(p.white_player_id) and not is_nil(p.black_player_id),
        limit: 1,
        preload: [:round, :white_player, :black_player]
    )
  end

  def get_pairing(_tournament_id, _game_uid), do: nil

  @doc "The game a board reported for `game_uid`, or nil."
  def get_game(tournament_id, game_uid) when is_binary(game_uid),
    do: Repo.get_by(Game, tournament_id: tournament_id, game_uid: game_uid)

  def get_game(_tournament_id, _game_uid), do: nil

  @doc "Every reported game of the tournament, as `%{game_uid => %Game{}}`."
  def games_by_uid(tournament_id) do
    Repo.all(from g in Game, where: g.tournament_id == ^tournament_id)
    |> Map.new(&{&1.game_uid, &1})
  end

  @doc """
  The same without the moves, for a page that shows a column and not a game:
  `%{game_uid => %{status, result, plies, reconstructed, guessed, rewritten}}`.
  """
  def summaries(tournament_id) do
    Repo.all(
      from g in Game,
        where: g.tournament_id == ^tournament_id,
        select: %{
          game_uid: g.game_uid,
          status: g.status,
          result: g.result,
          moves: g.moves,
          reconstructed: g.reconstructed,
          guessed: g.guessed,
          rewritten: g.rewritten
        }
    )
    |> Map.new(fn g ->
      {g.game_uid, g |> Map.put(:plies, length(g.moves)) |> Map.delete(:moves)}
    end)
  end

  @doc """
  How the arbiter's result for a board stands against what the board saw.

    * `:none` - the board reported nothing for this game;
    * `:live` - a game in progress, no result from the board;
    * `:pending` - the board saw a result and the arbiter has not entered one;
    * `:match` - both say the same;
    * `:mismatch` - they differ. The one case that is drawn in red.

  A forfeit entered by the arbiter is compared by who got the point: a board
  that saw 1-0 and an arbiter who wrote 1-0FF agree about the point, and the
  rest is the arbiter's business. A result with no over-the-board twin
  (0-0, a half point against nothing) matches no board result.
  """
  def compare(_arbiter_result, nil), do: :none

  def compare(arbiter_result, %{result: board_result} = report) do
    arbiter = over_the_board(arbiter_result)

    cond do
      is_nil(board_result) and report.status == "waiting" and plies(report) == 0 -> :none
      is_nil(board_result) -> :live
      arbiter == :unentered -> :pending
      arbiter == board_result -> :match
      true -> :mismatch
    end
  end

  defp plies(%{plies: plies}), do: plies
  defp plies(%{moves: moves}), do: length(moves)

  defp over_the_board(code) when code in ["1-0", "1-0U", "1-0FF", "+--"], do: "1-0"
  defp over_the_board(code) when code in ["0-1", "0-1U", "0-1FF", "--+"], do: "0-1"
  defp over_the_board(code) when code in ["1/2-1/2", "1/2-1/2U"], do: "1/2-1/2"

  defp over_the_board(code) do
    if code in [nil, ""] or Results.postponed?(code), do: :unentered, else: :other
  end

  ## ---------- games of pairings that are gone ----------

  @doc """
  Removes the reported games of `tournament_id` whose `game_uid` names no
  pairing any more, and returns how many went.

  Called wherever a pairing disappears - a round unpaired, a board deleted,
  a team line-up or a team import that rewrites the boards, a restore point
  or a returning hand-off put over the tournament - by the code that made it
  disappear and inside its transaction where it has one. The box has its own
  copy and its own recording; what is removed here is this side's copy of a
  game that no page could show and no export carried.

  A game whose pairing is still there is not touched, whatever happened to
  the board's number or to the players on it: the key is the game, and a
  swap keeps it.

  One audit line with the count when something went. Never the moves: the
  trail says what was done, it is not a second place to keep the game.
  """
  @spec prune_games(integer(), term()) :: non_neg_integer()
  def prune_games(tournament_id, actor \\ nil) when is_integer(tournament_id) do
    live =
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and not is_nil(p.game_uid),
        select: p.game_uid

    {count, _} =
      Repo.delete_all(
        from g in Game,
          where: g.tournament_id == ^tournament_id and g.game_uid not in subquery(live)
      )

    if count > 0 do
      # No announcement from here: this runs inside the caller's
      # transaction, and a page that read again now would read what is
      # about to stop being true. The caller announces the change it made.
      Audit.log(tournament_id, audit_actor(actor), "boards.games_removed", %{count: count})
    end

    count
  end

  defp audit_actor(%Scope{} = scope), do: scope
  defp audit_actor(%User{id: id}), do: id
  defp audit_actor(id) when is_integer(id), do: id
  defp audit_actor(_other), do: nil

  ## ---------- export and import ----------

  @doc """
  The reported games of `tournament_id` whose pairing still exists, for the
  export envelope. Keyed by `game_uid`, which the pairings of the same
  envelope carry. No code, no relay key: a game travels with its tournament,
  a credential stays on the machine it was issued on.
  """
  def export_games(tournament_id) do
    live =
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and not is_nil(p.game_uid),
        select: p.game_uid

    Repo.all(
      from g in Game,
        where: g.tournament_id == ^tournament_id and g.game_uid in subquery(live),
        order_by: g.id
    )
    |> Enum.map(fn g ->
      %{
        "game_uid" => g.game_uid,
        "seq" => g.seq,
        "status" => g.status,
        "result" => g.result,
        "moves" => g.moves,
        "move_clocks" => g.move_clocks,
        "white_ms" => g.white_ms,
        "black_ms" => g.black_ms,
        "running" => g.running,
        "start_fen" => g.start_fen,
        "pgn" => g.pgn,
        "reconstructed" => g.reconstructed,
        "guessed" => g.guessed,
        "rewritten" => g.rewritten,
        "first_reported_at" => g.first_reported_at && DateTime.to_iso8601(g.first_reported_at),
        "reported_at" => g.reported_at && DateTime.to_iso8601(g.reported_at),
        "finished_at" => g.finished_at && DateTime.to_iso8601(g.finished_at)
      }
    end)
  end

  @doc """
  Puts an envelope's `"board_games"` on `tournament_id`. An entry that is
  not shaped like a game is skipped, and so is one this tournament already
  holds a game for: a restore point must not put an older copy of a game
  over the one the board finished since.
  """
  def import_games(tournament_id, entries) when is_list(entries) do
    held = games_by_uid(tournament_id)

    for %{"game_uid" => uid} = e <- entries,
        is_binary(uid) and byte_size(uid) in 1..64,
        not Map.has_key?(held, uid),
        {:ok, moves} <- [moves(Map.get(e, "moves", []))],
        {:ok, clocks} <- [move_clocks(nil_if_empty(e["move_clocks"]), length(moves))] do
      Repo.insert!(
        %Game{
          tournament_id: tournament_id,
          game_uid: uid,
          seq: int_or(e["seq"], 0),
          status: if(e["status"] in Game.statuses(), do: e["status"], else: "finished"),
          result: if(e["result"] in Game.results(), do: e["result"]),
          moves: moves,
          move_clocks: clocks,
          white_ms: int_or(e["white_ms"], nil),
          black_ms: int_or(e["black_ms"], nil),
          running: if(e["running"] in ~w(white black), do: e["running"]),
          start_fen: short_text(e["start_fen"], 100),
          pgn: short_text(e["pgn"], @max_pgn_bytes),
          reconstructed: int_or(e["reconstructed"], 0),
          guessed: int_or(e["guessed"], 0),
          rewritten: int_or(e["rewritten"], 0),
          first_reported_at: datetime(e["first_reported_at"]),
          reported_at: datetime(e["reported_at"]),
          finished_at: datetime(e["finished_at"])
        },
        on_conflict: :nothing
      )
    end

    :ok
  end

  def import_games(_tournament_id, _other), do: :ok

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(other), do: other

  defp int_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp int_or(_value, default), do: default

  defp short_text(value, max) when is_binary(value) and byte_size(value) <= max, do: value
  defp short_text(_value, _max), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> nil
    end
  end

  defp datetime(_value), do: nil
end
