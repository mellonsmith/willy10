defmodule Willy.Lobbies do
  @moduledoc """
  Creates and looks up game lobbies. Wraps `Willy.GameRegistry` and
  `Willy.GameSupervisor` so the web layer only ever deals with lobby codes.
  """

  alias Willy.GameServer

  # No 0/O, 1/I/L to keep codes easy to read out loud
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @code_length 4
  @max_lobbies 200

  @spec create_lobby() :: {:ok, String.t()} | {:error, :too_many_lobbies}
  def create_lobby do
    if count() >= @max_lobbies do
      {:error, :too_many_lobbies}
    else
      start_with_unique_code(10)
    end
  end

  def exists?(code), do: whereis(code) != nil

  @spec whereis(String.t()) :: pid() | nil
  def whereis(code) do
    case Registry.lookup(Willy.GameRegistry, code) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  def count, do: Registry.count(Willy.GameRegistry)

  # Codes are case-insensitive; canonical form is upcased
  def normalize_code(code) when is_binary(code) do
    code |> String.trim() |> String.upcase()
  end

  defp start_with_unique_code(retries_left) do
    code = generate_code()

    case DynamicSupervisor.start_child(Willy.GameSupervisor, {GameServer, code}) do
      {:ok, _pid} ->
        {:ok, code}

      {:error, {:already_started, _pid}} when retries_left > 0 ->
        start_with_unique_code(retries_left - 1)
    end
  end

  defp generate_code do
    for _ <- 1..@code_length, into: "", do: <<Enum.random(@code_alphabet)>>
  end
end
