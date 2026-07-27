defmodule MoneyTree.SimpleFin.Redaction do
  @moduledoc """
  Helpers for redacting SimpleFIN credentials before logging or returning errors.
  """

  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    value
    |> redact_url()
    |> redact_basic_auth()
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {key, redact(value)} end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value), do: value

  @spec redact_url(binary()) :: binary()
  def redact_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: userinfo} = uri
      when is_binary(scheme) and is_binary(host) and is_binary(userinfo) ->
        %URI{uri | userinfo: "[redacted]"} |> URI.to_string()

      _uri ->
        value
    end
  rescue
    _ -> value
  end

  defp redact_basic_auth(value) do
    Regex.replace(~r/(authorization:\s*basic\s+)[a-z0-9+\/=._:-]+/i, value, "\\1[redacted]")
  end
end
