defmodule PairingsEngine.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias PairingsEngine.Repo

  alias PairingsEngine.Accounts.{User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by their 02cloud SSO (Keycloak) subject id.

  ## Examples

      iex> get_user_by_keycloak_sub("3fe2b6a0-...")
      %User{}

      iex> get_user_by_keycloak_sub("unknown")
      nil

  """
  def get_user_by_keycloak_sub(sub) when is_binary(sub) do
    Repo.get_by(User, keycloak_sub: sub)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## 02cloud SSO

  @doc """
  Finds or creates the local account for a verified 02cloud SSO identity -
  the counterpart to the registration-domain blocklist in
  `PairingsEngine.Accounts.User`: this is the *only* path that's allowed to
  create (or attach SSO to) an `@zerotwo.cloud` account, and it's also open
  to any other domain's SSO identity, per the same "SSO always gets in"
  policy.

  `attrs` is `%{sub: sub, email: email}` (`sub` and `email` from Keycloak's
  userinfo response - see `PairingsEngineWeb.KeycloakAuthController`).

  Resolution order, matching how a person's SSO identity can legitimately
  relate to an existing local account:

  1. **By `keycloak_sub`** - a return visit from someone already coupled.
     This is checked first and is the only stable key: Keycloak's `sub` never
     changes, unlike the email below, which can be renamed on either side.
  2. **By `email`** - a pre-existing password/magic-link account whose email
     matches this SSO identity gets *coupled* (its `keycloak_sub` is set) -
     "auto create a coupled account" for someone who already had one, rather
     than producing a confusing second account with the same email.
  3. **Neither** - a brand-new account is created, pre-confirmed (see
     `User.keycloak_changeset/2` for why).

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def find_or_create_from_keycloak(%{sub: sub, email: email})
      when is_binary(sub) and is_binary(email) do
    case get_user_by_keycloak_sub(sub) do
      %User{} = user ->
        {:ok, user}

      nil ->
        Repo.transact(fn ->
          user = get_user_by_email(email) || %User{}

          user
          |> User.keycloak_changeset(%{email: email, keycloak_sub: sub})
          |> Repo.insert_or_update()
        end)
    end
  end

  ## Local mode

  @doc """
  The single account a local-mode run uses, created on first sign-in.

  Local mode is one person on their own machine (see
  `PairingsEngineWeb.UserAuth.local_owner_session/2`), so there is nothing
  for an account system to decide: whoever can run the binary is the owner.
  The row still exists because everything downstream - tournament ownership,
  the audit trail, collaborator invitations - is keyed on a user, and giving
  local mode a real account is far less invasive than teaching all of that
  about a user that is not there.

  Named after the machine, so exports and audit entries say something
  truthful about where they came from rather than "local@localhost".
  Resolved by email, so restarting the binary returns the same account and
  the same tournaments.
  """
  def local_owner! do
    email = local_owner_email()

    case get_user_by_email(email) do
      %User{} = user ->
        user

      nil ->
        %User{}
        |> User.local_owner_changeset(%{email: email})
        |> Repo.insert!()
    end
  end

  @doc """
  The address `local_owner!/0` uses: the OS user at this machine's hostname.

  `.local` is reserved for exactly this (RFC 6762) - it cannot resolve on
  the public internet, so an address built from it can never collide with a
  real one, and a tournament file exported from a local install carries an
  arbiter address that is visibly machine-local rather than plausibly real.
  """
  def local_owner_email do
    user =
      System.get_env("USER") || System.get_env("USERNAME") || "arbiter"

    host =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> "localhost"
      end

    "#{sanitize_local_part(user)}@#{sanitize_local_part(host)}.local"
  end

  # Usernames and hostnames can carry spaces, accents and the @ the email
  # format check forbids ("Ann O'Brien" is a perfectly ordinary Windows
  # account name). Reduced to something an address can hold, never empty.
  defp sanitize_local_part(value) do
    cleaned =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 64)

    if cleaned == "", do: "arbiter", else: cleaned
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `PairingsEngine.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `PairingsEngine.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
