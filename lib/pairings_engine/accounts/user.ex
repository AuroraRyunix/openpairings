defmodule PairingsEngine.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  # Accounts on this domain are provisioned exclusively through 02cloud SSO
  # (see `keycloak_changeset/2` and `PairingsEngine.Accounts.find_or_create_from_keycloak/1`),
  # never through self-serve registration or an email change. Keep this in
  # sync with `validate_not_sso_domain/1` below, which is the enforcement
  # point - this is just the constant it reads.
  #
  # The compiled-in default here; `blocked_registration_domain/0` below is
  # what everything else in this module actually reads, and prefers
  # `SSO_BLOCKED_REGISTRATION_DOMAIN` (config/runtime.exs) over this so a
  # second federated domain doesn't need a code change and a redeploy -
  # only a config change.
  @blocked_registration_domain "zerotwo.cloud"

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :keycloak_sub, :string
    field :role, :string, default: "owner"

    # Which optional national-federation features this account has switched
    # on - see `PairingsEngine.Features`, which owns the catalogue, the
    # changeset and the rule that these hide entrances and never change a
    # stored value. Empty is the default and means "no federation pack",
    # which is what an arbiter outside Belgium should see.
    field :features, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @roles ~w(owner support admin)

  @doc """
  The roles this application understands, least privileged first.
  """
  def roles, do: @roles

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  @doc """
  The changeset used exclusively by `Accounts.find_or_create_from_keycloak/1`
  to create or couple an account from a verified 02cloud SSO identity.

  Deliberately bypasses `email_changeset/2`'s registration-domain blocklist -
  SSO is the on-ramp that blocklist exists to redirect people to, so it must
  never reject the identity it's protecting. Also sets `confirmed_at`
  immediately: Keycloak (AD federation) already verified this identity, so
  there's no reason to route an SSO-created account through the magic-link
  confirmation flow.
  """
  def keycloak_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :keycloak_sub])
    |> validate_required([:email, :keycloak_sub])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:keycloak_sub, PairingsEngine.Repo)
    |> unique_constraint(:keycloak_sub)
    |> put_change(:confirmed_at, DateTime.utc_now(:second))
  end

  @doc """
  The account a local-mode run signs in as.

  Same shape as `keycloak_changeset/2` and for the same reason: an identity
  asserted by something outside the app, pre-confirmed because there is no
  mailbox to confirm through and nothing to confirm - being able to run the
  binary IS the credential.

  It deliberately skips `validate_not_sso_domain/1`: that blocklist stops
  someone registering an `@zerotwo.cloud` address by email when they should
  be coming through SSO, which is a rule about a hosted deployment and has
  nothing to say about a machine-local account.
  """
  def local_owner_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> put_change(:confirmed_at, DateTime.utc_now(:second))
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)
      |> validate_not_sso_domain()

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, PairingsEngine.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  @doc """
  Whether `user` authenticated through 02cloud SSO (Keycloak) rather than a
  self-serve local account - i.e. whether `keycloak_sub` is set.

  Local registration is open to anyone (any email outside `sso_domain/0`),
  so this is the only reliable way to tell "an account we actually vouch
  for" from "whoever signed up five minutes ago".

  It used to gate the privileged actions on the Data & sync page as well.
  It no longer does, and should not again: how somebody authenticated and
  what they may do are different questions, and answering the second with
  the first made every account in a federated directory an administrator.
  `role` answers the second now - see `PairingsEngine.Authz`.
  """
  def sso?(%__MODULE__{keycloak_sub: sub}), do: is_binary(sub) and sub != ""
  def sso?(_), do: false

  @doc """
  This user's role, as an atom, defaulting to `:owner`.

  Tolerant of a row carrying something unrecognised - a hand-edited
  database, or a role this version has dropped - because the alternative is
  raising inside an authorisation check, and a check that crashes is a check
  that fails open in whatever `rescue` eventually catches it. Anything this
  version does not understand is the *least* privileged role, which is the
  only safe direction to be wrong in.
  """
  def role(%__MODULE__{role: role}) when role in @roles, do: String.to_existing_atom(role)
  def role(_), do: :owner

  @doc """
  Whether `user` may change how this installation is wired up.

  Do not call this directly to authorise anything - call
  `PairingsEngine.Authz.may_administer?/1`, which also answers for a local
  installation, where there is no meaningful account to hold a role.
  """
  def admin?(user), do: role(user) == :admin

  @doc """
  Whether `user` may see the diagnostics: connection status, backup list,
  sync state, and the read-only connection check.

  True for administrators too - a role that could act but not look would be
  a strange thing to build.
  """
  def support?(user), do: role(user) in [:support, :admin]

  @doc """
  Sets a user's role.

  Reached from `mix pairings.role` and from `PairingsEngineWeb.AdminLive`.

  This once said the mix task was the only way in, on the argument that
  requiring shell access keeps the authority to grant admin from being
  something admin itself confers. **That argument is about the FIRST
  administrator and still holds** - nothing in the application can bootstrap
  one, and a hosted box has none until `ADMIN_EMAILS` or the task says so.

  It does not reach the second. An administrator granting `support` to a
  colleague gains nothing they did not have: the same session can already
  repoint where the installation publishes and download the whole database.
  The Admin page carries the guards that matter instead - you cannot change
  your own role, the last administrator cannot be demoted, and an address
  declared in the deployment's configuration is not editable from a screen
  that could not make the change stick.
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
  end

  @doc """
  The domain that is reachable **only** through 02cloud SSO.
  """
  def sso_domain, do: blocked_registration_domain()

  @doc """
  Whether `email` belongs to the SSO-only domain.

  This is the single predicate behind the whole policy, and it is deliberately
  public because the rule has to hold at more than one place: creating an
  account, changing an account's email, *and* both local login paths. See
  `PairingsEngineWeb.UserSessionController` and `PairingsEngineWeb.UserLive.Login`.
  """
  def sso_domain_email?(email) when is_binary(email) do
    case String.split(email, "@") do
      [_local, domain] -> String.downcase(String.trim(domain)) == blocked_registration_domain()
      _ -> false
    end
  end

  def sso_domain_email?(_), do: false

  @doc """
  The email domain self-serve registration/email-change is blocked on -
  `SSO_BLOCKED_REGISTRATION_DOMAIN` (config/runtime.exs) when set, otherwise
  the compiled-in default. A runtime lookup (not a module attribute) on
  purpose, so a second federated domain is a config change, not a release.
  """
  def blocked_registration_domain do
    Application.get_env(:pairings_engine, :accounts, [])[:blocked_registration_domain] ||
      @blocked_registration_domain
  end

  # `@zerotwo.cloud` accounts must come from SSO (`keycloak_changeset/2`), not
  # self-serve registration or a settings-page email change - otherwise
  # someone could register a local password-only account under an address on
  # that domain without actually controlling it there.
  #
  # This blocks *creating/changing to* such an address. Blocking local LOGIN
  # for them is enforced separately at the two login entry points, because by
  # then the account legitimately exists (SSO made it) and the changeset is
  # not involved.
  defp validate_not_sso_domain(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      if sso_domain_email?(email) do
        [
          email:
            "sign in with SSO instead of registering an @#{blocked_registration_domain()} account"
        ]
      else
        []
      end
    end)
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Pbkdf2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%PairingsEngine.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
