defmodule MoneyTree.AI.Providers.Ollama do
  @moduledoc """
  Ollama provider adapter for local JSON generation.
  """

  @behaviour MoneyTree.AI.Provider

  @default_timeout_ms 60_000

  @impl MoneyTree.AI.Provider
  def health_check(settings) when is_map(settings) do
    with {:ok, _response} <- get(settings, "/api/tags") do
      {:ok, %{status: "ok"}}
    end
  end

  @impl MoneyTree.AI.Provider
  def list_models(settings) when is_map(settings) do
    with {:ok, body} <- get(settings, "/api/tags") do
      models =
        body
        |> Map.get("models", [])
        |> Enum.flat_map(fn model ->
          case model do
            %{"name" => name} when is_binary(name) -> [name]
            _ -> []
          end
        end)

      {:ok, models}
    end
  end

  @impl MoneyTree.AI.Provider
  def generate_json(settings, prompt, _opts \\ [])
      when is_map(settings) and is_binary(prompt) do
    model = Map.get(settings, :model) || Map.get(settings, "model")

    with true <- is_binary(model) and model != "",
         {:ok, body} <-
           post(settings, "/api/generate", %{
             model: model,
             prompt: prompt,
             stream: false,
             format: "json"
           }),
         {:ok, parsed} <- parse_json_response(body) do
      {:ok, parsed}
    else
      false -> {:error, :missing_model}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_json_response(%{"response" => response}) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_json_shape}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp parse_json_response(_body), do: {:error, :invalid_response}

  defp get(settings, path) do
    request = request(settings)

    case Req.get(request, url: path) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport_error, error.reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(settings, path, payload) do
    request = request(settings)

    case Req.post(request, url: path, json: payload) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport_error, error.reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(settings) do
    timeout_ms =
      Map.get(settings, :timeout_ms) ||
        Map.get(settings, "timeout_ms") ||
        @default_timeout_ms

    Req.new(
      base_url: Map.get(settings, :base_url) || Map.get(settings, "base_url"),
      receive_timeout: timeout_ms
    )
  end

  defp normalize_body(%{} = body), do: body
  defp normalize_body(_), do: %{}
end
