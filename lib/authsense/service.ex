defmodule Authsense.Service do
  @moduledoc """
  Functions for working with models or changesets.
  """

  import Ecto.Changeset, only:
    [get_change: 2, put_change: 3, validate_change: 3]

  alias Ecto.Changeset

  @doc """
  Checks if someone can authenticate with a given username/password pair.

  Credentials can be given as either an Ecto changeset or a tuple.

      # Changeset:
      %User{}
      |> change(%{ email: "rico@gmail.com", password: "password" })
      |> authenticate()

      # Tuple:
      authenticate({ "rico@gmail.com", "password" })

  Returns `{:ok, user}` on success, or `{:error, changeset}` on failure. If
  used as a tuple, it returns `{:error, nil}` on failure.

  Typically used within a login action.

      def login_create(conn, %{"user" => user_params}) do
        changeset = User.changeset(%User{}, user_params)

        case authenticate(changeset) do
          {:ok, user} ->
            conn
            |> Auth.put_current_user(user)
            |> put_flash(:info, "Welcome.")
            |> redirect(to: "/")

          {:error, changeset} ->
            render(conn, "login.html", changeset: changeset)
        end
      end

  It's also possible to add opts as a second parameter, which may contain a keyword scope.
  Scope must always be a function that returns an `Ecto.Queryable`.
  This will override the model with a prepared queryable.

      %User
      |> change(%{ email: "rico@gmail.com", password: "password})
      |> authenticate([scope: (fn () -> User |> where(:extra_field, ^somevar) end)])
  """
  def authenticate(changeset_or_tuple, model) when is_atom(model), do: authenticate(changeset_or_tuple, model: model)

  def authenticate(changeset_or_tuple, opts \\ [])
  def authenticate(credentials, opts) do
    model = Keyword.get(opts, :model)
    case authenticate_user(credentials, opts) do
      false -> {:error, auth_failure(credentials, model)}
      user -> {:ok, user}
    end
  end

  @doc """
  Returns the user associated with these credentials. Returns the User record
  on success, or `false` on error.

  Accepts both `{ email, password }` tuples and `Ecto.Changeset`s.

      authenticate_user(changeset)
      authenticate_user({ email, password })
  """

  def authenticate_user(changeset_or_tuple, model) when is_atom(model), do: authenticate_user(model: model)

  def authenticate_user(changeset_or_tuple, opts \\ [])
  def authenticate_user(%Changeset{} = changeset, opts) do
    %{identity_field: id, password_field: passwd} =
      Authsense.config(Keyword.get(opts, :model))

    email = get_change(changeset, id)
    password = get_change(changeset, passwd)
    authenticate_user({email, password}, opts)
  end

  def authenticate_user({email, password}, opts) do
    %{crypto: crypto, hashed_password_field: hashed_passwd} =
      Authsense.config(Keyword.get(opts, :model))

    user = get_user(email, opts)

    if user do
      crypto.checkpw(password, Map.get(user, hashed_passwd)) && user
    else
      crypto.dummy_checkpw
    end
  end

  @doc """
  Loads a user by a given identity field value. Returns a nil on failure.

      get_user("rico@gmail.com")  #=> %User{...}
  """
  def get_user(email, opts \\ []) do
    model = Keyword.get(opts, :model)
    %{repo: repo, model: model, identity_field: id} =
      Authsense.config(Keyword.get(opts, :model))

    model = get_scope(Keyword.get(opts, :scope) || model)

    repo.get_by(model, [{id, email}])
  end

  @doc """
  Updates an `Ecto.Changeset` to generate a hashed password.

  If the changeset has `:password` in it, it will be hashed and stored as
  `:hashed_password`.  (Fields can be configured in `Authsense`.)

      changeset
      |> generate_hashed_password()

  It's typically used in a model's `changeset/2` function.

      defmodule Example.User do
        use Example.Web, :model

        def changeset(model, params \\ []) do
          model
          |> cast(params, [:email, :password, :password_confirmation])
          |> generate_hashed_password()
          |> validate_confirmation(:password, message: "password confirmation doesn't match")
          |> unique_constraint(:email)
        end
      end
  """
  def generate_hashed_password(%Changeset{} = changeset, model \\ nil) do
    %{password_field: passwd, hashed_password_field: hashed_passwd,
      crypto: crypto} = Authsense.config(model)

    case get_change(changeset, passwd) do
      nil ->
        changeset
      password ->
        changeset
        |> put_change(hashed_passwd, crypto.hashpwsalt(password))
    end
  end

  # Adds errors to a changeset.
  # Used by `authenticate/2`.
  defp auth_failure(%Changeset{} = changeset, model) do
    %{password_field: passwd, login_error: login_error} =
      Authsense.config(model)

    changeset
    |> validate_change(passwd, fn _, _ -> [{passwd, login_error}] end)
  end

  defp auth_failure(_opts, _), do: nil

  defp get_scope(scope) when is_function(scope), do: scope.()
  defp get_scope(_scope), do: nil
end
