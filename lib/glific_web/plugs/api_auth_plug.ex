defmodule GlificWeb.APIAuthPlug do
  @moduledoc false
  use Pow.Plug.Base

  require Logger

  alias Glific.Repo
  alias GlificWeb.Endpoint

  alias Plug.Conn
  alias Pow.{Config, Store.CredentialsCache}
  alias PowPersistentSession.Store.PersistentSessionCache

  @doc """
  Fetches the user from access token.
  """
  @impl true
  @spec fetch(Conn.t(), Config.t()) :: {Conn.t(), map() | nil}
  def fetch(conn, config) do
    with {:ok, signed_token} <- fetch_access_token(conn),
         {user, metadata} <- get_credentials(conn, signed_token, config) do
      {conn, Map.put(user, :fingerprint, metadata[:fingerprint])}
    else
      _any -> {conn, nil}
    end
  end

  @doc """
  helper function that can be called from the socket token verification to
  validate the token
  """
  @spec get_credentials(Conn.t(), binary(), Config.t() | nil) :: {map(), [any()]} | nil
  def get_credentials(conn, signed_token, config) do
    with {:ok, token} <- verify_token(conn, signed_token, config),
         {user, metadata} <- CredentialsCache.get(store_config(config), token) do
      if Map.has_key?(conn.assigns, :organization_id) &&
           conn.assigns[:organization_id] != user.organization_id,
         do: nil,
         else: {Map.put(user, :fingerprint, metadata[:fingerprint]), metadata}
    else
      _any -> nil
    end
  end

  @ttl 30

  @doc """
  Creates an access and renewal token for the user.

  The tokens are added to the `conn.private` as `:api_access_token` and
  `:api_renewal_token`. The renewal token is stored in the access token
  metadata and vice versa.
  """
  @impl true
  @spec create(Conn.t(), map(), Config.t()) :: {Conn.t(), map()}
  def create(conn, user, config) do
    Logger.info("Creating tokens: user_id: '#{user.id}'")

    store_config = store_config(config)

    # 30 mins in seconds - this is the default, we wont change it
    token_expiry_time = DateTime.utc_now() |> DateTime.add(@ttl * 60, :second)
    fingerprint = conn.private[:pow_api_session_fingerprint] || Pow.UUID.generate()
    access_token = Pow.UUID.generate()
    renewal_token = Pow.UUID.generate()

    conn =
      conn
      |> Conn.put_private(:api_access_token, sign_token(conn, access_token, config))
      |> Conn.put_private(:api_renewal_token, sign_token(conn, renewal_token, config))
      |> Conn.put_private(:api_token_expiry_time, token_expiry_time)

    # Lets also preload the language object to the user, before we store
    user = user |> Repo.preload(:language)

    # The store caches will use their default `:ttl` settting. To change the
    # `:ttl`, `Keyword.put(store_config, :ttl, :timer.minutes(10))` can be
    # passed in as the first argument instead of `store_config`.
    CredentialsCache.put(
      store_config |> Keyword.put(:ttl, :timer.minutes(@ttl)),
      access_token,
      {user, fingerprint: fingerprint, renewal_token: renewal_token}
    )

    PersistentSessionCache.put(
      store_config,
      renewal_token,
      {user, [id: user.id, fingerprint: fingerprint, access_token: access_token]}
    )

    {conn, Map.put(user, :fingerprint, fingerprint)}
  end

  @doc """
  Delete the access token from the cache.

  The renewal token is deleted by fetching it from the access token metadata.
  """
  @impl true
  @spec delete(Conn.t(), Config.t()) :: Conn.t()
  def delete(conn, config) do
    store_config = store_config(config)

    with {:ok, signed_token} <- fetch_access_token(conn),
         {:ok, token} <- verify_token(conn, signed_token, config),
         {user, metadata} <- CredentialsCache.get(store_config, token) do
      Logger.info("Deleting tokens: user_id: '#{user.id}'")

      PersistentSessionCache.delete(store_config, metadata[:renewal_token])
      CredentialsCache.delete(store_config, token)

      Endpoint.broadcast("users_socket:" <> metadata[:fingerprint], "disconnect", %{})
    else
      _any -> :ok
    end

    conn
  end

  @doc """
  Creates new tokens using the renewal token.

  The access token, if any, will be deleted by fetching it from the renewal
  token metadata. The renewal token will be deleted from the store after the
  it has been fetched.

  `:pow_api_session_fingerprint` will be set in `conn.private` with the
  `:fingerprint` fetched from the metadata, to ensure it will be persisted in
  the tokens generated in `create/2`.
  """
  @spec renew(Conn.t(), Config.t()) :: {Conn.t(), map() | nil}
  def renew(conn, config) do
    store_config = store_config(config)

    with {:ok, signed_token} <- fetch_access_token(conn),
         {:ok, token} <- verify_token(conn, signed_token, config),
         {user, metadata} <- PersistentSessionCache.get(store_config, token) do
      Logger.info("Renewing token succeeded")

      CredentialsCache.delete(store_config, metadata[:access_token])
      PersistentSessionCache.delete(store_config, token)

      create(
        conn |> Conn.put_private(:pow_api_session_fingerprint, metadata[:fingerprint]),
        user,
        config
      )
    else
      _any ->
        Logger.error("Renewing token failed")
        {conn, nil}
    end
  end

  @doc """
  When we update a user record from the frontend (maybe by admin), we need to ensure
  we log this user out, so we can load the new permissioning structure for this user
  """
  @spec delete_user_sessions(map(), Conn.t() | nil) :: :ok
  def delete_user_sessions(user, conn) do
    # Delete existing user session
    Pow.Plug.fetch_config(conn)
    |> delete_all_user_sessions(user)
  end

  @doc """
  Delete all user sessions after user resets or updates the password
  """
  @spec delete_all_user_sessions(Config.t(), map()) :: :ok
  def delete_all_user_sessions(config, user) do
    store_config = store_config(config)

    CredentialsCache.sessions(store_config, user)
    |> Enum.each(fn token ->
      {_user, metadata} = CredentialsCache.get(store_config, token)
      PersistentSessionCache.delete(store_config, metadata[:renewal_token])
      CredentialsCache.delete(store_config, token)

      Endpoint.broadcast("users_socket:" <> metadata[:renewal_token], "disconnect", %{})
    end)
  end

  defp sign_token(conn, token, config) do
    Pow.Plug.sign_token(conn, signing_salt(), token, config)
  end

  defp signing_salt, do: Atom.to_string(__MODULE__)

  defp fetch_access_token(conn) do
    case Conn.get_req_header(conn, "authorization") do
      [token | _rest] ->
        {:ok, token}

      _any ->
        :error
    end
  end

  defp verify_token(conn, token, config),
    do: Pow.Plug.verify_token(conn, signing_salt(), token, config)

  defp store_config(config) do
    backend = Config.get(config, :cache_store_backend, Pow.Store.Backend.MnesiaCache)

    [backend: backend, pow_config: config]
  end
end
