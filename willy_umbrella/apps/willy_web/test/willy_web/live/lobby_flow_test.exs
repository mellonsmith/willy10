defmodule WillyWeb.LobbyFlowTest do
  use WillyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Willy.GameServer
  alias Willy.Lobbies

  defp create_lobby_with_host do
    {:ok, code} = Lobbies.create_lobby()
    host_id = GameServer.generate_player_id()
    {:ok, :host} = GameServer.join_game(code, host_id, "Hosty", :host)

    on_exit(fn ->
      case Lobbies.whereis(code) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Willy.GameSupervisor, pid)
      end
    end)

    {code, host_id}
  end

  test "landing page offers creating and joining a lobby", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Create a Lobby"
    assert html =~ "Join with a Code"
  end

  test "joining an unknown code shows an error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=join_lobby]")
    |> render_submit(%{"code" => "xxxx"})

    assert render(view) =~ "No lobby found with code XXXX"
  end

  test "a known code navigates to the game", %{conn: conn} do
    {code, _host_id} = create_lobby_with_host()
    {:ok, view, _html} = live(conn, ~p"/")

    result =
      view
      |> form("form[phx-submit=join_lobby]")
      |> render_submit(%{"code" => String.downcase(code)})

    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/g/#{code}"
  end

  test "an unknown lobby code redirects back to the landing page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/g/XXXX")
  end

  test "a player joins with a nickname and appears in the lobby", %{conn: conn} do
    {code, _host_id} = create_lobby_with_host()
    {:ok, view, html} = live(conn, ~p"/g/#{code}")

    assert html =~ "Lobby #{code}"
    # No free host slot: only the player join button is offered
    refute html =~ "Join as Host"

    view
    |> form("form[phx-submit=join_game]")
    |> render_submit(%{"nickname" => "Anna", "as" => "player"})

    assert render(view) =~ "Anna"
    assert map_size(GameServer.get_state(code).players) == 2
  end

  test "joining without a nickname is rejected", %{conn: conn} do
    {code, _host_id} = create_lobby_with_host()
    {:ok, view, _html} = live(conn, ~p"/g/#{code}")

    view
    |> form("form[phx-submit=join_game]")
    |> render_submit(%{"nickname" => "   ", "as" => "player"})

    assert render(view) =~ "Please pick a nickname first."
    assert map_size(GameServer.get_state(code).players) == 1
  end

  test "submitting the join form with Enter (no button value) joins as player", %{conn: conn} do
    {code, _host_id} = create_lobby_with_host()
    {:ok, view, _html} = live(conn, ~p"/g/#{code}")

    view
    |> form("form[phx-submit=join_game]")
    |> render_submit(%{"nickname" => "Bob"})

    state = GameServer.get_state(code)
    assert Enum.any?(state.players, fn {id, info} -> info.name == "Bob" and id != state.host_id end)
  end

  test "creating a lobby joins the creator as host and stores the session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=create_lobby]")
    |> render_submit(%{"nickname" => "Mellon"})

    # The LiveView asks the client to store the session before navigating
    assert_push_event(view, "store_session", %{code: code, nickname: "Mellon", role: "host"})

    state = GameServer.get_state(code)
    assert map_size(state.players) == 1
    assert state.players[state.host_id].name == "Mellon"

    # The client confirms storage, then navigation happens
    assert {:error, {:live_redirect, %{to: to}}} =
             render_hook(view, "session_stored", %{"code" => code})

    assert to == "/g/#{code}"

    case Lobbies.whereis(code) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Willy.GameSupervisor, pid)
    end
  end
end
