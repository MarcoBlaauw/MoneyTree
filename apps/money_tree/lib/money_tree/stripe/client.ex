defmodule MoneyTree.Stripe.Client do
  @moduledoc """
  Minimal Stripe Connect OAuth URL builder for browser-initiated linking.
  """

  @type t :: %__MODULE__{
          connect_client_id: String.t() | nil,
          connect_redirect_uri: String.t() | nil,
          authorize_host: String.t(),
          default_scope: String.t()
        }

  defstruct [:connect_client_id, :connect_redirect_uri, :authorize_host, :default_scope]

  @spec new() :: t()
  def new do
    config = Application.get_env(:money_tree, MoneyTree.Stripe, [])

    %__MODULE__{
      connect_client_id: Keyword.get(config, :connect_client_id),
      connect_redirect_uri: Keyword.get(config, :connect_redirect_uri),
      authorize_host: Keyword.get(config, :authorize_host, "https://connect.stripe.com"),
      default_scope: Keyword.get(config, :connect_scope, "read_write")
    }
  end

  @spec create_connect_session(map()) ::
          {:ok, %{url: String.t(), state: String.t()}} | {:error, :not_configured}
  def create_connect_session(params \\ %{}) when is_map(params) do
    client = new()

    if configured?(client) do
      state = build_state()

      scope =
        normalize_scope(Map.get(params, "scope") || Map.get(params, :scope), client.default_scope)

      query =
        %{
          response_type: "code",
          client_id: client.connect_client_id,
          scope: scope,
          state: state
        }
        |> maybe_put(:redirect_uri, client.connect_redirect_uri)
        |> URI.encode_query()

      {:ok,
       %{
         url: "#{String.trim_trailing(client.authorize_host, "/")}/oauth/authorize?#{query}",
         state: state
       }}
    else
      {:error, :not_configured}
    end
  end

  defp configured?(%__MODULE__{connect_client_id: client_id, connect_redirect_uri: redirect_uri}) do
    present?(client_id) and present?(redirect_uri)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp normalize_scope(value, default_scope) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: default_scope, else: trimmed
  end

  defp normalize_scope(_value, default_scope), do: default_scope

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_state do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
