# Umbau-Plan: Lobby-System (mehrere Spiele per Code / Link)

> **Status 2026-07-20: Umgesetzt.** Dieser Plan wurde gegen den damaligen Code-Stand
> optimiert (Ecto ist inzwischen komplett entfernt, `GameState` hatte bereits
> serverseitigen Timer, Rejoin-Flow und `caller_id`-Autorisierung — das alles wurde
> unverändert übernommen) und anschließend implementiert. Die Abschnitte unten
> beschreiben die finale Architektur.

## Ziel

- Ein Spieler **erstellt eine Lobby** (gibt dabei seinen Nickname an) und ist damit
  automatisch **Host**. Er bekommt einen **Lobby-Code** (z. B. `ABCD`) und einen
  **teilbaren Link** (`/g/ABCD`) mit Copy-Button.
- Andere joinen über den Code (Eingabefeld auf der Startseite) oder direkt über den Link.
- Beliebig viele Lobbies laufen gleichzeitig und unabhängig voneinander.
- **Reconnect:** Wer den Code kennt, landet auf `/g/CODE` und kann sich dort als einer der
  offline markierten Spieler zurückmelden (bestehender Rejoin-Flow, jetzt pro Lobby).
- **Host-Werkzeuge:** Spieler kicken (mit sauberem Cleanup mitten im Spiel) und Punkte
  manuell korrigieren (+/−), z. B. nach Streitfällen.
- **Rundenanzahl einstellbar:** `rounds_per_player` (1–3). Bei 2 ist jeder Spieler
  zweimal aktiver Spieler; die Rundenreihenfolge besteht aus n gemischten Durchläufen.

## Zielarchitektur (in der `willy`-App, nicht `willy_web`)

```
Willy.Application
├── Phoenix.PubSub (Willy.PubSub)              (wie bisher)
├── Registry (Willy.GameRegistry, keys: :unique)   code -> pid
└── DynamicSupervisor (Willy.GameSupervisor)
        └── Willy.GameServer("ABCD") …          ein Prozess pro Lobby, restart: :temporary
```

- **`Willy.GameServer`** = das frühere `WillyWeb.GameState`, aber pro Lobby instanziiert
  und via `{:via, Registry, {Willy.GameRegistry, code}}` registriert. Alle öffentlichen
  API-Funktionen nehmen `code` als erstes Argument. Die gesamte Spiellogik (Phasen,
  Punkte, Timer, previous_*, Reconnect) blieb erhalten.
- **`Willy.Lobbies`** (Context): `create_lobby/0` (kollisionsfreier Code, startet den
  Prozess, Obergrenze paralleler Lobbies), `exists?/1`, `whereis/1`, `normalize_code/1`.
  Die Web-Schicht kennt Registry/Supervisor nicht direkt.
- **PubSub-Topic pro Lobby:** `"word_game:" <> code` (`GameServer.topic/1`).
- **`restart: :temporary`**: Ein Crash startet die Lobby nicht mit leerem State unter
  gleichem Code neu — Clients werden beim nächsten Mount auf `/` umgeleitet.

## Lebenszyklus einer Lobby

- **Erstellung:** `LobbyLive` ruft `Lobbies.create_lobby/0`, joint den Ersteller sofort
  serverseitig als Host, speichert die Session per JS-Hook in `localStorage` (Key
  `willy:CODE`) und navigiert erst nach Bestätigung (`session_stored`) zu `/g/CODE` —
  so ist der Ersteller garantiert Host und nach dem Navigate direkt eingeloggt.
- **Ende:** Host-Leave oder „End Session" broadcastet `:lobby_closed` und beendet den
  Prozess (`{:stop, :normal, state}`); alle Clients werden auf `/` umgeleitet.
- **Idle-Timeout:** Minütlicher Selbstcheck; nach 10 Minuten ohne einen einzigen
  verbundenen Spieler beendet sich die Lobby selbst.
- **Kick:** `remove_player` broadcastet zusätzlich `{:player_kicked, id}`, damit der
  betroffene Client sofort rausfliegt. Mitten im Spiel wird aufgeräumt: Spieler wird aus
  `round_order`/`guessing_order`/`found_words`/`word_guesses` entfernt; war er gerade am
  Raten, rückt der nächste Rater nach; war er aktiver Spieler, endet die Runde und die
  nächste beginnt (bzw. das Spiel endet).

## Web-Schicht

```elixir
live "/",        LobbyLive,    :index   # Landing: erstellen (mit Nickname) / Code eingeben
live "/g/:code", WordGameLive, :play    # Spiel; Code aus den Params, Topic dynamisch
```

- `WordGameLive.mount/3`: `Lobbies.exists?(code)` prüfen, sonst Redirect auf `/` mit
  Flash; danach `GameServer.get_state(code)` + Subscribe auf `topic(code)`.
- **localStorage pro Lobby:** ein JSON-Eintrag `willy:CODE` mit
  `player_id`/`nickname`/`role` statt der drei globalen Keys. Der `PlayerSession`-Hook
  liest den Code aus `data-code` am Hook-Element. Alte Einträge (> 24 h) werden auf der
  Landing Page weggeräumt.
- **Stille Wiederherstellung nur pro Tab:** ein `sessionStorage`-Flag (`willy:tab:CODE`)
  entscheidet, ob die gespeicherte Session automatisch restauriert wird. Nur ein Tab, der
  bereits gejoint war (Reload, LiveView-Reconnect), rejoint still; wer den Invite-Link in
  einem frischen Tab öffnet, sieht immer zuerst die Namens-/Rejoin-Abfrage — auch wenn
  derselbe Browser die Host-Session hält.
- Codes: 4 Zeichen aus verwechslungsarmem Alphabet (ohne `0/O/1/I/L`), immer upgecased.

## Bewusste Entscheidungen

- **Keine Persistenz** über Server-Neustarts (Hobby-Spiel, bewusst in-memory).
- **Kein Host-Transfer**: Host-Disconnect (Tab zu) markiert ihn nur offline — er kann
  über den Code rejoin. Nur explizites Verlassen/Beenden schließt die Lobby.
- **Obergrenze**: max. 200 parallele Lobbies als simpler Missbrauchsschutz.
- Der „Join as Host"-Button auf `/g/CODE` erscheint weiterhin, wenn kein Host existiert —
  als Fallback, falls der Ersteller seine Session verliert und die Lobby sonst
  führungslos wäre.
