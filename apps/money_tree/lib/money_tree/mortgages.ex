defmodule MoneyTree.Mortgages do
  @moduledoc """
  Mortgage Center domain APIs for mortgage and escrow profile management.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias MoneyTree.Mortgages.EscrowProfile
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  @type mortgage_result :: {:ok, Mortgage.t()} | {:error, Changeset.t() | atom()}

  @default_preload [:escrow_profile]

  @doc """
  Lists mortgages owned by the current user.
  """
  @spec list_mortgages(User.t() | binary(), keyword()) :: [Mortgage.t()]
  def list_mortgages(user, opts \\ []) do
    preload = Keyword.get(opts, :preload, @default_preload)

    Mortgage
    |> where([mortgage], mortgage.user_id == ^normalize_user_id(user))
    |> order_by([mortgage], asc: mortgage.inserted_at)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Fetches a mortgage scoped to the current user.
  """
  @spec fetch_mortgage(User.t() | binary(), binary(), keyword()) ::
          {:ok, Mortgage.t()} | {:error, :not_found}
  def fetch_mortgage(user, mortgage_id, opts \\ [])

  def fetch_mortgage(user, mortgage_id, opts) when is_binary(mortgage_id) do
    case Ecto.UUID.cast(mortgage_id) do
      {:ok, id} ->
        preload = Keyword.get(opts, :preload, @default_preload)

        Mortgage
        |> where(
          [mortgage],
          mortgage.id == ^id and mortgage.user_id == ^normalize_user_id(user)
        )
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %Mortgage{} = mortgage -> {:ok, Repo.preload(mortgage, preload)}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def fetch_mortgage(_user, _mortgage_id, _opts), do: {:error, :not_found}

  @doc """
  Returns a mortgage changeset.
  """
  @spec change_mortgage(Mortgage.t(), map()) :: Changeset.t()
  def change_mortgage(%Mortgage{} = mortgage, attrs \\ %{}) do
    Mortgage.changeset(mortgage, attrs)
  end

  @doc """
  Creates a mortgage and an optional escrow profile.
  """
  @spec create_mortgage(User.t() | binary(), map()) :: mortgage_result()
  def create_mortgage(user, attrs) when is_map(attrs) do
    attrs = normalize_attr_map(attrs)
    escrow_attrs = extract_escrow_attrs(attrs)

    Multi.new()
    |> Multi.insert(
      :mortgage,
      Mortgage.changeset(
        %Mortgage{},
        attrs
        |> Map.put("user_id", normalize_user_id(user))
        |> Map.delete("escrow_profile")
      )
    )
    |> maybe_upsert_escrow_profile(escrow_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{mortgage: mortgage}} ->
        fetch_mortgage(user, mortgage.id)

      {:error, :mortgage, %Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, :escrow_profile, %Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an existing mortgage and optional escrow profile.
  """
  @spec update_mortgage(User.t() | binary(), Mortgage.t() | binary(), map()) :: mortgage_result()
  def update_mortgage(user, %Mortgage{} = mortgage, attrs) when is_map(attrs) do
    attrs = normalize_attr_map(attrs)
    escrow_attrs = extract_escrow_attrs(attrs)

    with :ok <- authorize_mortgage(user, mortgage) do
      Multi.new()
      |> Multi.update(
        :mortgage,
        Mortgage.changeset(mortgage, Map.delete(attrs, "escrow_profile"))
      )
      |> maybe_upsert_escrow_profile(escrow_attrs)
      |> Repo.transaction()
      |> case do
        {:ok, %{mortgage: updated}} -> fetch_mortgage(user, updated.id)
        {:error, :mortgage, %Changeset{} = changeset, _changes} -> {:error, changeset}
        {:error, :escrow_profile, %Changeset{} = changeset, _changes} -> {:error, changeset}
      end
    end
  end

  def update_mortgage(user, mortgage_id, attrs)
      when is_binary(mortgage_id) and is_map(attrs) do
    with {:ok, mortgage} <- fetch_mortgage(user, mortgage_id),
         {:ok, updated} <- update_mortgage(user, mortgage, attrs) do
      {:ok, updated}
    end
  end

  @doc """
  Deletes a mortgage owned by the current user.
  """
  @spec delete_mortgage(User.t() | binary(), Mortgage.t() | binary()) ::
          {:ok, Mortgage.t()} | {:error, :not_found}
  def delete_mortgage(user, %Mortgage{} = mortgage) do
    with :ok <- authorize_mortgage(user, mortgage),
         {:ok, deleted} <- Repo.delete(mortgage) do
      {:ok, deleted}
    end
  end

  def delete_mortgage(user, mortgage_id) when is_binary(mortgage_id) do
    with {:ok, mortgage} <- fetch_mortgage(user, mortgage_id) do
      delete_mortgage(user, mortgage)
    end
  end

  defp maybe_upsert_escrow_profile(multi, nil), do: multi

  defp maybe_upsert_escrow_profile(multi, escrow_attrs) do
    Multi.run(multi, :escrow_profile, fn repo, %{mortgage: mortgage} ->
      existing = repo.get_by(EscrowProfile, mortgage_id: mortgage.id)

      attrs = Map.put(escrow_attrs, "mortgage_id", mortgage.id)

      changeset =
        case existing do
          nil -> EscrowProfile.changeset(%EscrowProfile{}, attrs)
          %EscrowProfile{} = profile -> EscrowProfile.changeset(profile, attrs)
        end

      case existing do
        nil -> repo.insert(changeset)
        _ -> repo.update(changeset)
      end
    end)
  end

  defp extract_escrow_attrs(attrs) do
    case Map.get(attrs, "escrow_profile") || Map.get(attrs, :escrow_profile) do
      %{} = escrow_attrs -> normalize_attr_map(escrow_attrs)
      _ -> nil
    end
  end

  defp authorize_mortgage(user, %Mortgage{user_id: user_id}) do
    if user_id == normalize_user_id(user), do: :ok, else: {:error, :not_found}
  end

  defp normalize_attr_map(attrs) do
    attrs
    |> Map.new()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp normalize_user_id(%User{id: user_id}), do: user_id
  defp normalize_user_id(user_id) when is_binary(user_id), do: user_id
end
