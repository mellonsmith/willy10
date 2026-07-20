# Optimierungen & Refactoring-Backlog

Notizen aus dem ersten Repo-Durchgang. Grob nach Wirkung/Risiko sortiert. Der große
Architektur-Umbau (mehrere Lobbies) hat ein eigenes Dokument: `LOBBY_REWORK_PLAN.md`.

> **Status 2026-07-19:** Punkte 2, 4, 5, 6, 8, 10, 11 und 13 sind umgesetzt (serverseitige
> Autorisierung über `caller_id`, serverseitiger Timer mit Pause/Resume, `initial_state/0`,
> zentrale Konstanten via `GameState.topic/0` u. a., GameState-Testsuite, Role-Whitelist,
> Tests ohne Postgres). Zusätzlich behoben: doppelte Punktevergabe bei mehrfachem Reveal,
> Punktelogik des aktiven Spielers (= bester Rater), Rejoin-Anzeige ohne getrennte Spieler,
> nicht funktionierendes Input-Reset-Event, Schriftgrößen langer Wörter. Offen: 1 (Lobby),
> 7, 9, 12, 14.
>
> **Update 2026-07-20:** Punkt 3 entschieden und umgesetzt — Ecto/Postgres komplett
> entfernt (Repo, Deps `ecto_sql`/`postgrex`/`phoenix_ecto`, DB-Configs, Release-Migrator,
> `migrate`-Overlays, `DataCase`). Kein Docker-Postgres mehr nötig. Außerdem alle
> Dependencies innerhalb der Constraints aktualisiert (u. a. Phoenix 1.7.24,
> LiveView 1.2.7, Bandit 1.12) und die `swoosh`-Lockfile-Leiche entfernt; `mix hex.audit`
> ist sauber. Major-Sprünge (Phoenix 1.8, gettext 1.0, tailwind-Installer 0.5) bewusst
> nicht mitgenommen.
>
> **Update 2026-07-20 (Lobby-Umbau):** Punkt 1 umgesetzt — der Singleton-`GameState` ist
> durch `Willy.GameServer` (ein Prozess pro Lobby, `Registry` + `DynamicSupervisor` in der
> `willy`-App) ersetzt, Details in `LOBBY_REWORK_PLAN.md`. Dazu: Landing Page `LobbyLive`
> (`/` erstellen/joinen, `/g/:code` spielen), localStorage-Session pro Lobby-Code,
> Idle-Timeout + Selbst-Terminierung, Host-Kick mit Mid-Game-Cleanup, manuelle
> Punktekorrektur (+/−, übersteht `previous_phase`), einstellbare Rundenanzahl pro Spieler
> (1–3), Namenspflicht beim Join (serverseitig), aktiver Spieler bekommt seine Punkte erst
> nach dem letzten Reveal. Testsuite läuft jetzt async (eigene Lobby pro Test). Punkt 12
> (Host-Transfer) bewusst nicht umgesetzt: Host-Disconnect ist nur noch „offline" mit
> Rejoin; nur explizites Verlassen/Schließen beendet die Lobby. Offen: 7, 9, 12, 14.

## A. Architektur / Korrektheit

1. **Ein einziger globaler `GameState`-GenServer** — nur ein Spiel pro Server möglich, und
   ein Absturz des Prozesses löscht das laufende Spiel für alle. Das ist gleichzeitig der
   Kern des Lobby-Umbaus (siehe eigenes Dokument). Bis dahin sollte der Prozess zumindest
   sauber unter einem Supervisor mit sinnvoller Restart-Strategie laufen (tut er, aber ohne
   State-Persistenz → Neustart = Datenverlust).

2. **Server vertraut den Clients zu stark.** Autorisierung passiert doppelt: einmal im
   LiveView über `role`/`player_state`-Assigns (die ein Client fälschen könnte) und einmal im
   GenServer. Die GenServer-Prüfungen sind die einzig verlässlichen — die LiveView-Checks
   sind nur UX. Beim Aufräumen darauf achten, dass **jede** zustandsändernde Aktion im
   GenServer gegen `player_id`/`host_id` geprüft wird. `remove_player` prüft z. B. serverseitig
   *nicht*, ob der Aufrufer der Host ist (nur im LiveView) — jeder Client mit der PubSub-
   Verbindung könnte den Cast auslösen. `reveal_word`/`reveal_all_words` prüfen nur
   `state.host_id != nil`, nicht *wer* auslöst.

3. **In-Memory-State ohne jede Persistenz.** Ecto + Postgres sind konfiguriert, aber komplett
   ungenutzt (keine Schemas, keine Migrationen). Entweder die DB-Abhängigkeit ganz entfernen
   (schlankeres Setup, `mix test` braucht dann kein Postgres mehr) **oder** sie tatsächlich
   für Persistenz/Historie nutzen. Aktuell ist sie reiner Ballast und ein Setup-Stolperstein.

4. **Timer läuft pro Client, nicht serverseitig.** Jeder LiveView hat sein eigenes
   `:timer.send_interval(1000, …)` und ruft bei `time_remaining == 0` selbst `skip_timer` auf.
   Bei N verbundenen Clients feuert `skip_timer` also N-mal (idempotent, aber unnötig), und
   die Zeitanzeige kann leicht auseinanderlaufen. Besser: ein serverseitiger Timer im
   GameState (z. B. `Process.send_after/3`), der den Phasenwechsel autoritativ auslöst und
   nur noch `timer_start`/`timer_duration` broadcastet, die der Client zur reinen Anzeige
   nutzt.

## B. Code-Duplizierung / Wartbarkeit

5. **Initial-State ist 3× dupliziert** (in `start_link`, `leave_game` und `end_session`, je
   ~22 Felder). In eine Funktion `initial_state/0` ziehen und überall aufrufen — sonst driftet
   bei jeder neuen State-Property eine der Kopien ab.

6. **Konstanten doppelt gepflegt.** `@topic "word_game"` steht sowohl in `game_state.ex` als
   auch in `word_game_live.ex`. `@min_players`/`@max_players`/`@timer_duration` liegen nur im
   GameState, werden aber konzeptionell auch im View gebraucht. In ein gemeinsames Modul
   (z. B. `WillyWeb.Game` oder `Willy.Game`) zentralisieren.

7. **`word_game_live.ex` mischt 20+ `handle_event`-Handler**, die fast alle nach dem gleichen
   Muster „prüfe role → rufe GameState-Funktion → `{:noreply, socket}`" aufgebaut sind. Ließe
   sich stark verdichten (z. B. generischer Host-Only-Handler). Reine Kür, aber senkt die
   Fehlerquote beim Kopieren.

8. **Fehlplatzierte private Funktion:** `text_size_class/1` steht mitten zwischen den
   `handle_info`-Klauseln (Zeile ~327), zwischen `{:state_updated, …}` und
   `:host_disconnected`. Das trennt die beiden `handle_info`-Klauseln optisch — ans Ende zu
   den anderen Helpern verschieben. (Elixir gruppiert die Klauseln zwar korrekt, aber es ist
   verwirrend zu lesen.)

9. **Die gesamte UI ist eine einzige ~530-Zeilen-`.heex`-Datei** mit tief verschachtelten
   `if`s über `game_status`/`current_phase`/`role`. In Function Components pro Phase
   aufteilen (`lobby`, `choose_phase`, `guessing_phase`, `reveal_phase`, `host_panel`,
   `scoreboard`) — deutlich leichter zu warten und zu testen.

## C. Robustheit / Edge Cases

10. **Kaum automatisierte Tests für die Spiellogik.** Es existieren nur die generierten
    Controller-/Error-Tests. Der GenServer ist pure Logik ohne I/O und lässt sich hervorragend
    unit-testen (join/leave, Phasenübergänge, Punktevergabe, previous_*-Revert). Vor dem
    Lobby-Umbau eine Testsuite für `GameState` anlegen — dient als Sicherheitsnetz.

11. **`String.to_atom` auf Client-Eingaben** (`restore_session`, `join_game` mit `as`). Da die
    Werte aus dem Browser/localStorage kommen, ist das theoretisch ein Atom-Leak-Vektor. Auf
    eine Whitelist (`"host" -> :host`, `"player" -> :player`) umstellen.

12. **`disconnect`-Handling bei Host-Wechsel unklar.** Verlässt der Host, wird das Spiel
    komplett zurückgesetzt und alle rausgeworfen — es gibt keinen Host-Transfer. Für ein
    robusteres Erlebnis: Host-Rolle an einen verbundenen Spieler übergeben statt Full-Reset.
    (Passt gut in den Lobby-Umbau.)

## D. Betrieb / Setup

13. **`mix test` erzwingt Postgres**, obwohl kein Test die DB nutzt. Sobald Punkt 3 geklärt
    ist, die `ecto.create`/`ecto.migrate`-Aliase aus der Test-Task entfernen → schnellere,
    abhängigkeitsfreie Tests.

14. **README ist praktisch leer** (nur der Projektname). Nach dem Umbau eine kurze
    Spielregeln-/Setup-Beschreibung ergänzen.

## Vorgeschlagene Reihenfolge

1. Testsuite für `GameState` schreiben (Netz für alles Weitere) — Punkt 10.
2. Aufräumen ohne Verhaltensänderung: `initial_state/0`, Konstanten zentralisieren, Helper
   verschieben, `String.to_atom` absichern — Punkte 5, 6, 8, 11.
3. Serverseitigen Timer + serverseitige Autorisierung härten — Punkte 2, 4.
4. DB-Entscheidung treffen (entfernen oder nutzen) — Punkte 3, 13.
5. Großer Lobby-Umbau — siehe `LOBBY_REWORK_PLAN.md`.
6. UI in Components aufteilen — Punkt 9.
