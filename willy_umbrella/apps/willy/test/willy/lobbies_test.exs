defmodule Willy.LobbiesTest do
  use ExUnit.Case, async: true

  alias Willy.GameServer
  alias Willy.Lobbies

  test "create_lobby starts a joinable game process" do
    {:ok, code} = Lobbies.create_lobby()
    on_exit(fn -> stop_lobby(code) end)

    assert code =~ ~r/^[A-HJ-NP-Z2-9]{4}$/
    assert Lobbies.exists?(code)
    assert is_pid(Lobbies.whereis(code))
    assert {:ok, :host} = GameServer.join_game(code, "h", "Host", :host)
  end

  test "codes are unique per lobby" do
    {:ok, code_a} = Lobbies.create_lobby()
    {:ok, code_b} = Lobbies.create_lobby()
    on_exit(fn -> Enum.each([code_a, code_b], &stop_lobby/1) end)

    assert code_a != code_b
    assert Lobbies.whereis(code_a) != Lobbies.whereis(code_b)
  end

  test "unknown codes do not exist" do
    refute Lobbies.exists?("XXXX")
    assert Lobbies.whereis("XXXX") == nil
  end

  test "normalize_code trims and upcases" do
    assert Lobbies.normalize_code("  abcd \n") == "ABCD"
  end

  defp stop_lobby(code) do
    case Lobbies.whereis(code) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Willy.GameSupervisor, pid)
    end
  end
end
