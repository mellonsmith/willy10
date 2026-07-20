# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"Willy 10" is a real-time multiplayer word-association party game built with Phoenix
LiveView. Players gather in **lobbies** identified by a 4-letter code. One player creates a
lobby and is its **host**, an **active player** picks a secret main word plus up to 10
associated guess words, and the remaining players take turns trying to find those words.
Points are awarded during a reveal phase. The whole game runs in the browser over a
LiveView WebSocket — there is no separate client.

## Working directory

The mix project lives in `willy_umbrella/`, not the repo root. Run all `mix` commands from
there:

```bash
cd willy_umbrella
```

## Commands

```bash
mix setup                 # deps.get + assets setup/build for all apps (umbrella-wide)
mix phx.server            # run the app at http://localhost:4000 (from willy_umbrella/)
iex -S mix phx.server     # run with a connected IEx shell (useful to inspect lobbies)

mix test                  # run all tests (from willy_umbrella/ runs both apps; no DB needed)
mix test apps/willy/test/willy/game_server_test.exs        # one file
mix test apps/willy/test/willy/game_server_test.exs:12     # one test at line 12

mix format                # format .ex/.heex across the umbrella
```

There is no database: Ecto/Postgres were removed entirely (2026-07). All state is in
memory; tests and the dev server run without any external services. Restarting the server
wipes all lobbies.

## Architecture

Elixir **umbrella** with two apps under `apps/`:

- **`willy`** — the OTP/domain app: `Phoenix.PubSub` (name `Willy.PubSub`), `DNSCluster`,
  `Finch`, **and the whole game domain** (`Willy.GameServer`, `Willy.Lobbies`, plus
  `Willy.GameRegistry` / `Willy.GameSupervisor` in its supervision tree).
- **`willy_web`** — the Phoenix/LiveView app: endpoint, router, and the two LiveViews.

### Lobby system (most important thing to know)

The server hosts **many independent lobbies at once**. Each lobby is one
`Willy.GameServer` process (`apps/willy/lib/willy/game_server.ex`), started on demand by
`Willy.Lobbies.create_lobby/0` under the `Willy.GameSupervisor` `DynamicSupervisor` and
registered in `Willy.GameRegistry` under its 4-letter code (via-tuple). Consequences:

- **Every `GameServer` API function takes the lobby `code` as its first argument.**
- Each lobby broadcasts on its own PubSub topic `GameServer.topic(code)`
  (`"word_game:" <> code`).
- Lobbies are `restart: :temporary` and clean up after themselves: the host explicitly
  leaving or "Close Lobby" broadcasts `:lobby_closed` and stops the process; a lobby with
  no connected player for ~10 minutes shuts itself down (`:idle_check`).
- `Willy.Lobbies` is the only entry point the web layer uses to create/look up lobbies
  (`create_lobby/0`, `exists?/1`, `whereis/1`, `normalize_code/1`, max 200 lobbies).

### State flow

All game state of a lobby is a single map held in its `GameServer` **entirely in memory**.

- Clients mutate state by calling `GameServer` API functions (thin `GenServer.call/cast`
  wrappers). Host-only actions take the caller's `player_id` and are authorized **inside
  the GenServer** (`host?/2`) — the LiveView passes the id through without checks.
- After every mutation, the server broadcasts `{:state_updated, state}` on its topic;
  special messages are `:lobby_closed` (process terminating) and
  `{:player_kicked, player_id}`.
- `WillyWeb.WordGameLive` subscribes on mount and copies the broadcast state into socket
  assigns via `assign_game_state/2`. **The LiveView holds no authoritative state.**
- The guessing-phase timer is server-side (`Process.send_after`, states
  `:stopped/:running/:paused`); the per-client 1s tick only refreshes the displayed
  countdown.

Shared constants (player limits, max guess words) live in `game_server.ex` and are exposed
through functions (`GameServer.min_total_players/0`, `max_guess_words/0`).

### Game phases and scoring

A game moves `:waiting -> :in_progress -> :finished`. Within `:in_progress` each round
cycles through three phases driven by the host: `:choose` (active player enters the main
word and guess words) -> `:guessing` (each guesser gets a turn plus a timer to mark found
words) -> `:revealing` (host reveals cards). Guessers score +1 the moment a found card is
revealed; the **active player** scores as much as the best guesser, but only **after the
last card has been revealed**. The host can configure `rounds_per_player` (1–3) in the
lobby: `round_order` then contains that many shuffled cycles, so every player is the
active player that many times. The host can step **backward** through phases/players
(`previous_phase`, `previous_guessing_player`); per-round awards are tracked in
`round_points` so they can be reverted — manual host corrections (`adjust_points`, the
+/− buttons in the sidebar) deliberately bypass `round_points` and survive reverts.

### Host powers

The lobby creator automatically joins as host (`LobbyLive` joins them server-side before
navigating). The host can kick players (`remove_player` — cleans up `round_order`/
`guessing_order`/`word_guesses` mid-game, advances the round if the active player was
kicked, and evicts the client via `{:player_kicked, id}`), adjust points, set timer
duration and rounds per player, and close the lobby.

### Identity, sessions, and reconnection

There is no auth. On joining, the LiveView generates a random `player_id`
(`GameServer.generate_player_id/0`) and pushes a `save_session` event to the
`PlayerSession` JS hook (`apps/willy_web/assets/js/app.js`), which persists one JSON entry
**per lobby** in `localStorage` under `willy:<CODE>` (the hook reads the code from
`data-code`). A per-tab `sessionStorage` flag (`willy:tab:<CODE>`) gates silent restore:
only a tab that already joined auto-rejoins on reload/reconnect via `restore_session`;
opening the invite link in a fresh tab always shows the name/rejoin screen first, so
nobody silently inherits another tab's (host) session. Joining requires a
non-blank nickname (enforced server-side, `{:error, :invalid_name}`). Disconnects (tab
close, `leave_game`) mark a player `connected: false` rather than removing them; anyone
who opens `/g/CODE` can rejoin as one of the offline players. The host disconnecting is
also just marked offline and can rejoin — only explicit leave/close ends the lobby.

### Routing / UI

```
live "/",        LobbyLive,    :index   # landing: create lobby / enter code
live "/g/:code", WordGameLive, :play    # the actual game
```

`WordGameLive` validates the code in `mount` (unknown code -> redirect to `/` with a
flash). The whole game UI — join form, host control panel, and all three phases — is one
large template (`word_game_live.html.heex`), branched on
`game_status`/`current_phase`/`role`. UI copy is in English. Styling is Tailwind; assets
are built with esbuild + tailwind via mix aliases (no Node build step).

## Planning docs

- `docs/OPTIMIZATIONS.md` — known issues / cleanup and refactor backlog.
- `docs/LOBBY_REWORK_PLAN.md` — the (implemented) plan for the multi-lobby architecture.
