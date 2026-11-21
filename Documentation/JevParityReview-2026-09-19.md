# Jev: Einrichtung und erster Testfall-Abgleich

Stand: 19.09.2026, 10:02 UTC. Lokaler Snapshot bei Swift-HEAD
`0be321f51e479864cf49b26d590fea336c23c169`, JS-Referenz
`aaf2af36ec8ad05910f357a788e0e358bad32738`.
Parallel laufende Arbeiten können den aktuellen Bestand inzwischen verändern.

## Wiederverwendbarer OpenCode-Agent

Global installiert: `~/.config/opencode/agent/jev.md`, Alias `jav.md`,
Werkzeug `~/.config/opencode/tools/jev.ts`, Anleitung `agent/JEV-USAGE.txt`.

```bash
opencode run --agent jav "Prüfe die Assertion-Parität dieser JS- und Swift-Testfälle mit Jev."
```

Gemini 3.8 Flash liest Quellen und formuliert den Bericht. Jev beantwortet über
die Evaluation-API strukturierte Boolean-, Choice- und Score-Fragen. Der direkte
Aufruf als Sprachmodell (`-m vercel/typesafe-ai/jev`) ist falsch. Grundlage:
[Jev bei Vercel](https://vercel.com/ai-gateway/models/jev) und
[OpenCode Custom Tools](https://opencode.ai/docs/custom-tools/).

Das Werkzeug nutzt `ai@7.0.107` und vorhandene OpenCode-Vercel-Zugangsdaten oder
`AI_GATEWAY_API_KEY`. Keine kopierten Schlüssel. Jev und Koordinator haben eigene
Nutzungskosten. Der Agent besitzt Lese- und Jev-Rechte, keine Shell-/Schreibrechte.
Bis zu 32 Fragen pro Aufruf; 45 Sekunden Timeout, keine automatischen API-Retries.

Verifiziert: tatsächlicher CLI-Aufruf mit Alias `jav`, erfolgreiche Boolean- und
Choice-Auswertung (340 Input-/59 Output-Tokens, 313 ms). Score ebenfalls live
geprüft. Leere Fragen, doppelte IDs und fehlende Choice-Optionen werden abgewiesen.
Der zunächst versuchte kostenlose Muse-Koordinator lieferte HTTP 403; daher Gemini.

## Vollständiger offener Inventarstand

Der statische Vertragscheck bestand. Von 297 Runtime-Testdeklarationen haben 88
einen im Manifest zertifizierenden Vertrag, 102 sind dokumentierte Grenzen
(28 API, 38 Plattform, 36 nicht unterstützte Funktionen), 107 sind noch nicht
vollständig zertifiziert. Die 14 TypeScript-Typprüfungen werden separat geführt.

| Paket | Noch nicht zertifizierte Runtime-Deklarationen |
| --- | ---: |
| socket.io-client | 55 |
| engine.io-client | 42 |
| socket.io-parser | 2 |
| engine.io-parser | 8 |
| Gesamt | 107 |

Die [vollständige Liste](ReviewEvidence/JevParityBacklog-2026-09-19.csv) enthält
IDs, Originaltitel, Quellstellen, vorhandene Swift-Zuordnungen und Review-Notizen.
[Snapshot-Metadaten](ReviewEvidence/JevParitySnapshot-2026-09-19.json) halten
Revision und Hashes der verwendeten Dateien fest.
**107 offene Nachweise bedeuten nicht 107 komplett fehlende Tests.**
Die 88 Verträge sind hier statisch gezählt; aktuelle erfolgreiche Ausführungen
wurden in dieser Arbeit nicht nachgewiesen. Keine 100%-Coverage-Aussage.

## Sechs mit Jev vertieft geprüfte Reconnect-Fälle

Jev erhielt Quellausschnitte und beantwortete zwölf Fragen in zwei Batches.
Die folgenden Bewertungen wurden anschließend gegen den Quellcode geprüft.
Wahrscheinlichkeiten sind Modellschätzungen, keine Abdeckungswerte.

| ID | Jev-Urteil | Nachprüfung und konkrete Folgearbeit |
| --- | --- | --- |
| JS-014 | partial, 0,93 | Die zugeordneten `SocketReconnectEventsTest`-Methoden verwenden eine Fake-Engine und explizit `.reconnects(true)`. Für den Originalfall Default-Reconnect mit realem Transportabbruch und beobachtetem `.reconnect` ergänzen. |
| JS-016 | partial, 1,00 | `JSParityE2ETest.testReconnectAutomaticallyAfterReconnectingManually` wartet nach Transportabbruch nur auf `.connect`; die ausdrückliche `.reconnect`-Beobachtung des Originals fehlt in diesem Ablauf. |
| JS-017 | partial, 0,73 | Reentrantes `connect()` im Fehler-Callback ist bereits in `SocketReconnectEventsTest.testANewCycleStartedFromTheReconnectFailedHandlerGetsAFreshBudget` mit `[1,2,1,2]` geprüft. Nicht als fehlende Assertion zählen. Offen bleibt der Nachweis der Kombination mit echtem Timeout im selben Ablauf; Mapping gemeinsam prüfen. |
| JS-018 | partial, 0,97 | `SocketMangerTest.testBackoffIntervalCalulation` prüft die Formel; der vorhandene Timer-Test den ersten Versuch. Original verlangt drei Versuche und tatsächlich zunehmende Zeitintervalle. Diesen Ablauf samt `reconnectFailed` prüfen. |
| JS-023 | full_assertion_equivalence, 0,67 | `JSParityE2ETest.testReconnectTwiceThenFailWithImmediateTimeout` enthält Timeout 0, zwei Versuche und `reconnectFailed`. Kandidat für formale Zertifizierung nach Prüfung der nativen Szenario-Anpassung und aktuellem Testlauf; noch keine Freigabe. |
| JS-024 | partial, 0,88 | `testFiresReconnectEventsOnEverySocketOfTheManager` prüft bereits `[1,2]` und Fehlerabschluss. Die Socket-basierte native Event-API allein beweist keine fehlende Assertion. Timeout-Stimulus und gemeinsame Zuordnung prüfen; der Inventareintrag wird nicht pauschal zur API-Ausnahme umklassifiziert. |

Priorität nach Quellprüfung: JS-016, JS-018 und JS-014 vervollständigen; bei
JS-017/023/024 zuerst vorhandene Nachweise bündeln und Szenario-Unterschiede
prüfen. Jevs Prioritäts-Scores sind unkalibrierte Hinweise und kein Freigabekriterium.

[Exakte Jev-Eingaben und Antworten](ReviewEvidence/JevParityEvaluation-2026-09-19.json):
7.820 Input-, 506 Output-Tokens, zusammen 854 ms Bewertungszeit.
Quellensuche und Berichtserstellung des Koordinators kommen hinzu.
Nur diese sechs Fälle wurden semantisch mit Jev vertieft geprüft; die übrigen
101 offenen Fälle sind im vollständigen Backlog enthalten, aber nicht durch
diesen Lauf semantisch bewertet. Keine Swift-Laufzeittests ausgeführt und keine
Zertifizierungen, Ausnahmen oder Produktionsdateien durch diese Arbeit geändert.
