defmodule WillyWeb.LobbyLive do
  use WillyWeb, :live_view

  alias Willy.GameServer
  alias Willy.Lobbies

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Willy 10")}
  end

  # Create a lobby and join its creator as host. Navigation to /g/CODE only
  # happens after the LobbySession hook confirms the session was written to
  # localStorage ("session_stored"), so the game view can restore it on mount.
  def handle_event("create_lobby", %{"nickname" => nickname}, socket) do
    nickname = String.trim(nickname)

    cond do
      nickname == "" ->
        {:noreply, put_flash(socket, :error, "Please enter a nickname.")}

      true ->
        case Lobbies.create_lobby() do
          {:ok, code} ->
            player_id = GameServer.generate_player_id()
            {:ok, :host} = GameServer.join_game(code, player_id, nickname, :host)

            {:noreply,
             push_event(socket, "store_session", %{
               code: code,
               player_id: player_id,
               nickname: nickname,
               role: "host"
             })}

          {:error, :too_many_lobbies} ->
            {:noreply,
             put_flash(socket, :error, "Too many lobbies right now. Please try again later.")}
        end
    end
  end

  def handle_event("session_stored", %{"code" => code}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/g/#{code}")}
  end

  def handle_event("join_lobby", %{"code" => code}, socket) do
    code = Lobbies.normalize_code(code)

    if Lobbies.exists?(code) do
      {:noreply, push_navigate(socket, to: ~p"/g/#{code}")}
    else
      {:noreply, put_flash(socket, :error, "No lobby found with code #{code}.")}
    end
  end
end
