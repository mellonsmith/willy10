defmodule Willy.GameServerTest do
  # Every test gets its own lobby process, so they can run concurrently
  use ExUnit.Case, async: true

  alias Willy.GameServer

  setup do
    code = "T#{System.unique_integer([:positive])}"
    start_supervised!({GameServer, code})
    {:ok, code: code}
  end

  # Casts are async; a call afterwards guarantees they have been processed
  defp state(code), do: GameServer.get_state(code)

  defp join_host_and_players(code, player_count) do
    {:ok, :host} = GameServer.join_game(code, "host", "Hostname", :host)

    player_ids = for i <- 1..player_count, do: "p#{i}"

    for id <- player_ids,
        do: {:ok, :player} = GameServer.join_game(code, id, "Player #{id}", :player)

    {"host", player_ids}
  end

  defp start_game_with_players(code, player_count) do
    {host, players} = join_host_and_players(code, player_count)
    GameServer.start_game(code, host)
    {host, players, state(code)}
  end

  defp active_player(s) do
    {id, _info} = Enum.find(s.players, fn {_id, info} -> info.state == :active_player end)
    id
  end

  defp points(s, id), do: s.players[id].points

  defp play_full_round(code, host) do
    GameServer.next_phase(code, host)
    GameServer.next_phase(code, host)
    GameServer.next_phase(code, host)
  end

  describe "joining" do
    test "first host join succeeds, second is rejected", %{code: code} do
      assert {:ok, :host} = GameServer.join_game(code, "h1", "A", :host)
      assert {:error, :host_exists} = GameServer.join_game(code, "h2", "B", :host)
    end

    test "game is full at max players", %{code: code} do
      {_host, _players} = join_host_and_players(code, 6)
      assert {:error, :game_full} = GameServer.join_game(code, "late", "Late", :player)
    end

    test "blank names are rejected", %{code: code} do
      assert {:error, :invalid_name} = GameServer.join_game(code, "h1", "", :host)
      assert {:error, :invalid_name} = GameServer.join_game(code, "p1", "   ", :player)
      assert state(code).players == %{}
    end

    test "names are trimmed on join", %{code: code} do
      assert {:ok, :player} = GameServer.join_game(code, "p1", "  Anna  ", :player)
      assert state(code).players["p1"].name == "Anna"
    end

    test "rejoining with the same id keeps the existing role", %{code: code} do
      {host, [p1 | _]} = join_host_and_players(code, 3)
      assert {:ok, :host} = GameServer.join_game(code, host, "Hostname", :player)
      assert {:ok, :player} = GameServer.join_game(code, p1, "Player p1", :player)
    end

    test "lobbies are independent from each other", %{code: code} do
      other = "T#{System.unique_integer([:positive])}"
      start_supervised!({GameServer, other}, id: :other_lobby)

      {:ok, :host} = GameServer.join_game(code, "h1", "A", :host)
      assert {:ok, :host} = GameServer.join_game(other, "h2", "B", :host)
      assert map_size(state(code).players) == 1
      assert state(code).host_id == "h1"
      assert state(other).host_id == "h2"
    end
  end

  describe "starting a game" do
    test "only the host can start", %{code: code} do
      {_host, [p1 | _]} = join_host_and_players(code, 3)
      GameServer.start_game(code, p1)
      assert state(code).game_status == :waiting
    end

    test "start sets an active player and excludes the host from rounds", %{code: code} do
      {host, players, s} = start_game_with_players(code, 3)
      assert s.game_status == :in_progress
      assert s.current_round == 1
      assert s.current_phase == :choose
      assert host not in s.round_order
      assert Enum.sort(s.round_order) == Enum.sort(players)
      assert active_player(s) in players
      assert s.players[host].state == :passive_player
    end
  end

  describe "rounds per player" do
    test "only the host can change it and only in the lobby", %{code: code} do
      {host, [p1 | _]} = join_host_and_players(code, 3)

      GameServer.set_rounds_per_player(code, p1, 2)
      assert state(code).rounds_per_player == 1

      GameServer.set_rounds_per_player(code, host, 2)
      assert state(code).rounds_per_player == 2

      GameServer.set_rounds_per_player(code, host, 99)
      assert state(code).rounds_per_player == 2

      GameServer.start_game(code, host)
      GameServer.set_rounds_per_player(code, host, 3)
      assert state(code).rounds_per_player == 2
    end

    test "with 2 rounds per player everyone is active twice", %{code: code} do
      {host, players} = join_host_and_players(code, 3)
      GameServer.set_rounds_per_player(code, host, 2)
      GameServer.start_game(code, host)

      s = state(code)
      assert length(s.round_order) == 6
      assert Enum.frequencies(s.round_order) == Map.new(players, &{&1, 2})

      for _round <- 1..6, do: play_full_round(code, host)

      s = state(code)
      assert s.game_status == :finished
      assert s.current_round == 6
      assert Enum.frequencies(s.rounds_completed) == Map.new(players, &{&1, 2})
    end

    test "the active player never guesses even with repeated rounds", %{code: code} do
      {host, _players} = join_host_and_players(code, 3)
      GameServer.set_rounds_per_player(code, host, 2)
      GameServer.start_game(code, host)

      for _round <- 1..6 do
        active = active_player(state(code))
        GameServer.next_phase(code, host)
        s = state(code)
        assert active not in s.guessing_order
        assert length(Enum.uniq(s.guessing_order)) == length(s.guessing_order)
        GameServer.next_phase(code, host)
        GameServer.next_phase(code, host)
      end
    end
  end

  describe "guess words" do
    test "host and active player can add words in choose phase, others cannot", %{code: code} do
      {host, players, s} = start_game_with_players(code, 3)
      active = active_player(s)
      passive = Enum.find(players, &(&1 != active))

      GameServer.add_guess_word(code, host, "apple")
      GameServer.add_guess_word(code, active, "banana")
      GameServer.add_guess_word(code, passive, "cherry")

      assert state(code).guess_words == ["apple", "banana"]
    end

    test "duplicates are rejected and words are capped", %{code: code} do
      {host, _players, _s} = start_game_with_players(code, 3)

      GameServer.add_guess_word(code, host, "apple")
      GameServer.add_guess_word(code, host, "apple")
      assert state(code).guess_words == ["apple"]

      for i <- 1..15, do: GameServer.add_guess_word(code, host, "word#{i}")
      assert length(state(code).guess_words) == GameServer.max_guess_words()
    end

    test "main word can only be set by the host in choose phase", %{code: code} do
      {host, [p1 | _], _s} = start_game_with_players(code, 3)
      GameServer.update_main_word(code, p1, "hacked")
      GameServer.update_main_word(code, host, "fruit")
      assert state(code).main_word == "fruit"
    end
  end

  describe "phase transitions" do
    test "choose -> guessing sets up guessers without host and active player", %{code: code} do
      {host, _players, s} = start_game_with_players(code, 3)
      active = active_player(s)

      GameServer.next_phase(code, host)
      s = state(code)

      assert s.current_phase == :guessing
      assert host not in s.guessing_order
      assert active not in s.guessing_order
      assert s.current_guessing_player in s.guessing_order
    end

    test "advancing past the last guesser moves to revealing", %{code: code} do
      {host, _players, _s} = start_game_with_players(code, 3)
      GameServer.next_phase(code, host)

      # 2 guessers (3 players minus active) -> two advances end the phase
      GameServer.next_guessing_player(code, host)
      GameServer.next_guessing_player(code, host)

      assert state(code).current_phase == :revealing
    end

    test "game finishes after every player had an active round", %{code: code} do
      {host, _players, _s} = start_game_with_players(code, 3)

      for _round <- 1..3, do: play_full_round(code, host)

      s = state(code)
      assert s.game_status == :finished
      assert length(s.rankings) == 4
    end

    test "non-host cannot advance phases", %{code: code} do
      {_host, [p1 | _], _s} = start_game_with_players(code, 3)
      GameServer.next_phase(code, p1)
      assert state(code).current_phase == :choose
    end
  end

  describe "marking found words" do
    setup %{code: code} do
      {host, players, s} = start_game_with_players(code, 3)
      GameServer.add_guess_word(code, host, "apple")
      GameServer.add_guess_word(code, host, "banana")
      GameServer.next_phase(code, host)
      {:ok, host: host, players: players, active: active_player(s)}
    end

    test "host and active player mark for the current guesser", %{
      code: code,
      host: host,
      active: active
    } do
      guesser = state(code).current_guessing_player

      GameServer.toggle_found_word(code, host, 0)
      GameServer.toggle_found_word(code, active, 1)

      s = state(code)
      assert Enum.sort(Map.get(s.found_words, guesser)) == [0, 1]
      assert s.word_guesses[0] == [guesser]
      assert s.word_guesses[1] == [guesser]
    end

    test "toggling twice unmarks the word", %{code: code, host: host} do
      guesser = state(code).current_guessing_player
      GameServer.toggle_found_word(code, host, 0)
      GameServer.toggle_found_word(code, host, 0)

      s = state(code)
      assert Map.get(s.found_words, guesser) == []
      assert s.word_guesses[0] == []
    end

    test "a passive guesser cannot mark words themselves", %{
      code: code,
      players: players,
      active: active
    } do
      passive = Enum.find(players, &(&1 != active))
      GameServer.toggle_found_word(code, passive, 0)
      assert state(code).found_words == %{}
    end
  end

  describe "scoring" do
    # Sets up a round with two guessers who found a known number of words,
    # then returns to the revealing phase ready for reveals.
    setup %{code: code} do
      {host, players, s} = start_game_with_players(code, 3)
      active = active_player(s)
      GameServer.add_guess_word(code, host, "apple")
      GameServer.add_guess_word(code, host, "banana")
      GameServer.add_guess_word(code, host, "cherry")
      GameServer.next_phase(code, host)

      s = state(code)
      first_guesser = s.current_guessing_player
      # First guesser finds words 0 and 1
      GameServer.toggle_found_word(code, host, 0)
      GameServer.toggle_found_word(code, host, 1)
      GameServer.next_guessing_player(code, host)

      second_guesser = state(code).current_guessing_player
      # Second guesser finds word 0
      GameServer.toggle_found_word(code, host, 0)
      GameServer.next_guessing_player(code, host)

      assert state(code).current_phase == :revealing

      {:ok,
       host: host,
       players: players,
       active: active,
       first_guesser: first_guesser,
       second_guesser: second_guesser}
    end

    test "guessers get one point per revealed found word", ctx do
      GameServer.reveal_word(ctx.code, ctx.host, 0)
      s = state(ctx.code)
      assert points(s, ctx.first_guesser) == 1
      assert points(s, ctx.second_guesser) == 1

      GameServer.reveal_word(ctx.code, ctx.host, 1)
      s = state(ctx.code)
      assert points(s, ctx.first_guesser) == 2
      assert points(s, ctx.second_guesser) == 1
    end

    test "active player scores like the best guesser, but only after the last reveal", ctx do
      GameServer.reveal_word(ctx.code, ctx.host, 0)
      assert points(state(ctx.code), ctx.active) == 0

      GameServer.reveal_word(ctx.code, ctx.host, 1)
      s = state(ctx.code)
      # Guessers score per card, the active player not yet
      assert points(s, ctx.first_guesser) == 2
      assert points(s, ctx.active) == 0

      # Revealing the last card awards the active player the best guesser's total
      GameServer.reveal_word(ctx.code, ctx.host, 2)
      assert points(state(ctx.code), ctx.active) == 2
    end

    test "revealing the same word twice does not award points twice", ctx do
      GameServer.reveal_word(ctx.code, ctx.host, 0)
      GameServer.reveal_word(ctx.code, ctx.host, 0)

      s = state(ctx.code)
      assert points(s, ctx.first_guesser) == 1
      assert points(s, ctx.second_guesser) == 1
      # Not all cards are revealed yet, so the active player has nothing
      assert points(s, ctx.active) == 0
    end

    test "reveal_all after single reveals does not double-award", ctx do
      GameServer.reveal_word(ctx.code, ctx.host, 0)
      GameServer.reveal_all_words(ctx.code, ctx.host)

      s = state(ctx.code)
      assert points(s, ctx.first_guesser) == 2
      assert points(s, ctx.second_guesser) == 1
      assert points(s, ctx.active) == 2
      assert MapSet.size(s.revealed_words) == 3
    end

    test "only the host can reveal", ctx do
      GameServer.reveal_word(ctx.code, ctx.first_guesser, 0)
      GameServer.reveal_all_words(ctx.code, ctx.first_guesser)

      s = state(ctx.code)
      assert s.revealed_words == MapSet.new()
      assert points(s, ctx.first_guesser) == 0
    end

    test "going back from revealing reverts all points from this round", ctx do
      GameServer.reveal_all_words(ctx.code, ctx.host)
      assert points(state(ctx.code), ctx.first_guesser) == 2

      GameServer.previous_phase(ctx.code, ctx.host)

      s = state(ctx.code)
      assert s.current_phase == :guessing
      assert points(s, ctx.first_guesser) == 0
      assert points(s, ctx.second_guesser) == 0
      assert points(s, ctx.active) == 0
      assert s.round_points == %{}
    end

    test "manual corrections are not reverted by previous_phase", ctx do
      GameServer.reveal_all_words(ctx.code, ctx.host)
      GameServer.adjust_points(ctx.code, ctx.host, ctx.first_guesser, 5)
      assert points(state(ctx.code), ctx.first_guesser) == 7

      GameServer.previous_phase(ctx.code, ctx.host)
      assert points(state(ctx.code), ctx.first_guesser) == 5
    end
  end

  describe "manual point adjustments" do
    test "only the host can adjust and points never go negative", %{code: code} do
      {host, [p1 | _]} = join_host_and_players(code, 3)

      GameServer.adjust_points(code, p1, p1, 10)
      assert points(state(code), p1) == 0

      GameServer.adjust_points(code, host, p1, 3)
      assert points(state(code), p1) == 3

      GameServer.adjust_points(code, host, p1, -5)
      assert points(state(code), p1) == 0
    end

    test "adjusting after the game recalculates the rankings", %{code: code} do
      {host, [p1 | _], _s} = start_game_with_players(code, 3)
      for _round <- 1..3, do: play_full_round(code, host)
      assert state(code).game_status == :finished

      GameServer.adjust_points(code, host, p1, 10)
      assert [{^p1, 10} | _] = state(code).rankings
    end
  end

  describe "timer" do
    setup %{code: code} do
      {host, _players, _s} = start_game_with_players(code, 3)
      GameServer.next_phase(code, host)
      {:ok, host: host}
    end

    test "start, pause and resume", %{code: code, host: host} do
      GameServer.start_timer(code, host)
      s = state(code)
      assert s.timer_state == :running
      assert s.timer_remaining == s.timer_duration

      GameServer.pause_timer(code, host)
      s = state(code)
      assert s.timer_state == :paused
      assert s.timer_started_at == nil
      assert s.timer_remaining <= s.timer_duration

      GameServer.start_timer(code, host)
      assert state(code).timer_state == :running
    end

    test "reset stops the timer and restores the full duration", %{code: code, host: host} do
      GameServer.start_timer(code, host)
      GameServer.reset_timer(code, host)

      s = state(code)
      assert s.timer_state == :stopped
      assert s.timer_remaining == s.timer_duration
    end

    test "the timer expires on its own", %{code: code, host: host} do
      GameServer.update_timer_duration(code, host, 1)
      GameServer.start_timer(code, host)
      assert state(code).timer_state == :running

      Process.sleep(1100)

      s = state(code)
      assert s.timer_state == :stopped
      assert s.timer_remaining == 0
    end

    test "only the host controls the timer", %{code: code} do
      GameServer.start_timer(code, "p1")
      assert state(code).timer_state == :stopped
    end

    test "changing guesser stops a running timer", %{code: code, host: host} do
      GameServer.start_timer(code, host)
      GameServer.next_guessing_player(code, host)
      assert state(code).timer_state == :stopped
    end
  end

  describe "connection handling" do
    test "disconnect and reconnect flip the connected flag", %{code: code} do
      {_host, [p1 | _]} = join_host_and_players(code, 3)

      GameServer.disconnect_player(code, p1)
      assert state(code).players[p1].connected == false

      GameServer.reconnect_player(code, p1)
      assert state(code).players[p1].connected == true
    end
  end

  describe "kicking players" do
    test "only the host can kick, and the host cannot kick themselves", %{code: code} do
      {host, [p1, p2 | _]} = join_host_and_players(code, 3)

      GameServer.remove_player(code, p1, p2)
      assert Map.has_key?(state(code).players, p2)

      GameServer.remove_player(code, host, host)
      assert Map.has_key?(state(code).players, host)

      GameServer.remove_player(code, host, p2)
      refute Map.has_key?(state(code).players, p2)
    end

    test "kicking broadcasts a player_kicked message", %{code: code} do
      {host, [p1 | _]} = join_host_and_players(code, 3)
      Phoenix.PubSub.subscribe(Willy.PubSub, GameServer.topic(code))

      GameServer.remove_player(code, host, p1)
      assert_receive {:player_kicked, ^p1}
    end

    test "kicking a player mid-game removes them from the rotation", %{code: code} do
      {host, players, s} = start_game_with_players(code, 3)
      active = active_player(s)
      victim = Enum.find(players, &(&1 != active))

      GameServer.remove_player(code, host, victim)

      s = state(code)
      refute Map.has_key?(s.players, victim)
      refute victim in s.round_order
      assert s.game_status == :in_progress
    end

    test "kicking the current guesser advances to the next one", %{code: code} do
      {host, _players, _s} = start_game_with_players(code, 3)
      GameServer.next_phase(code, host)

      guesser = state(code).current_guessing_player
      GameServer.remove_player(code, host, guesser)

      s = state(code)
      assert s.current_guessing_player != guesser
      refute guesser in s.guessing_order
      # 2 guessers originally, one kicked -> one remains
      assert s.current_phase == :guessing
    end

    test "kicking the active player ends the round", %{code: code} do
      {host, _players, s} = start_game_with_players(code, 3)
      active = active_player(s)

      GameServer.remove_player(code, host, active)

      s = state(code)
      refute Map.has_key?(s.players, active)
      assert s.current_round == 2
      assert s.current_phase == :choose
      assert active_player(s) != active
    end
  end

  describe "lobby lifecycle" do
    test "host leaving closes the lobby", %{code: code} do
      {host, _players} = join_host_and_players(code, 3)
      pid = GenServer.whereis({:via, Registry, {Willy.GameRegistry, code}})
      ref = Process.monitor(pid)
      Phoenix.PubSub.subscribe(Willy.PubSub, GameServer.topic(code))

      GameServer.leave_game(code, host)

      assert_receive :lobby_closed
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "end_session closes the lobby, but only for the host", %{code: code} do
      {host, [p1 | _]} = join_host_and_players(code, 3)
      pid = GenServer.whereis({:via, Registry, {Willy.GameRegistry, code}})
      ref = Process.monitor(pid)

      GameServer.end_session(code, p1)
      assert map_size(state(code).players) == 4

      GameServer.end_session(code, host)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "a non-host player leaving is only marked disconnected", %{code: code} do
      {_host, [p1 | _]} = join_host_and_players(code, 3)
      GameServer.leave_game(code, p1)

      s = state(code)
      assert Map.has_key?(s.players, p1)
      assert s.players[p1].connected == false
    end
  end

  describe "session lifecycle" do
    test "start_new_game keeps players, host and settings but resets points", %{code: code} do
      {host, _players} = join_host_and_players(code, 3)
      GameServer.set_rounds_per_player(code, host, 2)
      GameServer.start_game(code, host)
      s = state(code)
      active = active_player(s)
      GameServer.add_guess_word(code, host, "apple")
      GameServer.next_phase(code, host)
      GameServer.toggle_found_word(code, host, 0)
      GameServer.next_phase(code, host)
      GameServer.reveal_all_words(code, host)
      assert points(state(code), active) > 0

      GameServer.start_new_game(code, host)

      s = state(code)
      assert s.game_status == :waiting
      assert s.host_id == host
      assert s.rounds_per_player == 2
      assert map_size(s.players) == 4

      assert Enum.all?(s.players, fn {_id, info} ->
               info.points == 0 and info.state == :waiting
             end)
    end
  end
end
