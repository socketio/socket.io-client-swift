# Upstream-Issues und -PRs mit Jev geprüft: Was der Fork daraus lernen kann

Stand: 19.09.2026, 18:14 UTC. Bewertet wurde der Fork bei Commit `119bd46` (Branch
`feat/socketio4-swift6.4`); bis zum aktuellen `bf62914` ist `Source/` unverändert,
nur `SocketPollingCloseTest` und `SocketRetrySafetyTest` wurden erweitert.
Quelle: alle 1515 Issues und Pull Requests von
[socketio/socket.io-client-swift](https://github.com/socketio/socket.io-client-swift)
(Snapshot 19.09.2026). Auswertung: read-only OpenCode-Agent `jev`
(Gemini 3.8 Flash als Evidenzsammler, TypeSafe Jev als Bewerter).

Jev-Nutzung: Stufe 1 65 Aufrufe, 1.154.249 Eingabe-/183.503 Ausgabe-Tokens, 40 s
Bewertungszeit; Stufe 2 58 Aufrufe, 568.609/41.162 Tokens, 31 s.
Dazu kommen die Gemini-Läufe des Koordinators (ein OpenCode-Lauf pro Batch), die
hier nicht abgerechnet sind. Alle Wahrscheinlichkeiten sind Modellschätzungen.

Rohdaten, Skripte und die vollständigen Ereignisprotokolle liegen außerhalb des
Repositories in `/home/monkey/code/socket.io-client-swift-upstream-triage/`.
Die Jev-Urteile sind als [Stufe-1-CSV](ReviewEvidence/UpstreamTriage-Stage1-2026-09-19.csv)
und [Stufe-2-CSV](ReviewEvidence/UpstreamTriage-Stage2-2026-09-19.csv) beigelegt.

## Kernaussagen

1. **Der Großteil der Upstream-Historie lehrt nichts über unseren Code.**
   Von 1274 Issues sind laut Stufe 1 rund 43 % Nutzungsfragen, 16 %
   Build-/Packaging-Probleme der CocoaPods- und Swift-2-bis-4-Ära und 15 % vom
   Maintainer behobene Defekte. Die Titel der 565 Support- und Doku-Items
   drehen sich vor allem um Verbindungsaufbau, URL und Pfad (192 Titel), dann um
   Binärdaten und Datentypen (46), Reconnect im Hintergrund (38) sowie TLS (30).
   Das ist die Themenliste, die das README zuerst beantworten sollte.

2. **Der Fork hat die substanziellen Upstream-Bugs überwiegend schon
   geschlossen.** Stufe 2 prüfte 369 Kandidaten gegen den Quellcode: 131
   bereits adressiert, 129 nicht anwendbar (Starscream, Objective-C, alte
   Server), 30 verhalten sich wie der JS-Client, 47 laut Jev noch
   zutreffend, 32 ohne ausreichende Evidenz. Beispiele mit Test im Fork:
   Polling-Crash #355/#356 (`SocketPollingCloseTest`), ungültige URLSession #465,
   Base64-Padding bei Polling #1496, `emit` direkt nach `connect` #385
   (Upgrade-Puffer, `SocketNativeEngineTest`).

3. **Ein reproduzierbarer Absturz ist der wichtigste Fund.**
   [#1421](https://github.com/socketio/socket.io-client-swift/issues/1421)
   (offen seit 2022): `connectParams` mit `<`, `>`, `\` oder `` ` `` lässt die
   Verbindung abstürzen. `allowedURLCharacterSet` (`SocketExtensions.swift:31`)
   kodiert diese vier Zeichen nicht, `createURLs()` schreibt sie in
   `percentEncodedQuery`, und Foundation bricht dort mit
   `Fatal error: Attempting to set percentEncodedQuery with invalid characters` ab.
   Lokal mit Swift 6.4 pro Zeichen nachgestellt. JS `encodeURIComponent` kodiert
   alle vier. Der Fix ist klein: verbotene Zeichenliste auf JS-Semantik umstellen
   (unkodiert nur `A-Z a-z 0-9 - _ . ! ~ * ' ( )`) plus Regressionstest.

4. **Fünf weitere Punkte nach manueller Prüfung:**
   - **Defekt #887:** Der Per-Socket-Timeout aus
     `connect(timeoutAfter:withHandler:)` wird bei Erfolg nicht abgebrochen.
     Nach Connect und späterem Verbindungsabbruch setzt die Reconnect-Schleife den
     Status auf `connecting`, der alte Timer feuert, ruft den Fehler-Handler,
     setzt `disconnected` und beendet per `leaveNamespace` den laufenden
     Reconnect. Der Manager-Timeout macht es richtig (Abbruch bei Open, wie JS).
     Fix: `DispatchWorkItem`, in `didConnect` abbrechen, Test ergänzen.
   - **Paritätslücke #1297:** JS macht aus `io("https://host/admin")` den
     Namespace `/admin`; der Fork ersetzt den URL-Pfad durch `socketPath` und
     verbindet still mit `/`. Query-Parameter der URL werden dagegen JS-gleich
     übernommen. Entweder JS-gleich als Namespace behandeln oder deutlich
     dokumentieren.
   - **Feature-Lücke mTLS (#857, #936, #1157):** Keine Client-Zertifikate; der
     JS-Node-Client akzeptiert `pfx`/`key`/`cert`. Nur relevant, wenn ein Nutzer
     gegenseitige TLS-Authentifizierung braucht.
   - **Rest-Parität #681:** Die Polling-Handshake-Anfrage hat fest 60 s
     `timeoutInterval`; JS bietet `requestTimeout` (standardmäßig unbegrenzt).
     Der eigentliche Wunsch des Reporters ist durch den Manager-`connectTimeout`
     (20 s, JS-gleich) erfüllt.
   - **Neu bewertbar #249 (Linux-Port):** Ohne Starscream scheitert `swift build`
     unter Linux nach 3 s in eigenem Code (`FoundationNetworking`-Import, `@objc`,
     Security-Framework). Ein Port ist damit erstmals eine überschaubare Aufgabe.

5. **Dokumentationspunkte statt Codeänderungen:** globaler Logger (#610,
   JS-analog), `\/`-Escaping beim Emit (#1512, bewusste Abweichung), negative
   Timeouts lösen eine Assertion aus (#1288), `.websocketUpgrade` feuert bei
   WebSocket-only vor dem Engine.IO-Handshake (#1301), Offline-Erkennung nur über
   den Ping-Timeout (#1374, wie JS), `once()` wird über `off(id:)` abgebrochen
   (#1507).

6. **Nie gemergte Upstream-PRs:** Von 47 nie gemergten PRs mit Verhaltensänderung sind 12 noch offen. Stufe 2 stuft ein: [#1233](https://github.com/socketio/socket.io-client-swift/pull/1233) noch zutreffend, [#1320](https://github.com/socketio/socket.io-client-swift/pull/1320) ohne Evidenz, [#1331](https://github.com/socketio/socket.io-client-swift/pull/1331) nicht anwendbar, [#1444](https://github.com/socketio/socket.io-client-swift/pull/1444) nicht anwendbar, [#1483](https://github.com/socketio/socket.io-client-swift/pull/1483) noch zutreffend, [#1508](https://github.com/socketio/socket.io-client-swift/pull/1508) noch zutreffend, [#1511](https://github.com/socketio/socket.io-client-swift/pull/1511) noch zutreffend, [#1518](https://github.com/socketio/socket.io-client-swift/pull/1518) noch zutreffend, [#1520](https://github.com/socketio/socket.io-client-swift/pull/1520) ohne Evidenz, [#1521](https://github.com/socketio/socket.io-client-swift/pull/1521) bereits adressiert, [#1524](https://github.com/socketio/socket.io-client-swift/pull/1524) bereits adressiert, [#1525](https://github.com/socketio/socket.io-client-swift/pull/1525) bereits adressiert. Manuell geprüft: #1524 (URLSession-Leak), #1508 (Ack-Set-Race), #1518 (wss als secure) und #1526 (autoConnect) sind im Fork gelöst; #1444, #1511 und #1520 betreffen Starscream oder Android und sind gegenstandslos; #1320 (Combine) und #1331 (Rohnachrichten) sind Feature-Ideen ohne JS-Bezug; die Jev-Urteile "noch zutreffend" zu #1233 und #1483 sind durch den Quellcode widerlegt (Abschnitt Manuell verifiziert). Die geschlossenen, nie gemergten PRs stammen fast alle aus der Zeit vor Swift 5 (Tabelle im Datenteil).

7. **Offene Upstream-Issues ohne Evidenz, die nur ein Gerätetest klärt:**
   [#1497](https://github.com/socketio/socket.io-client-swift/issues/1497) (Socket stopped listening event after 30 to 40 mins), [#1455](https://github.com/socketio/socket.io-client-swift/issues/1455) (Socket io gives a connection error when connecting back from), [#403](https://github.com/socketio/socket.io-client-swift/issues/403) (Network connection was lost). Diese decken sich mit den in `REMAINING-WORK.md` bereits offenen
   manuellen Hardware-Nachweisen (Hintergrund/Vordergrund, Netzverlust,
   Sperrbildschirm).

## Vorgehen

**Datenbasis.** Alle Issues und Pull Requests des Upstream-Repositories
`socketio/socket.io-client-swift` (Snapshot 19.09.2026 über die GitHub-API):
1274 Issues (243 offen), 241 PRs (16 offen, 154 gemergt, 87 nie gemergt), alle
5730 Kommentare sowie pro PR die geänderten Dateien mit Patch-Auszug. Unsere
Basis ist Upstream v16.1.1 (letzter Upstream-Commit 01.10.2024); jeder dort
gemergte PR ist damit bereits im Fork enthalten.

**Bewertung durch Jev.** Verwendet wurde der installierte, nur lesende
OpenCode-Agent `jev` (`~/.config/opencode/agent/jev.md`): Gemini 3.8 Flash
liest Dateien und reicht Evidenz durch, TypeSafe Jev beantwortet über die
Evaluation-API typisierte Fragen (Choice, Boolean, Score) und liefert exakte
Wahrscheinlichkeiten. Die Evidenz- und Fragedateien wurden vorab deterministisch
erzeugt, damit der Koordinator nichts zusammenfasst; die Tool-Ereignisse in den
`--format json`-Logs enthalten Eingabe und Ausgabe jedes Jev-Aufrufs.

**Stufe 1 (Vorfilter, ohne Fork-Kenntnis).** Ein Choice-Urteil pro Item mit
zehn Kategorien (Defekt potenziell aktuell, Defekt behoben/obsolet,
Feature-Wunsch, Build/Packaging, Support-Frage, Doku-Lücke, PR mit oder ohne
Verhaltensänderung, Duplikat, unzureichende Evidenz). Evidenz pro Item: Titel,
Labels, Status, Daten, Reaktionen, gekürzter Text (1000 Zeichen), die letzten
zwei Maintainer-Kommentare, der letzte Kommentar und bei PRs die geänderten
Dateien. 24 Items pro Jev-Aufruf.

**Stufe 2 (Kandidaten gegen den Fork-Quellcode).** Kandidaten sind alle Items
der Kategorien Defekt/Feature/Doku, unsichere Erstklassifikationen mit solcher
Zweitwahl sowie nie gemergte PRs mit Verhaltensänderung. Sie wurden nach Thema
gebündelt (Reconnect, Acks, Namespaces, Engine/Transport, TLS, Parser/Binär,
Threading/Speicher, API/Konfiguration). Pro Item drei Fragen: Status (bereits
adressiert, noch zutreffend, entspricht JS-Client, nicht anwendbar,
unzureichende Evidenz), Test vorhanden (Boolean) und Priorität (Score
Routine/Important/High/Critical). Der Koordinator las dafür die Fork-Dateien des
Themas, suchte item-spezifische Symbole in `Source/`, `Tests/` und der
Dokumentation und zitierte den JS-Client v4.8.3 / engine.io-client 6.6.6 aus
`/tmp/socket.io-js`. Fehlende Evidenz musste ausdrücklich benannt werden.
Einwände des Koordinators gegen Jev-Urteile sind als „Disputed“ erfasst.

**Manuelle Nachprüfung.** Die höher priorisierten „noch zutreffend“-Urteile und
das offene Issue #385 wurden anschließend von Hand im Quellcode geprüft
(siehe Abschnitt „Manuell verifiziert“).

## Grenzen

- Jev-Wahrscheinlichkeiten sind Modellschätzungen, keine Abdeckungswerte und
  kein Beweis. Ein „bereits adressiert“ bedeutet: zitierter Code oder Test
  spricht dafür; es wurde kein Test ausgeführt (die Swift-Tests laufen nur in
  der macOS-CI).
- Stufe 1 kennt den Fork nicht und stuft alte Starscream-Crashes teils als
  „potenziell aktuell“ ein; das ist beabsichtigt (Vorfilter) und wird in Stufe 2
  korrigiert.
- Die Evidenzsammlung in Stufe 2 ist heuristisch (Grep und Lesen durch Gemini);
  „unzureichende Evidenz“ heißt oft nur, dass der Sammler die Stelle nicht
  fand, wie das Beispiel #385 zeigt.
- Support-Fragen wurden nicht einzeln beantwortet, sondern nur thematisch
  gezählt.
- Betriebsprobleme: `opencode run` blockiert ohne `< /dev/null`; das
  Vercel-Gateway antwortete bei fünf parallelen Jev-Aufrufen wiederholt mit
  HTTP 503 (drei parallele Aufrufe mit Backoff waren stabil); ein Batch
  (#1278–#1301) scheiterte fünfmal mit `AI_InvalidResponseDataError` und wurde
  geteilt.

## Manuell verifiziert

Die folgenden Jev-Urteile wurden von Hand gegen den Quellcode geprüft; Zeilenangaben beziehen sich auf Commit `119bd46`.

- #887 (Timeout handler should be invalidated once connection succeeds) — BESTÄTIGT noch zutreffend.
  `SocketIOClient.connect(withPayload:timeoutAfter:withHandler:)` (Source/SocketIO/Client/SocketIOClient.swift:286-321) plant den Timeout mit
  `socketAsyncAfter` und prüft beim Feuern nur `status == .connecting || .notConnected`. Wird nach erfolgreichem Connect die Verbindung
  vor Ablauf der Frist getrennt (Status `.notConnected`), läuft der `else`-Zweig und ruft `handler?()` trotz erfolgreichem Connect.
  Kein Abbruch des Timers in `didConnect`. Der Manager-Timeout (`connectTimeout`, SocketManager.swift:220/311) wird dagegen bei erfolgreichem Open
  abgebrochen (JS-Parität, manager.ts onopen -> cleanup). Tests: nur SocketActiveTest.swift:29 nutzt `timeoutAfter: 1` mit `withHandler: nil`;
  kein Test für Handler-Semantik. Empfehlung: DispatchWorkItem, in `didConnect` cancel; Test ergänzen.
- #681 (60-second timeout) — TEILWEISE zutreffend. `SocketEngine.startOpeningTransport()` (SocketEngine.swift:421-422) setzt für den
  Polling-Handshake `timeoutInterval: 60` fest. Der Fork hat aber einen Manager-`connectTimeout` (Default 20 s, `.connectError("timeout")`),
  der das Anliegen des Reporters abdeckt. Rest: harte 60-s-Obergrenze für die Handshake-Anfrage; JS engine.io-client hat dafür die Option
  `requestTimeout` (standardmäßig unbegrenzt). Priorität niedrig; ggf. Option `requestTimeout` für Parität.
- #610 (Log option affecting all sockets) — BESTÄTIGT zutreffend, aber JS-analog. `DefaultSocketLogger.Logger` ist statisch
  (SocketLogger.swift:71-78); `.log(true)` eines Managers schaltet prozessweit. JS `debug` ist ebenfalls prozessweit (DEBUG-Env).
  Empfehlung: im README dokumentieren, keine Codeänderung nötig.
- #385 (Sometimes emit method is not working on connect; offen, 14 Kommentare) — vermutlich ADRESSIERT (Jev: unzureichende Evidenz,
  weil der Sammler die Tests nicht fand). Der vom Maintainer vermutete Pfad (Pakete landen nach dem Flush in probeWait, wenn das Upgrade
  scheitert) ist im Fork mit `probeWait`/`flushProbeWait` (SocketEngine.swift:198, 652-664, 1074, 1145-1150) und Tests abgedeckt:
  SocketNativeEngineTest.testFailedUpgradeKeepsHealthyPollingAndFlushesBufferedWrites (:380), testUpgradeFailureAfterStopPollingClosesInsteadOfResumingPolling (:523),
  testUpgradeWaitsForGetAndPostAndQueuesUpgradeFirst (:593), SocketEngineWritableTest.testCustomEngineFlushesQueuedPollingWritesThroughWebSocketAfterUpgrade (:73),
  Fixture upgrade-race-proof.mjs. Kein Test für exakt "emit im connect-Handler während Upgrade" gefunden; Ausführung nicht lokal möglich (nur macOS-CI).
- #887 Ergänzung: `didDisconnect` setzt `.disconnected`, `.notConnected` kommt nur aus `abortPendingConnect` (SocketIOClient.swift:571-576).
  Die schädliche Variante läuft über die Reconnect-Schleife: `setReconnecting(reason:)` (SocketIOClient.swift:1736-1738) setzt den Status
  wieder auf `.connecting`. Feuert dann der alte Per-Socket-Timer, greift der `.connecting`-Zweig: Status `.disconnected`, `leaveNamespace()`
  (-> `manager.disconnectSocket(self, removeFromManager: false)`, bricht den laufenden Reconnect dieses Namespaces ab) und `handler?()`.
  Damit reproduziert der Fork exakt das in #887 beschriebene Verhalten (Connect ok -> Netzwechsel -> Handler feuert, Status disconnected).
- #1512 (Any message including slash gets escape character; offen) — BEKANNTE, DOKUMENTIERTE ABWEICHUNG. `JSONSerialization` schreibt `/` als `\/`
  (PARITY.md:78, Documentation/ProtocolParityReview.md:438-454: bewusste Abweichung neben sortierten Schlüsseln und erweiterten Jahreszahlen).
  Für JSON-Konsumenten (JSON.parse) gleichwertig; JS sendet `/` unmaskiert. Keine Codeänderung geplant; Hinweis im README wäre sinnvoll.
- #1496 (Base64 in Polling nicht gepaddet; offen) — ADRESSIERT. `SocketEnginePacketCodec.swift:16` nutzt `Data.base64EncodedString()` (Foundation, immer mit
  Padding), Decoder akzeptiert fehlendes Padding und URL-sichere Zeichen (SocketEnginePacketCodec.swift:64). Server-Seite (engine.io-parser encodePacket.js:8)
  nutzt `toString("base64")` mit Padding.
- #857 (Reconnect-Schleife mit Client-Zertifikat; geschlossen 2017, Jev High) — TEILWEISE zutreffend, als FEATURE-LÜCKE. Der Fork unterstützt
  Server-Trust, Pinning und eigene Anker (SocketSessionDelegateProxy.swift:31-66, nur `URLCredential(trust:)`), aber keine Client-Identität
  (kein `pfx`/`identity`/`URLCredential(identity:)` in Source/SocketIO/Security oder in den Optionen). Verlangt der Server ein Client-Zertifikat,
  scheitert der Polling-Handshake (SocketEnginePollable.swift:236-247 -> didError) und die Reconnect-Schleife läuft, wie beschrieben.
  JS-Node-Client akzeptiert `pfx`/`key`/`cert`/`ca`/`rejectUnauthorized` (engine.io-client transports/*.node.ts). Unter dem Paritätsziel eine
  dokumentierbare Lücke (mTLS); Priorität niedrig, sofern kein Nutzer mTLS braucht.
- #1507 (Timeout oder Abbruch für `once()`; offen 2024, Jev Important) — ADRESSIERT. `once(_:callback:)` liefert eine UUID (SocketIOClient.swift:1591),
  `off(id:)` (SocketIOClient.swift:1536) entfernt den Handler; das ist der gewünschte Abbruch. Ein Timeout für `once` kennt auch der JS-Client nicht.
  Jev-Urteil "noch zutreffend" (0,79) widerlegt durch Quellcode.
- #249 (Linux Port; offen seit 2015, Jev "noch zutreffend" 1,00) — HEUTE NEU BEWERTBAR. `swift build` (Swift 6.4, aarch64 Linux) scheitert nach der
  Starscream-Entfernung nicht mehr an Starscream, sondern nach 3 s in eigenem Code: `HTTPCookie` u.a. brauchen unter Linux
  `#if canImport(FoundationNetworking) import FoundationNetworking` (SocketEngineSpec.swift:240-241), `@objc`-Deklarationen kollidieren mit
  `-disable-objc-interop` (SocketManager.swift:250), und das Security-Framework (SecTrust-Pinning) wird in 3 Dateien importiert. Ein Linux-Port
  ist damit erstmals eine überschaubare Aufgabe (Bedingt-Import, @objc entfernen, TLS-Pinning unter Linux ausklammern), aber nicht Teil dieses Reviews.
- #1297 (Namespace und Query aus der Manager-URL ableiten; offen 2020) — HALB ADRESSIERT, Rest ist eine echte PARITÄTSLÜCKE. Query-Parameter der
  URL erreichen die Verbindung (SocketEngine.createURLs, Kommentar zitiert JS `parsed.queryKey`; Tests SocketQueryOptionTest.swift:39-72).
  Der URL-Pfad wird dagegen durch `socketPath` ersetzt (SocketEngine.swift:454-455) und nie als Namespace interpretiert; JS `lookup()`
  (socket.io-client lib/index.ts:8-34) macht aus `io("https://host/admin")` den Namespace `/admin`. Wer JS-Code portiert, landet still im
  Default-Namespace. Empfehlung: `SocketManager(socketURL:)` mit nicht-leerem Pfad dokumentieren oder JS-gleich als Namespace behandeln;
  Priorität Important (stille Fehlfunktion beim Portieren, genau das Szenario des Issues).
- #1301 (nur `.websocketUpgrade` feuert, sonst kein Handler; geschlossen 2020) — WEITGEHEND ADRESSIERT. Ohne Engine.IO-OPEN vom Server greift heute
  der Manager-`connectTimeout` (20 s, `.connectError("timeout")`, wie JS). Verbleibende Eigenheit: `.websocketUpgrade` wird bei WebSocket-only
  schon beim Transport-Open gemeldet (SocketEngine.swift:523-525), vor dem Engine.IO-Handshake; JS kennt dieses Ereignis nicht. Doku-Hinweis.
- #1288 ("Invalid timeout:" Assertion; offen 2020) — KEIN DEFEKT. `connect(timeoutAfter:)` prüft `assert(timeoutAfter >= 0)` (SocketIOClient.swift:288);
  ein negativer Wert ist ein Aufruffehler. JS hätte bei negativem `timeout` sofort `connect_error timeout` gemeldet. Dokumentieren.
- #1374 (Status bleibt connected ohne Internet; offen 2021) — ENTSPRICHT JS. Erkennung nur über Ping-Timeout (`pingInterval + pingTimeout`,
  SocketEngine.swift:820-835, wie engine.io-client socket.ts:660-670); ohne Server-Ping keine schnellere Erkennung. Gemini-Einwand bestätigt.
- #1483 (PR: Default-Pfad + Starscream Native Engine; offen 2024), #1233 (PR: Fehlerbehandlung bei falschem Verbindungsstatus; offen 2019),
  #1473 (PR: verbesserte WebSocket-Reconnect-Logik; geschlossen 2024) — Jev "noch zutreffend" mit p <= 0,77; die Einwände des Sammlers
  (Default-Pfad ist `/socket.io/`, SocketManager.swift:1128; connect() bei bestehender Verbindung ist wie in JS ein No-op; Heartbeat ist in
  Engine.IO v4 serverseitig) sind stimmig. Starscream-Teil von #1483 ist gegenstandslos.
- #1524 (PR: URLSession-Leak in SocketEngine; offen 2024) — ADRESSIERT. `resetEngine`/Session-Wechsel rufen `invalidateAndCancel()` (SocketEngine.swift:236, 317, 933;
  WebSocketSessionDelegateProxy.swift:132-146 mit `finishTasksAndInvalidate` und verzögertem `invalidateAndCancel`). Jev 1,00 bestätigt.
- #1444 (PR: Starscream `.viabilityChanged`; offen 2023) und #1511 (PR "Android"; offen 2025) — NICHT ANWENDBAR: Starscream ist entfernt, Android
  ist kein Ziel des Forks (URLSession-basiert).
- #1526 (PR: `autoConnect`-Option; geschlossen 2026) — ADRESSIERT: der Fork hat `autoConnect` inklusive neu erzeugter Namespaces (Documentation/Release17.md, CHANGELOG).
- #1518 (PR: `wss://` setzt `secure`; offen 2025) und #1400 (Issue: WSS löst keine Secure-Konfiguration aus; offen) — ADRESSIERT. `SocketEngine.init`
  leitet `secure` aus dem Schema `https`/`wss` ab (SocketEngine.swift:211); Upstream 16.1.1 prüfte nur `https://`.
- #1508 (PR: Crash durch konkurrierende Änderung des Ack-Sets; offen 2024) — ADRESSIERT. `SocketAckManager` schützt alle Mutationen mit `NSLock`
  (SocketAckManager.swift:73-116); Callbacks laufen nach dem Unlock.
- #1520 (PR: fehlendes Error-Event bei Starscream `HTTPUpgradeError`/`.error`; offen 2025) — NICHT ANWENDBAR. Starscream-spezifisch; der native Transport
  meldet Fehler und Close-Codes über `.closed(code, reason, error)` (SocketEngine.swift:528-530) an `websocketDidDisconnect`.
- #1320 (PR: Combine-Publisher für Events; offen 2020) und #1331 (PR: Option, Nachrichten ungeparst als String zu empfangen; offen 2021) — FEATURE-IDEEN
  ohne JS-Entsprechung; kein Paritätsthema. Der Fork bietet stattdessen async/await-Acks und `SocketRawView`. Nur bei konkretem Bedarf aufgreifen.
- #1421 (Crash bei `<`, `>`, `\` in connectParams; offen seit 2022) — **BESTÄTIGTER CRASH, mit ausführbarem Code belegt.**
  `CharacterSet.allowedURLCharacterSet` (SocketExtensions.swift:31-34) verbietet nur `!*'();:@&=+$,/?%#[]" {}^|`; die Zeichen
  `<`, `>`, `\` und `` ` `` bleiben damit in `urlEncode()` (SocketExtensions.swift:156) unkodiert. `SocketEngine.createURLs()` schreibt sie
  in `urlPolling.percentEncodedQuery` / `urlWebSocket.percentEncodedQuery` (SocketEngine.swift:488-489). Foundation bricht dabei ab:
  `Fatal error: Attempting to set percentEncodedQuery with invalid characters` (verifiziert mit Swift 6.4, Foundation, je ein Lauf pro Zeichen;
  `URLComponents` ist plattformgemeinsamer Foundation-Code, auf Darwin ist das Verhalten identisch dokumentiert). Der anschließende
  `urlPolling.url!`-Force-Unwrap (SocketEngine.swift:490) wäre der zweite Absturzpunkt.
  JS `encodeURIComponent` kodiert alle vier Zeichen; unter dem Paritätsziel ist das eine Abweichung mit Absturzfolge.
  Fix: die vier Zeichen der verbotenen Liste hinzufügen, besser die Liste ganz auf JS-Semantik umstellen (unkodiert nur
  `A-Z a-z 0-9 - _ . ! ~ * ' ( )`). Test: `connectParams` mit `<`, `>`, `\`, `` ` `` gegen `urlPolling`/`urlWebSocket`.
- #1509, #1219, #1290 (handleAck-Crashes in `Set._Variant.remove`) — ADRESSIERT. Der Stacktrace zeigt genau `executeAck`; `SocketAckManager`
  schützt heute alle Mutationen mit `NSLock` und ruft Callbacks erst nach dem Unlock (SocketAckManager.swift:84-125). Jev stufte #1509/#1219
  als "noch zutreffend" ein, der Gemini-Einwand und der Quellcode widerlegen das.
- #1157 und #936 (TLS-Client-Zertifikate) — gleiche Lücke wie #857: keine Client-Identität im Fork; Sammelpunkt mTLS.
- #1513, #1455, #1497 (Verbindung nach Hintergrund/Sperrbildschirm, Abbruch nach 30-40 Minuten; alle offen) — OHNE EVIDENZ entscheidbar.
  Das sind genau die Szenarien, die `REMAINING-WORK.md` als offene manuelle Hardware-Nachweise führt; die macOS-CI kann sie nicht zeigen.
- #952, #1013, #1150, #1259, #1476 (Codable-Dekodierung, eigener Parser, Protobuf, thread-sichere Handler) — FEATURE-WÜNSCHE ohne JS-Bezug
  bzw. bewusste Architekturentscheidungen (queue-basiertes Threading-Modell). Kein Handlungsbedarf für die Parität.
- #1498 ("EngineError error 0"; offen 2024) — `EngineError.canceled` ist im Fork toter Code, der nie geworfen wird (Gemini-Einwand, SocketEngine.swift:1332);
  die Meldung stammt aus Upstream 16.x. Kein Defekt, aber der ungenutzte Fehlerfall könnte entfernt werden.

## Datenteil
Generiert am 2026-09-19 18:14 UTC. Klassifiziert: 1515 von 1515 Items; in Stufe 2 bewertet: 369.


## Stufe 1: Erstklassifikation aller Items

Eine Choice-Frage pro Item mit zehn Kategorien; Evidenz waren Titel, Labels, Datum, gekürzter Text, letzte Maintainer-Kommentare und bei PRs die geänderten Dateien. Ohne Fork-Kenntnis; nur Vorfilter.

### Issues, offen (n=243)

| Kategorie (Jev-Wahl) | Anzahl |
| --- | ---: |
| Defekt, potenziell aktuell | 96 |
| Support-/Nutzungsfrage | 81 |
| Build/Packaging/Umgebung | 30 |
| Feature-Wunsch | 20 |
| Dokumentationslücke | 6 |
| Defekt, behoben oder obsolet | 5 |
| Unzureichende Evidenz | 5 |

### Issues, geschlossen (n=1031)

| Kategorie (Jev-Wahl) | Anzahl |
| --- | ---: |
| Support-/Nutzungsfrage | 468 |
| Defekt, behoben oder obsolet | 182 |
| Build/Packaging/Umgebung | 176 |
| Defekt, potenziell aktuell | 80 |
| Feature-Wunsch | 57 |
| Duplikat/ungültig | 32 |
| Unzureichende Evidenz | 24 |
| Dokumentationslücke | 10 |
| PR ohne Verhaltensänderung | 2 |

### PRs, nicht gemergt (n=87)

| Kategorie (Jev-Wahl) | Anzahl |
| --- | ---: |
| PR mit Verhaltensänderung | 38 |
| PR ohne Verhaltensänderung | 18 |
| Build/Packaging/Umgebung | 16 |
| Defekt, potenziell aktuell | 8 |
| Defekt, behoben oder obsolet | 3 |
| Unzureichende Evidenz | 2 |
| Feature-Wunsch | 1 |
| Duplikat/ungültig | 1 |

### PRs, gemergt (bereits in unserer Basis v16.1.1) (n=154)

| Kategorie (Jev-Wahl) | Anzahl |
| --- | ---: |
| PR mit Verhaltensänderung | 65 |
| PR ohne Verhaltensänderung | 42 |
| Defekt, behoben oder obsolet | 26 |
| Build/Packaging/Umgebung | 18 |
| Unzureichende Evidenz | 3 |

Unsichere Erstklassifikationen (Top-Wahrscheinlichkeit unter 0,6): 286. Sie wurden in Stufe 2 aufgenommen, wenn die Zweitwahl eine Kandidatenkategorie war.

## Stufe 2: Kandidaten gegen den Fork-Quellcode

Kandidaten: alle Items der Kategorien Defekt/Feature/Doku sowie nicht gemergte PRs mit Verhaltensänderung. Pro Item drei Fragen (Status-Choice, Test-Boolean, Prioritäts-Score). Gemini 3.8 Flash sammelte die Evidenz im Fork (Source, Tests, Doku) und in der JS-Referenz v4.8.3; Jev bewertete.

| Status (Jev-Wahl) | Anzahl |
| --- | ---: |
| im Fork bereits adressiert | 131 |
| nicht anwendbar | 129 |
| noch zutreffend | 47 |
| Unzureichende Evidenz | 32 |
| entspricht JS-Client | 30 |

| Priorität (Jev-Score, wahrscheinlichste Stufe) | Anzahl |
| --- | ---: |
| Critical | 1 |
| High | 45 |
| Important | 112 |
| Routine | 211 |

### Noch zutreffend laut Jev (47)

Sortiert nach Priorität. **Diese Liste ist ein Rohbefund, kein Arbeitsvorrat.** 45 der 47 Urteile wurden gegengeprüft (von Hand oder durch den Einwand des Evidenzsammlers, der jeweils unter dem Eintrag steht); nur neun blieben handlungsrelevant: #1421, #887, #681, #610, #857 mit #936 und #1157, #249 und #216. Die übrigen sind widerlegt, Feature-Wünsche ohne JS-Bezug oder bewusste Architekturentscheidungen. Nur #216 und #1365 wurden nicht gegengeprüft.

- [#1421](https://github.com/socketio/socket.io-client-swift/issues/1421) (issue, open, 2022) **Crash when using '<', '>', '\' in connectParams** — noch zutreffend 0.99; Test vorhanden: nein (0.03); Priorität High; Evidenz: `Source/SocketIO/Util/SocketExtensions.swift:33`
- [#1518](https://github.com/socketio/socket.io-client-swift/pull/1518) (pr, open, nicht gemergt, 2025) **fix: wss secure** — noch zutreffend 0.96; Test vorhanden: nein (0.10); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1124`
- [#1400](https://github.com/socketio/socket.io-client-swift/issues/1400) (issue, open, 2022) **`WSS` protocol does not trigger secure config** — noch zutreffend 0.87; Test vorhanden: nein (0.12); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1124`
- [#857](https://github.com/socketio/socket.io-client-swift/issues/857) (issue, closed, 2017) **Reconnecting causes disconnect/reconnect loop when using client certificate authentication** — noch zutreffend 0.78; Test vorhanden: nein (0.03); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEnginePollable.swift:236`
- [#1509](https://github.com/socketio/socket.io-client-swift/issues/1509) (issue, open, 2024) **handleAck crash in V16.1.1** — noch zutreffend 0.73; Test vorhanden: nein (0.05); Priorität High; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:84`
  - Einwand des Evidenz-Sammlers: #1509: Source/SocketIO/Ack/SocketAckManager.swift:114 — The crash in Set._Variant.remove during executeAck called from handleAck is resolved because acks.remove is now lock-guarded by NSLock (already_addressed).
- [#1200](https://github.com/socketio/socket.io-client-swift/issues/1200) (issue, open, 2019) **SocketManager.init failing with config options** — noch zutreffend 0.71; Test vorhanden: nein (0.10); Priorität High; Evidenz: `Source/SocketIO/Util/SocketExtensions.swift:114`
  - Einwand des Evidenz-Sammlers: #1200: Source/SocketIO/Util/SocketExtensions.swift:114 — the `.compress` option was removed and `SocketManager.init(socketURL:config:[.log(...)])` initializes without crashing.
- [#1508](https://github.com/socketio/socket.io-client-swift/pull/1508) (pr, open, nicht gemergt, 2024) **Fix crash after concurent modification of acks Set.** — noch zutreffend 0.63; Test vorhanden: nein (0.07); Priorität High; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:84`
  - Einwand des Evidenz-Sammlers: #1508: Source/SocketIO/Ack/SocketAckManager.swift:84 — SocketAckManager storage is lock-guarded with NSLock around addAck, executeAck, and timeoutAck, eliminating concurrent modification of the acks Set (already_addressed).
- [#1326](https://github.com/socketio/socket.io-client-swift/issues/1326) (issue, open, 2021) **v16 EXC_BAD_ACCESS** — noch zutreffend 0.56; Test vorhanden: nein (0.16); Priorität High; Evidenz: `Source/SocketIO/Util/SocketExtensions.swift:117`
  - Einwand des Evidenz-Sammlers: #1326: Source/SocketIO/Util/SocketExtensions.swift:117 — Socket.IO 2 server support was removed, and dictionary configuration bridging for path and connectParams works without EXC_BAD_ACCESS.
- [#784](https://github.com/socketio/socket.io-client-swift/issues/784) (issue, open, 2017) **Trying to reconnect always** — noch zutreffend 0.51; Test vorhanden: nein (0.04); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1023`
  - Einwand des Evidenz-Sammlers: #784: Source/SocketIO/Manager/SocketManager.swift:1023 — Jev evaluated still_applicable, but rapid reconnect loops and negative attempt numbers were resolved by JavaScript-aligned backoff scheduling, 1-based attempt counting, and disconnecting active transports on reconnect.
- [#1428](https://github.com/socketio/socket.io-client-swift/issues/1428) (issue, open, 2022) **Doing Polling issue from swift client when using v4.5.2 socket.IO in a node.js server** — noch zutreffend 0.51; Test vorhanden: nein (0.16); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:118`
  - Einwand des Evidenz-Sammlers: #1428: Source/SocketIO/Engine/SocketEngine.swift:118 — Jev evaluated still_applicable, but starting with polling before upgrading to WebSocket is standard Engine.IO protocol behaviour matching the JavaScript client (engine.io-client socket.ts:1177), and .forceWebsockets(true) is supported and tested in Tests/TestSocketIO/E2E/EngineRemainingParityE2ETest.swift:108.
- [#909](https://github.com/socketio/socket.io-client-swift/issues/909) (issue, open, 2017) **After connection upgrade to webSocket In case of a failure to reconnect client will never reconnect again and be stuck in an endless reconnect loop** — noch zutreffend 0.49; Test vorhanden: nein (0.04); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1020`
  - Einwand des Evidenz-Sammlers: #909: Source/SocketIO/Manager/SocketManager.swift:1020 — Jev evaluated still_applicable, but tight reconnect loops and failure to recover from temporary non-200 polling handshakes were resolved by JavaScript-aligned backoff delay scheduling in scheduleReconnectAttempt and clean session resets in resetEngine.
- [#1483](https://github.com/socketio/socket.io-client-swift/pull/1483) (pr, open, nicht gemergt, 2024) **Use correct default socket path. Use native engine of StarScream** — noch zutreffend 0.39; Test vorhanden: nein (0.30); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1128`
  - Einwand des Evidenz-Sammlers: #1483: Source/SocketIO/Manager/SocketManager.swift:1128 — Jev evaluated still_applicable, but SocketManager already defaults socketPath to "/socket.io/" matching JS socket.io-client while SocketEngine defaults to "/engine.io/" matching JS engine.io-client, and Starscream/useCustomEngine was removed.
- [#610](https://github.com/socketio/socket.io-client-swift/issues/610) (issue, closed, 2017) **Log option affecting all sockets** — noch zutreffend 0.99; Test vorhanden: nein (0.08); Priorität Important; Evidenz: `Source/SocketIO/Util/SocketLogger.swift:73`
- [#936](https://github.com/socketio/socket.io-client-swift/issues/936) (issue, closed, 2018) **Can we connect to a TCP socket which requires Two way authenticated communications.** — noch zutreffend 0.89; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Security/SocketTLSConfiguration.swift:9`
- [#1157](https://github.com/socketio/socket.io-client-swift/issues/1157) (issue, open, 2019) **SSL / TLS client certificate authentication** — noch zutreffend 0.89; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Documentation/NativeWebSocketTransport.md:5`
- [#681](https://github.com/socketio/socket.io-client-swift/issues/681) (issue, open, 2017) **Client fires "error" event for 60 second timeout, timeout handlers >60s never fire** — noch zutreffend 0.84; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:422`
  - Einwand des Evidenz-Sammlers: #681: Source/SocketIO/Manager/SocketManager.swift:644 — Jev classified this as still_applicable, but pre-connection timeouts now emit .connectError rather than .error to match JavaScript client parity, though Source/SocketIO/Engine/SocketEngine.swift:422 still hardcodes a 60-second timeoutInterval on polling handshakes.
- [#1512](https://github.com/socketio/socket.io-client-swift/issues/1512) (issue, open, 2025) **Any message incuding slash will be added escape character after calling emit** — noch zutreffend 0.83; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Parse/SocketPacket.swift:201`
- [#1507](https://github.com/socketio/socket.io-client-swift/issues/1507) (issue, open, 2024) **Timeout or way to cancel `socketClient.once()` so that `.once()` can be safely wrapped in a `withCheckedContinuation` swift async block** — noch zutreffend 0.79; Test vorhanden: nein (0.07); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1591`
- [#1233](https://github.com/socketio/socket.io-client-swift/pull/1233) (pr, open, nicht gemergt, 2019) **Fix connection error handling if the connection state is wrong** — noch zutreffend 0.77; Test vorhanden: nein (0.34); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:286`
  - Einwand des Evidenz-Sammlers: #1233 | Source/SocketIO/Client/SocketIOClient.swift:290 | Calling connect when already connected is an intentional no-op matching JS client socket.ts:361 rather than a failure invoking the error handler.
- [#887](https://github.com/socketio/socket.io-client-swift/issues/887) (issue, closed, 2017) **Timeout handler should be invalidated once connection succeed** — noch zutreffend 0.70; Test vorhanden: nein (0.09); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:305`
- [#1323](https://github.com/socketio/socket.io-client-swift/issues/1323) (issue, open, 2021) **Emit parameters wrapped twice** — noch zutreffend 0.68; Test vorhanden: nein (0.23); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:610`
  - Einwand des Evidenz-Sammlers: #1323: Source/SocketIO/Client/SocketIOClient.swift:610 — the fork provides the requested array overload `emit(_:with:completion:)`, preventing double-wrapping when wrapping emit calls.
- [#1154](https://github.com/socketio/socket.io-client-swift/issues/1154) (issue, open, 2019) **connect timeout doesn't called when network is off** — noch zutreffend 0.55; Test vorhanden: nein (0.44); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:290`
  - Einwand des Evidenz-Sammlers: #1154: Source/SocketIO/Client/SocketIOClient.swift:290 — Calling connect() while already connected is explicitly guarded and ignored, tested by testConnectDoesNotTimeOutIfConnected and matching JS socket.connect() behavior (matches_js_client), not a defect.
- [#1513](https://github.com/socketio/socket.io-client-swift/issues/1513) (issue, open, 2025) **Socket is not getting connect when coming from background to foreground** — noch zutreffend 0.52; Test vorhanden: nein (0.02); Priorität Important; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:282`
- [#139](https://github.com/socketio/socket.io-client-swift/issues/139) (issue, closed, 2015) **Closing socket** — noch zutreffend 0.49; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:583`
  - Einwand des Evidenz-Sammlers: #139: Source/SocketIO/Client/SocketIOClient.swift:583 — Jev classified this as still_applicable, but delayed close on app exit is caused by iOS process suspension requiring application-side background task execution rather than library code, and the removed Objective-C closeWithFast API is obsolete, making this not_applicable.
- [#1219](https://github.com/socketio/socket.io-client-swift/issues/1219) (issue, closed, 2019) **EXC_BAD_ACCESS KERN_INVALID_ADDRESS Crash** — noch zutreffend 0.43; Test vorhanden: nein (0.06); Priorität Important; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:84`
  - Einwand des Evidenz-Sammlers: #1219: Source/SocketIO/Ack/SocketAckManager.swift:84 contradicts still_applicable; the crash in Set._Variant.remove(_:) during SocketAckManager.executeAck was caused by unsynchronized access to the acks Set from caller threads, which is now guarded by NSLock in both addAck and executeAck.
- [#1353](https://github.com/socketio/socket.io-client-swift/issues/1353) (issue, open, 2021) **Socket.io v16.0.0-16.0.1 emit event twice?** — noch zutreffend 0.40; Test vorhanden: nein (0.30); Priorität Important; Evidenz: `Tests/TestSocketIO/SocketAnyListenersTest.swift:78`
  - Einwand des Evidenz-Sammlers: #1353: Source/SocketIO/Client/SocketIOClient.swift:416 — `dispatchEvent` invokes `anyHandler` only once per received event, verified by `Tests/TestSocketIO/SocketAnyListenersTest.swift:82`.
- [#1473](https://github.com/socketio/socket.io-client-swift/pull/1473) (pr, closed, nicht gemergt, 2024) **Improved websocket reconnection logic** — noch zutreffend 0.40; Test vorhanden: nein (0.07); Priorität Important; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:44`
  - Einwand des Evidenz-Sammlers: #1473: Source/SocketIO/Engine/SocketEngine.swift:186 — Jev evaluated still_applicable, but in Engine.IO v4 the heartbeat is server-driven (server ping, client pong) matching JavaScript client parity, while probe timeout (webSocketProbeTimeout = 10) and handshake timeout (connectTimeout = 20) are already implemented.
- [#1055](https://github.com/socketio/socket.io-client-swift/issues/1055) (issue, closed, 2018) **SocketIO logs show connected but emit refuses** — noch zutreffend 0.39; Test vorhanden: nein (0.05); Priorität Important; Evidenz: `none`
  - Einwand des Evidenz-Sammlers: #1055: Source/SocketIO/Manager/SocketManager.swift:1151 contradicts still_applicable; the reported failure is caused by application-side code misusing the API (instantiating an unmanaged SocketIOClient with invalid namespace "" not registered in manager.nsps, alongside removed option .compress), and disconnected emits are now buffered in Source/SocketIO/Client/SocketIOClient.swift:930 rather than dropped.
- [#1374](https://github.com/socketio/socket.io-client-swift/issues/1374) (issue, open, 2021) **SocketIOClient always return connected status when the internet has shutdown** — noch zutreffend 0.36; Test vorhanden: nein (0.33); Priorität Important; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:823`
  - Einwand des Evidenz-Sammlers: #1374: Source/SocketIO/Engine/SocketEngine.swift:820-835 implements Engine.IO heartbeat ping/pong expiration (`pingInterval + pingTimeout`) to close with "ping timeout", matching JavaScript engine.io-client socket.ts:660-670; an unnotified network drop cannot immediately update connection state prior to heartbeat expiry, so this reflects expected protocol parity (matches_js_client) rather than an unaddressed defect (still_applicable).
- [#249](https://github.com/socketio/socket.io-client-swift/issues/249) (issue, open, 2015) **Linux Port** — noch zutreffend 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Package.swift:6`
- [#952](https://github.com/socketio/socket.io-client-swift/issues/952) (issue, open, 2018) **Decode responses to Struct via Codable** — noch zutreffend 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Util/SocketTypes.swift:77`
- [#1013](https://github.com/socketio/socket.io-client-swift/issues/1013) (issue, open, 2018) **Question about feature, or possible suggestion** — noch zutreffend 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1548`
- [#1150](https://github.com/socketio/socket.io-client-swift/issues/1150) (issue, open, 2019) **Custom parser for iOS app** — noch zutreffend 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClientOption.swift:174`
- [#1476](https://github.com/socketio/socket.io-client-swift/pull/1476) (pr, closed, nicht gemergt, 2024) **Thread safe handlers** — noch zutreffend 0.95; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:71`
- [#885](https://github.com/socketio/socket.io-client-swift/issues/885) (issue, closed, 2017) **Need off method that accepts a callback reference** — noch zutreffend 0.92; Test vorhanden: nein (0.06); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:63`
  - Einwand des Evidenz-Sammlers: #885: Source/SocketIO/Client/SocketIOClient.swift:63 — Jev evaluated still_applicable, but Swift closures lack stable identity by design, making callback-reference off impossible; listener unregistration is deliberately UUID-keyed via off(id:).
- [#470](https://github.com/socketio/socket.io-client-swift/issues/470) (issue, closed, 2016) **Possibility to reconnect with a different URL** — noch zutreffend 0.87; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:62`
  - Einwand des Evidenz-Sammlers: #470: Source/SocketIO/Manager/SocketManager.swift:62 — Jev classified this as still_applicable, but in both the fork (let socketURL) and the reference JS client (readonly uri in manager.ts:124), URLs are immutable and transferring handlers across instances is not supported, matching JS client parity.
- [#216](https://github.com/socketio/socket.io-client-swift/issues/216) (issue, closed, 2015) **Add 'off()' and 'removeAllHandlers()' to readme** — noch zutreffend 0.85; Test vorhanden: ja (0.68); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1712`
- [#1365](https://github.com/socketio/socket.io-client-swift/issues/1365) (issue, open, 2021) **Add completion handler to SocketIOClient connect, disconnect, and emit methods** — noch zutreffend 0.68; Test vorhanden: nein (0.30); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:286`
- [#1336](https://github.com/socketio/socket.io-client-swift/issues/1336) (issue, open, 2021) **Idea: Improve release notes for 16.x (Link to upgrading notes?)** — noch zutreffend 0.63; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `CHANGELOG.md:19`
  - Einwand des Evidenz-Sammlers: #1336: CHANGELOG.md:19 and Documentation/SocketIO4Swift6Migration.md:16 show 16.x documentation, historical migration guides (15to16.html), and the .version(.two) option were explicitly removed in 17.0.0, making updating 16.x release notes not_applicable rather than still_applicable.
- [#1259](https://github.com/socketio/socket.io-client-swift/issues/1259) (issue, open, 2020) **Protobuf** — noch zutreffend 0.61; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `none`
  - Einwand des Evidenz-Sammlers: #1259 | none | Requesting a Protobuf demo concerns application-side serialization code rather than library functionality, making it not_applicable.
- [#54](https://github.com/socketio/socket.io-client-swift/issues/54) (issue, closed, 2015) **Using this client with self signed certificates** — noch zutreffend 0.57; Test vorhanden: nein (0.06); Priorität Routine; Evidenz: `Source/SocketIO/Security/SocketTLSConfiguration.swift:16`
  - Einwand des Evidenz-Sammlers: #54: Source/SocketIO/Security/SocketSessionDelegateProxy.swift:10 — Jev classified this as still_applicable, but passing an external delegate to bypass server trust for self-signed certificates was intentionally deprecated and blocked in favor of explicit SocketTLSConfiguration.customTrust anchors, and legacy .selfSigned was removed.
- [#1511](https://github.com/socketio/socket.io-client-swift/pull/1511) (pr, open, nicht gemergt, 2025) **Android** — noch zutreffend 0.57; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `none`
  - Einwand des Evidenz-Sammlers: #1511 | Package.swift:6 | Jev returned still_applicable, but the fork supports only Apple platforms (iOS, macOS, tvOS, watchOS) and the PR patches removed Starscream engine components, making it not_applicable.
- [#690](https://github.com/socketio/socket.io-client-swift/issues/690) (issue, closed, 2017) **Can the user-agent to configure it by yourself** — noch zutreffend 0.54; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngineSpec.swift:250`
  - Einwand des Evidenz-Sammlers: #690: Source/SocketIO/Engine/SocketEngineSpec.swift:250 — Jev evaluated still_applicable, but configuring User-Agent is supported via .extraHeaders(["User-Agent": ...]), which sets HTTP headers on the URLRequest.
- [#927](https://github.com/socketio/socket.io-client-swift/pull/927) (pr, closed, nicht gemergt, 2018) **fix insert invoked twice** — noch zutreffend 0.54; Test vorhanden: nein (0.06); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:237`
  - Einwand des Evidenz-Sammlers: #927: Source/SocketIO/Manager/SocketManager.swift:237 — self._config.insert(.path("/socket.io/"), replacing: false) was removed from init() and only runs once in setConfigs(), so the duplicate insertion is already resolved (already_addressed).
- [#336](https://github.com/socketio/socket.io-client-swift/issues/336) (issue, closed, 2016) **Is there any way where we can Observer (KVO) the status property of SocketIOClient ?** — noch zutreffend 0.52; Test vorhanden: nein (0.27); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:88`
  - Einwand des Evidenz-Sammlers: #336: Source/SocketIO/Client/SocketIOClient.swift:90 — Jev classified this as still_applicable, but KVO is an Objective-C runtime feature incompatible with the fork's removal of Objective-C support (CHANGELOG.md:150); status observation is provided via the .statusChange client event.
- [#1498](https://github.com/socketio/socket.io-client-swift/issues/1498) (issue, open, 2024) **"The operation couldn’t be completed. (SocketIO.EngineError error 0.)"** — noch zutreffend 0.51; Test vorhanden: nein (0.14); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:1332`
  - Einwand des Evidenz-Sammlers: #1498: Source/SocketIO/Engine/SocketEngine.swift:1332 contradicts still_applicable; EngineError.canceled (error 0) is dead code never instantiated or thrown in the fork, inactive sockets ignore engine errors (Source/SocketIO/Manager/SocketManager.swift:639), and quick reconnect tests in Tests/TestSocketIO/SocketPollingCloseTest.swift:487 and :517 verify client.errors remains empty.
- [#1391](https://github.com/socketio/socket.io-client-swift/issues/1391) (issue, open, 2021) **Compatibility table link does not work** — noch zutreffend 0.47; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Usage Docs/Compatibility.md:1`
  - Einwand des Evidenz-Sammlers: #1391 | Usage Docs/Compatibility.md:1 | The broken external compatibility table link was resolved by embedding compatibility tables directly in README.md:31 and Usage Docs/Compatibility.md, making it already_addressed.

### Unzureichende Evidenz (32)

Weder Fork-Code noch Item-Text erlaubten ein Urteil; hier hilft nur manuelle Prüfung oder ein Repro.

- [#385](https://github.com/socketio/socket.io-client-swift/issues/385) (issue, open, 2016) **Sometimes emit method is not working on connect** — Unzureichende Evidenz 0.53; Test vorhanden: nein (0.05); Priorität High; Evidenz: `none`
- [#83](https://github.com/socketio/socket.io-client-swift/issues/83) (issue, closed, 2015) **event is emited twice** — Unzureichende Evidenz 0.99; Test vorhanden: nein (0.03); Priorität Important; Evidenz: `none`
- [#650](https://github.com/socketio/socket.io-client-swift/issues/650) (issue, closed, 2017) **我会监听到多次一样的推送，怎么回事** — Unzureichende Evidenz 0.98; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `none`
- [#235](https://github.com/socketio/socket.io-client-swift/issues/235) (issue, closed, 2015) **Crashes on SocketEventHandler.executeCallback** — Unzureichende Evidenz 0.92; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `none`
- [#1363](https://github.com/socketio/socket.io-client-swift/issues/1363) (issue, open, 2021) **Not Receiving Private Events for Subscribed Channels** — Unzureichende Evidenz 0.91; Test vorhanden: nein (0.03); Priorität Important; Evidenz: `none`
- [#1497](https://github.com/socketio/socket.io-client-swift/issues/1497) (issue, open, 2024) **Socket stopped listening event after 30 to 40 mins** — Unzureichende Evidenz 0.80; Test vorhanden: nein (0.03); Priorität Important; Evidenz: `none`
- [#536](https://github.com/socketio/socket.io-client-swift/issues/536) (issue, closed, 2016) **UnsafeMutablePointer.moveInitializeFrom with negative count** — Unzureichende Evidenz 0.69; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `README.md:5`
  - Einwand des Evidenz-Sammlers: #536: README.md:5 and Documentation/NativeWebSocketTransport.md:33 contradict insufficient_evidence; the UnsafeMutablePointer crash occurred in Starscream's NSStream buffer implementation, which was completely removed in favor of URLSessionWebSocketTask, making the issue not_applicable.
- [#1163](https://github.com/socketio/socket.io-client-swift/issues/1163) (issue, open, 2019) **Socket event not connect after disconnect** — Unzureichende Evidenz 0.62; Test vorhanden: nein (0.14); Priorität Important; Evidenz: `none`
- [#1455](https://github.com/socketio/socket.io-client-swift/issues/1455) (issue, open, 2023) **Socket io gives a connection error when connecting back from going to background** — Unzureichende Evidenz 0.60; Test vorhanden: nein (0.07); Priorität Important; Evidenz: `none`
- [#1401](https://github.com/socketio/socket.io-client-swift/issues/1401) (issue, open, 2022) **App crash when connecting to socket** — Unzureichende Evidenz 0.57; Test vorhanden: nein (0.03); Priorität Important; Evidenz: `none`
- [#1520](https://github.com/socketio/socket.io-client-swift/pull/1520) (pr, open, nicht gemergt, 2025) **Adding missing error event** — Unzureichende Evidenz 0.50; Test vorhanden: nein (0.03); Priorität Important; Evidenz: `none`
  - Einwand des Evidenz-Sammlers: #1520 | README.md:5 | Jev returned insufficient_evidence, but Starscream and its error types (WSError, HTTPUpgradeError) were completely removed in favor of native URLSessionWebSocketTask, making the PR not_applicable.
- [#846](https://github.com/socketio/socket.io-client-swift/issues/846) (issue, closed, 2017) **swift ios存在漏接收数据的情况** — Unzureichende Evidenz 0.44; Test vorhanden: nein (0.05); Priorität Important; Evidenz: `none`
- [#1242](https://github.com/socketio/socket.io-client-swift/issues/1242) (issue, closed, 2019) **I need open  #1156， this bug** — Unzureichende Evidenz 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1251](https://github.com/socketio/socket.io-client-swift/issues/1251) (issue, closed, 2019) **iOS13 15.2.0 Crash!** — Unzureichende Evidenz 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1264](https://github.com/socketio/socket.io-client-swift/issues/1264) (issue, open, 2020) **Sometime emitting getting failed and seems like socket get stuck on request** — Unzureichende Evidenz 1.00; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `none`
- [#1346](https://github.com/socketio/socket.io-client-swift/issues/1346) (issue, open, 2021) **Crash inside the SocketIOClient** — Unzureichende Evidenz 1.00; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#638](https://github.com/socketio/socket.io-client-swift/issues/638) (issue, open, 2017) **Update the latest version can not submit parameters and receive the return data** — Unzureichende Evidenz 0.97; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1345](https://github.com/socketio/socket.io-client-swift/issues/1345) (issue, open, 2021) **event socket.on not recieve data, but in log in socket data is recieved** — Unzureichende Evidenz 0.96; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#589](https://github.com/socketio/socket.io-client-swift/issues/589) (issue, closed, 2016) **Socket is not working in 3G always reconnects coming** — Unzureichende Evidenz 0.93; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `none`
- [#1172](https://github.com/socketio/socket.io-client-swift/issues/1172) (issue, open, 2019) **Few events are not called but connection is made properly** — Unzureichende Evidenz 0.92; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `none`
- [#403](https://github.com/socketio/socket.io-client-swift/issues/403) (issue, open, 2016) **Network connection was lost** — Unzureichende Evidenz 0.86; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `none`
- [#1239](https://github.com/socketio/socket.io-client-swift/issues/1239) (issue, closed, 2019) **crash ：App init (SocketEngine.swift:)** — Unzureichende Evidenz 0.86; Test vorhanden: nein (0.02); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:39`
- [#1226](https://github.com/socketio/socket.io-client-swift/issues/1226) (issue, closed, 2019) **swift：disconnect method Can't disconnect from server** — Unzureichende Evidenz 0.83; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1320](https://github.com/socketio/socket.io-client-swift/pull/1320) (pr, open, nicht gemergt, 2020) **Combine support** — Unzureichende Evidenz 0.80; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#615](https://github.com/socketio/socket.io-client-swift/issues/615) (issue, closed, 2017) **Upload Image/Video via stream using Socket.io-stream server** — Unzureichende Evidenz 0.77; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1162](https://github.com/socketio/socket.io-client-swift/issues/1162) (issue, open, 2019) **I use this socket. io-client-swift (the latest version of 14.0.0) to do chat function, always appear for a period of time, then the problem of disconnection, God knows what happened?** — Unzureichende Evidenz 0.76; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `none`
- [#671](https://github.com/socketio/socket.io-client-swift/pull/671) (pr, closed, nicht gemergt, 2017) **v9.0** — Unzureichende Evidenz 0.68; Test vorhanden: nein (0.05); Priorität Routine; Evidenz: `none`
  - Einwand des Evidenz-Sammlers: #671: Source/SocketIO/Engine/SocketEngine.swift:39 — Jev evaluated insufficient_evidence, but the v9.0 refactoring symbols from #671 (engineQueue, SocketEngineSpec, SocketEnginePollable, SocketIOClientOption) are already implemented in the fork.
- [#922](https://github.com/socketio/socket.io-client-swift/issues/922) (issue, closed, 2018) **Apple Watch constant `Connecting` status** — Unzureichende Evidenz 0.63; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1243](https://github.com/socketio/socket.io-client-swift/issues/1243) (issue, closed, 2019) **I need open  #1156,This bug still exists with `Multiple Reconnect` and `Multiple Connect`** — Unzureichende Evidenz 0.60; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:282`
- [#670](https://github.com/socketio/socket.io-client-swift/issues/670) (issue, closed, 2017) **Jazzy documentaion** — Unzureichende Evidenz 0.44; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`
- [#1380](https://github.com/socketio/socket.io-client-swift/issues/1380) (issue, open, 2021) **Emit doesn't work** — Unzureichende Evidenz 0.43; Test vorhanden: nein (0.07); Priorität Routine; Evidenz: `none`
- [#1223](https://github.com/socketio/socket.io-client-swift/issues/1223) (issue, closed, 2019) **Causes the URLSession dataTask request to be unresponsive** — Unzureichende Evidenz 0.40; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `none`

### Entspricht dem JS-Client (30)

- [#1415](https://github.com/socketio/socket.io-client-swift/issues/1415) (issue, open, 2022) **Socket `disconnect` not fired when device loses network** — entspricht JS-Client 0.79; Test vorhanden: nein (0.04); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:823`
- [#613](https://github.com/socketio/socket.io-client-swift/issues/613) (issue, open, 2017) **{"code":1,"message":"Session ID unknown"} while connecting users to socket.io for first attempt.** — entspricht JS-Client 0.81; Test vorhanden: ja (0.55); Priorität Important; Evidenz: `Tests/TestSocketIO/E2E/EngineRemainingParityE2ETest.swift:406`
- [#22](https://github.com/socketio/socket.io-client-swift/issues/22) (issue, closed, 2015) **Event on "connect" not called** — entspricht JS-Client 0.71; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:526`
- [#1053](https://github.com/socketio/socket.io-client-swift/issues/1053) (issue, closed, 2018) **Not getting Disconnect event when network dosconnects** — entspricht JS-Client 0.71; Test vorhanden: nein (0.05); Priorität Important; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:820`
- [#367](https://github.com/socketio/socket.io-client-swift/issues/367) (issue, closed, 2016) **Escape issue** — entspricht JS-Client 0.67; Test vorhanden: ja (0.53); Priorität Important; Evidenz: `Tests/TestSocketIO/SocketEngineURLParityTest.swift:74`
- [#517](https://github.com/socketio/socket.io-client-swift/issues/517) (issue, closed, 2016) **How to cancel in-flight emitWithAck** — entspricht JS-Client 0.64; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1736`
- [#300](https://github.com/socketio/socket.io-client-swift/issues/300) (issue, closed, 2016) **Reconnecting gets called a lot.** — entspricht JS-Client 0.57; Test vorhanden: ja (0.59); Priorität Important; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:681`
- [#838](https://github.com/socketio/socket.io-client-swift/issues/838) (issue, closed, 2017) **Asyncronous send and receive** — entspricht JS-Client 0.51; Test vorhanden: nein (0.04); Priorität Important; Evidenz: `Source/SocketIO/Client/SocketIOClientOption.swift:121`
- [#1466](https://github.com/socketio/socket.io-client-swift/issues/1466) (issue, open, 2023) **LOG SocketManager: Tried connecting an already active socket** — entspricht JS-Client 0.32; Test vorhanden: nein (0.29); Priorität Important; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:282`
- [#144](https://github.com/socketio/socket.io-client-swift/pull/144) (pr, closed, nicht gemergt, 2015) **Clear waiting data on reconnect (like JS does)** — entspricht JS-Client 0.96; Test vorhanden: nein (0.29); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:186`
- [#413](https://github.com/socketio/socket.io-client-swift/issues/413) (issue, closed, 2016) **SSL + base64 = wrong base64 received by server** — entspricht JS-Client 0.95; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEnginePollable.swift:150`
- [#1262](https://github.com/socketio/socket.io-client-swift/issues/1262) (issue, open, 2020) **No elapsed time (latency) in pong event** — entspricht JS-Client 0.95; Test vorhanden: nein (0.35); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:725`
- [#1167](https://github.com/socketio/socket.io-client-swift/issues/1167) (issue, open, 2019) **manager .disconnect () fail** — entspricht JS-Client 0.94; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:459`
- [#1389](https://github.com/socketio/socket.io-client-swift/issues/1389) (issue, open, 2021) **Timestamp sometimes Int and sometimes String** — entspricht JS-Client 0.90; Test vorhanden: nein (0.06); Priorität Routine; Evidenz: `Source/SocketIO/Parse/SocketParsable.swift:176`
- [#245](https://github.com/socketio/socket.io-client-swift/issues/245) (issue, closed, 2015) **SocketEngine message parser problem** — entspricht JS-Client 0.88; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Parse/SocketParsable.swift:122`
- [#1392](https://github.com/socketio/socket.io-client-swift/issues/1392) (issue, open, 2021) **error with data: [Invalid namespace]** — entspricht JS-Client 0.84; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1477`
- [#1213](https://github.com/socketio/socket.io-client-swift/pull/1213) (pr, closed, nicht gemergt, 2019) **Auto detect which protocol to use depend on url scheme** — entspricht JS-Client 0.80; Test vorhanden: nein (0.34); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:211`
- [#1214](https://github.com/socketio/socket.io-client-swift/pull/1214) (pr, closed, nicht gemergt, 2019) **Auto detect which protocol to use depend on url scheme** — entspricht JS-Client 0.80; Test vorhanden: nein (0.35); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:211`
- [#1321](https://github.com/socketio/socket.io-client-swift/issues/1321) (issue, closed, 2021) **Can we receive event arguments as a raw string, to parse into a Swift struct using codable** — entspricht JS-Client 0.79; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Parse/SocketParsable.swift:176`
- [#488](https://github.com/socketio/socket.io-client-swift/issues/488) (issue, closed, 2016) **Send request body when connecting socket** — entspricht JS-Client 0.78; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:421`
- [#1423](https://github.com/socketio/socket.io-client-swift/issues/1423) (issue, open, 2022) **Behaviour change: connect on manager** — entspricht JS-Client 0.78; Test vorhanden: nein (0.38); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:281`
- [#571](https://github.com/socketio/socket.io-client-swift/issues/571) (issue, closed, 2016) **Can't emit a dictionary** — entspricht JS-Client 0.75; Test vorhanden: ja (0.73); Priorität Routine; Evidenz: `Tests/TestSocketIO/SocketBasicPacketTest.swift:49`
- [#639](https://github.com/socketio/socket.io-client-swift/issues/639) (issue, open, 2017) **SocketIO crash when server disconnect client** — entspricht JS-Client 0.73; Test vorhanden: nein (0.28); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1470`
- [#1208](https://github.com/socketio/socket.io-client-swift/issues/1208) (issue, closed, 2019) **Outgoing port** — entspricht JS-Client 0.72; Test vorhanden: nein (0.03); Priorität Routine; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:444`
- [#200](https://github.com/socketio/socket.io-client-swift/issues/200) (issue, closed, 2015) **Event handler data argument - [AnyObject] vs AnyObject** — entspricht JS-Client 0.67; Test vorhanden: ja (0.59); Priorität Routine; Evidenz: `Source/SocketIO/Util/SocketTypes.swift:80`
- [#1322](https://github.com/socketio/socket.io-client-swift/issues/1322) (issue, closed, 2021) **Can we receive event arguments as raw strings, to then parse into Swift structs using Codable?** — entspricht JS-Client 0.66; Test vorhanden: nein (0.04); Priorität Routine; Evidenz: `Source/SocketIO/Parse/SocketParsable.swift:176`
- [#684](https://github.com/socketio/socket.io-client-swift/issues/684) (issue, closed, 2017) **How to include a custom authentication token AFTER connect** — entspricht JS-Client 0.65; Test vorhanden: ja (0.65); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:1131`
- [#724](https://github.com/socketio/socket.io-client-swift/issues/724) (issue, closed, 2017) **When not set nps,socket only send type 4 and not bussiness data** — entspricht JS-Client 0.56; Test vorhanden: nein (0.36); Priorität Routine; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:54`
- [#210](https://github.com/socketio/socket.io-client-swift/issues/210) (issue, closed, 2015) **Joining a namespace needs a Ack option.** — entspricht JS-Client 0.55; Test vorhanden: nein (0.17); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:923`
- [#870](https://github.com/socketio/socket.io-client-swift/issues/870) (issue, closed, 2017) **Raw Messages** — entspricht JS-Client 0.47; Test vorhanden: nein (0.43); Priorität Routine; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:777`

### Im Fork bereits adressiert (131)

Nur Items mit Priorität High oder Critical werden aufgeführt, weil sie zeigen, welche historischen Upstream-Fehler der Fork mit Test abdeckt und welche ohne Test.

- [#1290](https://github.com/socketio/socket.io-client-swift/issues/1290) (issue, open, 2020) **Pointer being freed was not allocated | Random Crash** — im Fork bereits adressiert 0.52; Test vorhanden: nein (0.06); Priorität Critical; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:68`
- [#45](https://github.com/socketio/socket.io-client-swift/issues/45) (issue, closed, 2015) **emit error event when the socket is denied by the server.** — im Fork bereits adressiert 0.67; Test vorhanden: ja (0.92); Priorität High; Evidenz: `Tests/TestSocketIO/E2E/JSParityE2ETest.swift:108`
- [#193](https://github.com/socketio/socket.io-client-swift/issues/193) (issue, closed, 2015) **Possible crash when closing connection** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.64); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:296`
- [#279](https://github.com/socketio/socket.io-client-swift/issues/279) (issue, closed, 2016) **Reconnect cannot reconnect because already connected** — im Fork bereits adressiert 0.99; Test vorhanden: ja (0.80); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:386`
- [#301](https://github.com/socketio/socket.io-client-swift/issues/301) (issue, closed, 2016) **Unknown Crash** — im Fork bereits adressiert 1.00; Test vorhanden: nein (0.34); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEnginePollable.swift:208`
- [#355](https://github.com/socketio/socket.io-client-swift/issues/355) (issue, closed, 2016) **SocketEnginePollable Crash Sometimes** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.88); Priorität High; Evidenz: `Tests/TestSocketIO/SocketPollingCloseTest.swift:574`
- [#356](https://github.com/socketio/socket.io-client-swift/issues/356) (issue, open, 2016) **SocketEnginePollable Crash Sometimes** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.86); Priorität High; Evidenz: `Tests/TestSocketIO/SocketPollingCloseTest.swift:574`
- [#448](https://github.com/socketio/socket.io-client-swift/issues/448) (issue, closed, 2016) **App crashes when I receive huge data from server** — im Fork bereits adressiert 0.98; Test vorhanden: nein (0.36); Priorität High; Evidenz: `Source/SocketIO/Engine/Transport/SocketWebSocketOptions.swift:11`
- [#521](https://github.com/socketio/socket.io-client-swift/issues/521) (issue, closed, 2016) **Crash problem** — im Fork bereits adressiert 1.00; Test vorhanden: nein (0.04); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:564`
- [#549](https://github.com/socketio/socket.io-client-swift/issues/549) (issue, closed, 2016) **Crash due to race condition in SocketEngine.createWebsocketAndConnect** — im Fork bereits adressiert 0.97; Test vorhanden: nein (0.03); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngine.swift:379`
- [#565](https://github.com/socketio/socket.io-client-swift/issues/565) (issue, open, 2016) **acknowledgement times out on simulatneous multiple socket.emitwithack or socket.onany** — im Fork bereits adressiert 0.89; Test vorhanden: nein (0.15); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:2036`
- [#583](https://github.com/socketio/socket.io-client-swift/issues/583) (issue, closed, 2016) **fatal error: cannot increment beyond endIndex** — im Fork bereits adressiert 0.62; Test vorhanden: nein (0.46); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEnginePacketCodec.swift:54`
- [#620](https://github.com/socketio/socket.io-client-swift/pull/620) (pr, closed, nicht gemergt, 2017) **synchronized call to mutating ackHandlers.executeAck** — im Fork bereits adressiert 0.42; Test vorhanden: nein (0.14); Priorität High; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:113`
- [#621](https://github.com/socketio/socket.io-client-swift/pull/621) (pr, closed, nicht gemergt, 2017) **Thread safety issues** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.90); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:140`
- [#677](https://github.com/socketio/socket.io-client-swift/issues/677) (issue, closed, 2017) **Errors in SocketData should be reported to the users.** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.94); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:629`
- [#716](https://github.com/socketio/socket.io-client-swift/issues/716) (issue, closed, 2017) **Crash when server returns "404: Not Found"** — im Fork bereits adressiert 0.48; Test vorhanden: nein (0.04); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEnginePollable.swift:236`
- [#722](https://github.com/socketio/socket.io-client-swift/issues/722) (issue, closed, 2017) **Crash in SocketAckManager with version 10.0.0** — im Fork bereits adressiert 0.99; Test vorhanden: nein (0.02); Priorität High; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:68`
- [#1096](https://github.com/socketio/socket.io-client-swift/issues/1096) (issue, closed, 2018) **Feature Request: completion handler for writes** — im Fork bereits adressiert 0.97; Test vorhanden: ja (0.83); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClientSpec.swift:112`
- [#1156](https://github.com/socketio/socket.io-client-swift/issues/1156) (issue, closed, 2019) **Connect  / disconnect loop** — im Fork bereits adressiert 1.00; Test vorhanden: ja (0.64); Priorität High; Evidenz: `Tests/TestSocketIO/SocketNativeEngineTest.swift:341`
- [#1183](https://github.com/socketio/socket.io-client-swift/issues/1183) (issue, open, 2019) **Client called Connect first, then called Error when server throw next(error). Why connect was still called when server already throw a error?** — im Fork bereits adressiert 0.52; Test vorhanden: ja (0.75); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1484`
- [#1191](https://github.com/socketio/socket.io-client-swift/issues/1191) (issue, open, 2019) **Loosing extraHeaders when locking - unlocking device twice** — im Fork bereits adressiert 0.52; Test vorhanden: nein (0.37); Priorität High; Evidenz: `Source/SocketIO/Engine/SocketEngineSpec.swift:248`
- [#1193](https://github.com/socketio/socket.io-client-swift/issues/1193) (issue, open, 2019) **handleAck crash** — im Fork bereits adressiert 0.95; Test vorhanden: ja (0.56); Priorität High; Evidenz: `Source/SocketIO/Ack/SocketAckManager.swift:84`
- [#1194](https://github.com/socketio/socket.io-client-swift/issues/1194) (issue, open, 2019) **SocketIOClient Triggers `connect` event too early** — im Fork bereits adressiert 0.51; Test vorhanden: nein (0.47); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:1460`
- [#1255](https://github.com/socketio/socket.io-client-swift/issues/1255) (issue, open, 2019) **"Tried emitting when not connected" while being actually connected** — im Fork bereits adressiert 0.56; Test vorhanden: ja (0.60); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:923`
- [#1282](https://github.com/socketio/socket.io-client-swift/issues/1282) (issue, open, 2020) **reconnect not disabled after disconnect** — im Fork bereits adressiert 0.60; Test vorhanden: nein (0.05); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:503`
- [#1297](https://github.com/socketio/socket.io-client-swift/issues/1297) (issue, open, 2020) **Extract namespace and query parameters from SocketManager URL** — im Fork bereits adressiert 0.86; Test vorhanden: nein (0.43); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:54`
  - Einwand des Evidenz-Sammlers: #1297: Source/SocketIO/Manager/SocketManager.swift:54 — while URL query parameter extraction was implemented in SocketEngine, extracting the namespace from the URL path was not implemented (defaultSocket is hardcoded to "/" and custom namespaces must be selected explicitly via socket(forNamespace:)).
- [#1301](https://github.com/socketio/socket.io-client-swift/issues/1301) (issue, closed, 2020) **Handlers not called except for event '.webSocketUpgrade'** — im Fork bereits adressiert 0.47; Test vorhanden: nein (0.10); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:326`
  - Einwand des Evidenz-Sammlers: #1301: Source/SocketIO/Engine/SocketEngine.swift:523 — Jev classified this as already_addressed (0.47 vs still_applicable 0.40), but emitting .websocketUpgrade without .connect when a server completes the WebSocket handshake without sending an Engine.IO handshake is by-design protocol behavior (and application-side endpoint misconfiguration), though Source/SocketIO/Manager/SocketManager.swift:326 now prevents indefinite hangs via connectTimeout.
- [#1403](https://github.com/socketio/socket.io-client-swift/issues/1403) (issue, open, 2022) **websocket 重连错误，  guard !status.active else 第一次之后，永远return** — im Fork bereits adressiert 0.91; Test vorhanden: nein (0.45); Priorität High; Evidenz: `Source/SocketIO/Manager/SocketManager.swift:282`
- [#1422](https://github.com/socketio/socket.io-client-swift/issues/1422) (issue, open, 2022) **Connecting to the server with nginx load balancer sends socket.io iOS client into reconnection spiral** — im Fork bereits adressiert 0.43; Test vorhanden: nein (0.44); Priorität High; Evidenz: `Tests/TestSocketIO/SocketReconnectEventsTest.swift:279`
- [#1525](https://github.com/socketio/socket.io-client-swift/pull/1525) (pr, open, nicht gemergt, 2025) **Add socketio connection state recovery** — im Fork bereits adressiert 0.94; Test vorhanden: ja (0.52); Priorität High; Evidenz: `Source/SocketIO/Client/SocketIOClient.swift:125`

### Nicht gemergte Upstream-PRs mit Verhaltensänderung

| PR | Titel | Stufe 1 | Stufe 2 | Priorität |
| --- | --- | --- | --- | --- |
| [#18](https://github.com/socketio/socket.io-client-swift/pull/18) | updated parsing to better handle acks | PR mit Verhaltensänderung 0.56 | im Fork bereits adressiert 0.99 | Routine |
| [#112](https://github.com/socketio/socket.io-client-swift/pull/112) | emit dictionary in Objective-C | PR mit Verhaltensänderung 0.52 | nicht anwendbar 0.96 | Routine |
| [#144](https://github.com/socketio/socket.io-client-swift/pull/144) | Clear waiting data on reconnect (like JS does) | PR mit Verhaltensänderung 0.39 | entspricht JS-Client 0.96 | Routine |
| [#159](https://github.com/socketio/socket.io-client-swift/pull/159) | Fix secure option issue | PR mit Verhaltensänderung 0.35 | im Fork bereits adressiert 0.77 | Important |
| [#211](https://github.com/socketio/socket.io-client-swift/pull/211) | Improve initial options | PR mit Verhaltensänderung 0.68 | im Fork bereits adressiert 0.96 | Routine |
| [#213](https://github.com/socketio/socket.io-client-swift/pull/213) | Real type save | PR mit Verhaltensänderung 0.79 | im Fork bereits adressiert 0.77 | Routine |
| [#262](https://github.com/socketio/socket.io-client-swift/pull/262) | Avoid doing unaligned reads/writes via UnsafePointer | PR mit Verhaltensänderung 0.46 | nicht anwendbar 1.00 | Routine |
| [#343](https://github.com/socketio/socket.io-client-swift/pull/343) | Websocket compression [DONT MERGE] | PR mit Verhaltensänderung 0.96 | im Fork bereits adressiert 0.50 | Routine |
| [#349](https://github.com/socketio/socket.io-client-swift/pull/349) | How to know how many events i have registered? | Feature-Wunsch 0.81 | im Fork bereits adressiert 0.55 | Routine |
| [#380](https://github.com/socketio/socket.io-client-swift/pull/380) | Add Proxy support for websocket | PR mit Verhaltensänderung 0.75 | nicht anwendbar 0.62 | Routine |
| [#418](https://github.com/socketio/socket.io-client-swift/pull/418) | Upgraded to Swift 3.0 | PR mit Verhaltensänderung 0.40 | nicht anwendbar 0.87 | Routine |
| [#489](https://github.com/socketio/socket.io-client-swift/pull/489) | Propagate websocket connected event to SocketIOClientStatus when force | PR mit Verhaltensänderung 0.51 | im Fork bereits adressiert 0.38 | Important |
| [#515](https://github.com/socketio/socket.io-client-swift/pull/515) | Fix crash | Defekt, potenziell aktuell 0.42 | nicht anwendbar 0.98 | Routine |
| [#520](https://github.com/socketio/socket.io-client-swift/pull/520) | Update SSLSecurity.swift | PR mit Verhaltensänderung 0.71 | nicht anwendbar 0.99 | Routine |
| [#524](https://github.com/socketio/socket.io-client-swift/pull/524) | change sslsecurity and isvalid to open | PR mit Verhaltensänderung 0.54 | nicht anwendbar 0.99 | Routine |
| [#572](https://github.com/socketio/socket.io-client-swift/pull/572) | Non array data | PR mit Verhaltensänderung 0.84 | im Fork bereits adressiert 0.82 | Routine |
| [#620](https://github.com/socketio/socket.io-client-swift/pull/620) | synchronized call to mutating ackHandlers.executeAck | Defekt, potenziell aktuell 0.51 | im Fork bereits adressiert 0.42 | High |
| [#621](https://github.com/socketio/socket.io-client-swift/pull/621) | Thread safety issues | Defekt, potenziell aktuell 0.45 | im Fork bereits adressiert 1.00 | High |
| [#666](https://github.com/socketio/socket.io-client-swift/pull/666) | Update SocketIOClient.swift | PR mit Verhaltensänderung 0.71 | nicht anwendbar 0.56 | Routine |
| [#669](https://github.com/socketio/socket.io-client-swift/pull/669) | Refactor engine | PR mit Verhaltensänderung 0.93 | im Fork bereits adressiert 1.00 | Routine |
| [#671](https://github.com/socketio/socket.io-client-swift/pull/671) | v9.0 | PR mit Verhaltensänderung 0.84 | Unzureichende Evidenz 0.68 | Routine |
| [#822](https://github.com/socketio/socket.io-client-swift/pull/822) | v12.1.0 | PR mit Verhaltensänderung 0.96 | im Fork bereits adressiert 0.52 | Routine |
| [#915](https://github.com/socketio/socket.io-client-swift/pull/915) | Add missing `,`  when leaving or joining a namespace | PR mit Verhaltensänderung 0.42 | im Fork bereits adressiert 0.98 | Important |
| [#927](https://github.com/socketio/socket.io-client-swift/pull/927) | fix insert invoked twice | PR mit Verhaltensänderung 0.51 | noch zutreffend 0.54 | Routine |
| [#1014](https://github.com/socketio/socket.io-client-swift/pull/1014) | thread-safety on ackNumber generation and memory leak fix | PR mit Verhaltensänderung 0.44 | im Fork bereits adressiert 1.00 | Important |
| [#1015](https://github.com/socketio/socket.io-client-swift/pull/1015) | thread-safe ackNumber generation and memory leak fix | Defekt, potenziell aktuell 0.41 | im Fork bereits adressiert 1.00 | Important |
| [#1051](https://github.com/socketio/socket.io-client-swift/pull/1051) | Fix for SyntaxError: Unexpected end of JSON input | PR mit Verhaltensänderung 0.71 | nicht anwendbar 0.41 | Routine |
| [#1102](https://github.com/socketio/socket.io-client-swift/pull/1102) | Propagate http header callback from websocket back to client. | PR mit Verhaltensänderung 0.76 | im Fork bereits adressiert 0.91 | Routine |
| [#1103](https://github.com/socketio/socket.io-client-swift/pull/1103) | Propagate http header callback from websocket back to client. | PR mit Verhaltensänderung 0.76 | im Fork bereits adressiert 0.95 | Routine |
| [#1198](https://github.com/socketio/socket.io-client-swift/pull/1198) | Expose SocketIOClient and SocketAnyEvent to objective c | PR mit Verhaltensänderung 0.73 | nicht anwendbar 0.99 | Routine |
| [#1213](https://github.com/socketio/socket.io-client-swift/pull/1213) | Auto detect which protocol to use depend on url scheme | PR mit Verhaltensänderung 0.77 | entspricht JS-Client 0.80 | Routine |
| [#1214](https://github.com/socketio/socket.io-client-swift/pull/1214) | Auto detect which protocol to use depend on url scheme | PR mit Verhaltensänderung 0.78 | entspricht JS-Client 0.80 | Routine |
| [#1233](https://github.com/socketio/socket.io-client-swift/pull/1233) | Fix connection error handling if the connection state is wrong | Defekt, potenziell aktuell 0.52 | noch zutreffend 0.77 | Important |
| [#1320](https://github.com/socketio/socket.io-client-swift/pull/1320) | Combine support | PR mit Verhaltensänderung 0.92 | Unzureichende Evidenz 0.80 | Routine |
| [#1331](https://github.com/socketio/socket.io-client-swift/pull/1331) | Add option to disableEventMessageParsing and receive messages as Strin | PR mit Verhaltensänderung 0.98 | nicht anwendbar 0.90 | Routine |
| [#1443](https://github.com/socketio/socket.io-client-swift/pull/1443) | Fix Internet switch cases by adding the case of viabilityChanged | PR mit Verhaltensänderung 0.53 | nicht anwendbar 0.94 | Routine |
| [#1444](https://github.com/socketio/socket.io-client-swift/pull/1444) | Fix the network switch cases by adding case for  .viabilityChanged(is… | PR mit Verhaltensänderung 0.60 | nicht anwendbar 0.87 | Important |
| [#1473](https://github.com/socketio/socket.io-client-swift/pull/1473) | Improved websocket reconnection logic | PR mit Verhaltensänderung 0.82 | noch zutreffend 0.40 | Important |
| [#1476](https://github.com/socketio/socket.io-client-swift/pull/1476) | Thread safe handlers | PR mit Verhaltensänderung 0.59 | noch zutreffend 0.95 | Routine |
| [#1483](https://github.com/socketio/socket.io-client-swift/pull/1483) | Use correct default socket path. Use native engine of StarScream | PR mit Verhaltensänderung 0.79 | noch zutreffend 0.39 | High |
| [#1508](https://github.com/socketio/socket.io-client-swift/pull/1508) | Fix crash after concurent modification of acks Set. | Defekt, potenziell aktuell 0.72 | noch zutreffend 0.63 | High |
| [#1511](https://github.com/socketio/socket.io-client-swift/pull/1511) | Android | PR mit Verhaltensänderung 0.47 | noch zutreffend 0.57 | Routine |
| [#1518](https://github.com/socketio/socket.io-client-swift/pull/1518) | fix: wss secure | PR mit Verhaltensänderung 0.46 | noch zutreffend 0.96 | High |
| [#1520](https://github.com/socketio/socket.io-client-swift/pull/1520) | Adding missing error event | Defekt, potenziell aktuell 0.67 | Unzureichende Evidenz 0.50 | Important |
| [#1521](https://github.com/socketio/socket.io-client-swift/pull/1521) | Adding an option to ignore httpCookieStorage Cookies | PR mit Verhaltensänderung 0.82 | im Fork bereits adressiert 0.57 | Important |
| [#1524](https://github.com/socketio/socket.io-client-swift/pull/1524) | Fix memory leak of URLSession in SocketEngine | Defekt, potenziell aktuell 0.95 | im Fork bereits adressiert 1.00 | Important |
| [#1525](https://github.com/socketio/socket.io-client-swift/pull/1525) | Add socketio connection state recovery | PR mit Verhaltensänderung 0.64 | im Fork bereits adressiert 0.94 | High |

### Offene Upstream-Issues mit Substanz

| Issue | Titel | Jahr | Stufe 1 | Stufe 2 | Priorität |
| --- | --- | --- | --- | --- | --- |
| [#249](https://github.com/socketio/socket.io-client-swift/issues/249) | Linux Port | 2015 | Feature-Wunsch 0.95 | noch zutreffend 1.00 | Routine |
| [#307](https://github.com/socketio/socket.io-client-swift/issues/307) | Need to read cookie from response headers | 2016 | Feature-Wunsch 1.00 | im Fork bereits adressiert 0.98 | Important |
| [#356](https://github.com/socketio/socket.io-client-swift/issues/356) | SocketEnginePollable Crash Sometimes | 2016 | Defekt, potenziell aktuell 0.98 | im Fork bereits adressiert 1.00 | High |
| [#385](https://github.com/socketio/socket.io-client-swift/issues/385) | Sometimes emit method is not working on connect | 2016 | Defekt, potenziell aktuell 0.99 | Unzureichende Evidenz 0.53 | High |
| [#411](https://github.com/socketio/socket.io-client-swift/issues/411) | After websocket disconnected, it still call a method named error | 2016 | Defekt, potenziell aktuell 0.80 | nicht anwendbar 0.90 | Important |
| [#421](https://github.com/socketio/socket.io-client-swift/issues/421) | WebSocket doesn't connect through proxy | 2016 | Defekt, potenziell aktuell 0.54 | nicht anwendbar 0.93 | Routine |
| [#442](https://github.com/socketio/socket.io-client-swift/issues/442) | Reconnect Events stop firing once the socket is disconnected and conne | 2016 | Defekt, potenziell aktuell 0.91 | im Fork bereits adressiert 0.74 | Important |
| [#465](https://github.com/socketio/socket.io-client-swift/issues/465) | Engine URLSession became invalid | 2016 | Defekt, potenziell aktuell 0.55 | im Fork bereits adressiert 0.96 | Important |
| [#531](https://github.com/socketio/socket.io-client-swift/issues/531) | Multiple data races found by Xcode Thread Sanitizer | 2016 | Defekt, potenziell aktuell 0.90 | im Fork bereits adressiert 0.80 | Important |
| [#552](https://github.com/socketio/socket.io-client-swift/issues/552) | Crash on init because of sessionDelegate parameter | 2016 | Defekt, potenziell aktuell 0.65 | nicht anwendbar 0.99 | Routine |
| [#554](https://github.com/socketio/socket.io-client-swift/issues/554) | emitWithAck and timeout behavior | 2016 | Defekt, potenziell aktuell 0.80 | im Fork bereits adressiert 0.79 | Routine |
| [#564](https://github.com/socketio/socket.io-client-swift/issues/564) | (URGENT)(Objective-C) After successful connection, Emit is causing Dis | 2016 | Defekt, potenziell aktuell 0.72 | nicht anwendbar 1.00 | Routine |
| [#565](https://github.com/socketio/socket.io-client-swift/issues/565) | acknowledgement times out on simulatneous multiple socket.emitwithack  | 2016 | Defekt, potenziell aktuell 1.00 | im Fork bereits adressiert 0.89 | High |
| [#605](https://github.com/socketio/socket.io-client-swift/issues/605) | Multi connection after reconnected | 2017 | Defekt, potenziell aktuell 0.97 | nicht anwendbar 0.50 | Important |
| [#613](https://github.com/socketio/socket.io-client-swift/issues/613) | {"code":1,"message":"Session ID unknown"} while connecting users to so | 2017 | Defekt, potenziell aktuell 0.55 | entspricht JS-Client 0.81 | Important |
| [#630](https://github.com/socketio/socket.io-client-swift/issues/630) | Received the same event twice from one socketClient | 2017 | Defekt, potenziell aktuell 0.98 | im Fork bereits adressiert 0.96 | Important |
| [#638](https://github.com/socketio/socket.io-client-swift/issues/638) | Update the latest version can not submit parameters and receive the re | 2017 | Defekt, potenziell aktuell 0.57 | Unzureichende Evidenz 0.97 | Routine |
| [#639](https://github.com/socketio/socket.io-client-swift/issues/639) | SocketIO crash when server disconnect client | 2017 | Defekt, potenziell aktuell 0.94 | entspricht JS-Client 0.73 | Routine |
| [#656](https://github.com/socketio/socket.io-client-swift/issues/656) | socket looses connection as soon as it is connected. Sometimes keeps c | 2017 | Defekt, potenziell aktuell 0.65 | nicht anwendbar 0.83 | Routine |
| [#679](https://github.com/socketio/socket.io-client-swift/issues/679) | Client-side and server-side errors are difficult to differentiate | 2017 | Feature-Wunsch 0.99 | im Fork bereits adressiert 0.94 | Routine |
| [#681](https://github.com/socketio/socket.io-client-swift/issues/681) | Client fires "error" event for 60 second timeout, timeout handlers >60 | 2017 | Defekt, potenziell aktuell 1.00 | noch zutreffend 0.84 | Important |
| [#784](https://github.com/socketio/socket.io-client-swift/issues/784) | Trying to reconnect always | 2017 | Defekt, potenziell aktuell 1.00 | noch zutreffend 0.51 | High |
| [#792](https://github.com/socketio/socket.io-client-swift/issues/792) | Reconnect may lead to crash,cause of race condition | 2017 | Defekt, potenziell aktuell 0.99 | nicht anwendbar 0.96 | Routine |
| [#878](https://github.com/socketio/socket.io-client-swift/issues/878) | Need way to distinguish server disconnects from client disconnects | 2017 | Feature-Wunsch 1.00 | im Fork bereits adressiert 0.48 | Important |
| [#909](https://github.com/socketio/socket.io-client-swift/issues/909) | After connection upgrade to webSocket In case of a failure to reconnec | 2017 | Defekt, potenziell aktuell 0.98 | noch zutreffend 0.49 | High |
| [#913](https://github.com/socketio/socket.io-client-swift/issues/913) | Socket disconnects automatically and after disconnect it's not reconne | 2017 | Defekt, potenziell aktuell 0.70 | im Fork bereits adressiert 0.50 | Important |
| [#918](https://github.com/socketio/socket.io-client-swift/issues/918) | Socket disconnects automatically, reconnects, and disconnects again an | 2018 | Defekt, potenziell aktuell 0.79 | nicht anwendbar 0.90 | Important |
| [#945](https://github.com/socketio/socket.io-client-swift/issues/945) | session leak | 2018 | Defekt, potenziell aktuell 0.89 | im Fork bereits adressiert 0.98 | Important |
| [#952](https://github.com/socketio/socket.io-client-swift/issues/952) | Decode responses to Struct via Codable | 2018 | Feature-Wunsch 1.00 | noch zutreffend 1.00 | Routine |
| [#1013](https://github.com/socketio/socket.io-client-swift/issues/1013) | Question about feature, or possible suggestion | 2018 | Feature-Wunsch 1.00 | noch zutreffend 1.00 | Routine |
| [#1076](https://github.com/socketio/socket.io-client-swift/issues/1076) | How can i fix this kind of crash?(specialized closure #1 in....) | 2018 | Defekt, potenziell aktuell 0.48 | nicht anwendbar 1.00 | Routine |
| [#1136](https://github.com/socketio/socket.io-client-swift/issues/1136) | Automatically reconnected after disconnect | 2018 | Defekt, potenziell aktuell 0.71 | im Fork bereits adressiert 0.91 | Important |
| [#1137](https://github.com/socketio/socket.io-client-swift/issues/1137) | socket event listeners not removing after disconnect in objective c | 2018 | Defekt, potenziell aktuell 0.88 | nicht anwendbar 0.66 | Important |
| [#1141](https://github.com/socketio/socket.io-client-swift/issues/1141) | [__NSMallocBlock__ _fastCStringContents:]: unrecognized selector sent  | 2019 | Defekt, potenziell aktuell 0.90 | nicht anwendbar 0.63 | Routine |
| [#1142](https://github.com/socketio/socket.io-client-swift/issues/1142) | In the process of using it, I received connect monitoring without rece | 2019 | Defekt, potenziell aktuell 0.57 | nicht anwendbar 1.00 | Routine |
| [#1143](https://github.com/socketio/socket.io-client-swift/issues/1143) | Socket Emit Ack false | 2019 | Defekt, potenziell aktuell 0.68 | nicht anwendbar 0.83 | Routine |
| [#1150](https://github.com/socketio/socket.io-client-swift/issues/1150) | Custom parser for iOS app | 2019 | Feature-Wunsch 0.96 | noch zutreffend 1.00 | Routine |
| [#1154](https://github.com/socketio/socket.io-client-swift/issues/1154) | connect timeout doesn't called when network is off | 2019 | Defekt, potenziell aktuell 0.90 | noch zutreffend 0.55 | Important |
| [#1157](https://github.com/socketio/socket.io-client-swift/issues/1157) | SSL / TLS client certificate authentication | 2019 | Feature-Wunsch 1.00 | noch zutreffend 0.89 | Important |
| [#1161](https://github.com/socketio/socket.io-client-swift/issues/1161) | After each connection, it will be disconnected No rules. | 2019 | Defekt, potenziell aktuell 0.37 | nicht anwendbar 0.70 | Important |
| [#1162](https://github.com/socketio/socket.io-client-swift/issues/1162) | I use this socket. io-client-swift (the latest version of 14.0.0) to d | 2019 | Defekt, potenziell aktuell 0.49 | Unzureichende Evidenz 0.76 | Routine |
| [#1163](https://github.com/socketio/socket.io-client-swift/issues/1163) | Socket event not connect after disconnect | 2019 | Defekt, potenziell aktuell 0.77 | Unzureichende Evidenz 0.62 | Important |
| [#1166](https://github.com/socketio/socket.io-client-swift/issues/1166) | in swift ,  on(_:callback:)  EXC_BAD_INSTRUCTION | 2019 | Defekt, potenziell aktuell 0.41 | nicht anwendbar 0.97 | Routine |
| [#1167](https://github.com/socketio/socket.io-client-swift/issues/1167) | manager .disconnect () fail | 2019 | Defekt, potenziell aktuell 0.64 | entspricht JS-Client 0.94 | Routine |
| [#1169](https://github.com/socketio/socket.io-client-swift/issues/1169) | Transports property of configuration options in Android? | 2019 | Feature-Wunsch 0.99 | im Fork bereits adressiert 0.92 | Routine |
| [#1170](https://github.com/socketio/socket.io-client-swift/issues/1170) | using websocket chatting doesn't receive right message when not in eng | 2019 | Defekt, potenziell aktuell 0.62 | im Fork bereits adressiert 0.79 | Important |
| [#1171](https://github.com/socketio/socket.io-client-swift/issues/1171) | found some bug i think in json seralization socketextension str.toarra | 2019 | Defekt, potenziell aktuell 0.84 | im Fork bereits adressiert 0.96 | Routine |
| [#1172](https://github.com/socketio/socket.io-client-swift/issues/1172) | Few events are not called but connection is made properly | 2019 | Defekt, potenziell aktuell 0.58 | Unzureichende Evidenz 0.92 | Routine |
| [#1173](https://github.com/socketio/socket.io-client-swift/issues/1173) | Large Memory Footprint When Processing Large Messages | 2019 | Defekt, potenziell aktuell 0.72 | nicht anwendbar 0.69 | Important |
| [#1183](https://github.com/socketio/socket.io-client-swift/issues/1183) | Client called Connect first, then called Error when server throw next( | 2019 | Defekt, potenziell aktuell 0.90 | im Fork bereits adressiert 0.52 | High |
| [#1191](https://github.com/socketio/socket.io-client-swift/issues/1191) | Loosing extraHeaders when locking - unlocking device twice | 2019 | Defekt, potenziell aktuell 0.95 | im Fork bereits adressiert 0.52 | High |
| [#1193](https://github.com/socketio/socket.io-client-swift/issues/1193) | handleAck crash | 2019 | Defekt, potenziell aktuell 0.99 | im Fork bereits adressiert 0.95 | High |
| [#1194](https://github.com/socketio/socket.io-client-swift/issues/1194) | SocketIOClient Triggers `connect` event too early | 2019 | Defekt, potenziell aktuell 1.00 | im Fork bereits adressiert 0.51 | High |
| [#1200](https://github.com/socketio/socket.io-client-swift/issues/1200) | SocketManager.init failing with config options | 2019 | Defekt, potenziell aktuell 0.94 | noch zutreffend 0.71 | High |
| [#1215](https://github.com/socketio/socket.io-client-swift/issues/1215) | Apple Watch OS 6 supported with new websocket API? | 2019 | Feature-Wunsch 0.96 | im Fork bereits adressiert 0.70 | Routine |
| [#1217](https://github.com/socketio/socket.io-client-swift/issues/1217) | 服务器返回中文乱码，forcePolling设置为NO后，就第一次接收的消息偶尔为乱码 | 2019 | Defekt, potenziell aktuell 0.79 | nicht anwendbar 0.93 | Important |
| [#1227](https://github.com/socketio/socket.io-client-swift/issues/1227) | Request for a socket.io and socket.io-client-swift compatible versions | 2019 | Dokumentationslücke 0.95 | im Fork bereits adressiert 0.87 | Routine |
| [#1255](https://github.com/socketio/socket.io-client-swift/issues/1255) | "Tried emitting when not connected" while being actually connected | 2019 | Defekt, potenziell aktuell 0.75 | im Fork bereits adressiert 0.56 | High |
| [#1259](https://github.com/socketio/socket.io-client-swift/issues/1259) | Protobuf | 2020 | Feature-Wunsch 0.80 | noch zutreffend 0.61 | Routine |
| [#1262](https://github.com/socketio/socket.io-client-swift/issues/1262) | No elapsed time (latency) in pong event | 2020 | Defekt, potenziell aktuell 0.51 | entspricht JS-Client 0.95 | Routine |
| [#1263](https://github.com/socketio/socket.io-client-swift/issues/1263) | SocketIOStatus error | 2020 | Defekt, potenziell aktuell 0.94 | nicht anwendbar 0.99 | Routine |
| [#1264](https://github.com/socketio/socket.io-client-swift/issues/1264) | Sometime emitting getting failed and seems like socket get stuck on re | 2020 | Defekt, potenziell aktuell 0.83 | Unzureichende Evidenz 1.00 | Routine |
| [#1270](https://github.com/socketio/socket.io-client-swift/issues/1270) | Socket with custom namespace sent event but status is still connecting | 2020 | Defekt, potenziell aktuell 0.95 | im Fork bereits adressiert 0.56 | Important |
| [#1272](https://github.com/socketio/socket.io-client-swift/issues/1272) | receive message in Chinese will be show unrecognizable characters, lik | 2020 | Defekt, potenziell aktuell 0.54 | im Fork bereits adressiert 0.97 | Routine |
| [#1282](https://github.com/socketio/socket.io-client-swift/issues/1282) | reconnect not disabled after disconnect | 2020 | Defekt, potenziell aktuell 0.83 | im Fork bereits adressiert 0.60 | High |
| [#1287](https://github.com/socketio/socket.io-client-swift/issues/1287) | Base64 encoded images emitting problem | 2020 | Defekt, potenziell aktuell 0.91 | nicht anwendbar 0.93 | Routine |
| [#1288](https://github.com/socketio/socket.io-client-swift/issues/1288) | xcode 11 socket connect error: tried emitting when not connected | 2020 | Defekt, potenziell aktuell 0.49 | im Fork bereits adressiert 0.88 | Important |
| [#1289](https://github.com/socketio/socket.io-client-swift/issues/1289) | Socket Keeps reconnecting | 2020 | Defekt, potenziell aktuell 0.51 | nicht anwendbar 0.92 | Important |
| [#1290](https://github.com/socketio/socket.io-client-swift/issues/1290) | Pointer being freed was not allocated | Random Crash | 2020 | Defekt, potenziell aktuell 0.99 | im Fork bereits adressiert 0.52 | Critical |
| [#1292](https://github.com/socketio/socket.io-client-swift/issues/1292) | Crash on com.socketio.engineHandleQueue | 2020 | Defekt, potenziell aktuell 1.00 | nicht anwendbar 0.99 | Routine |
| [#1293](https://github.com/socketio/socket.io-client-swift/issues/1293) | Emitting in connect event after disconnection | 2020 | Defekt, potenziell aktuell 0.71 | im Fork bereits adressiert 0.84 | Important |
| [#1297](https://github.com/socketio/socket.io-client-swift/issues/1297) | Extract namespace and query parameters from SocketManager URL | 2020 | Feature-Wunsch 0.97 | im Fork bereits adressiert 0.86 | High |
| [#1298](https://github.com/socketio/socket.io-client-swift/issues/1298) | cannot received correct mixed binary message | 2020 | Defekt, potenziell aktuell 1.00 | im Fork bereits adressiert 0.84 | Important |
| [#1323](https://github.com/socketio/socket.io-client-swift/issues/1323) | Emit parameters wrapped twice | 2021 | Defekt, potenziell aktuell 0.55 | noch zutreffend 0.68 | Important |
| [#1326](https://github.com/socketio/socket.io-client-swift/issues/1326) | v16 EXC_BAD_ACCESS | 2021 | Defekt, potenziell aktuell 0.60 | noch zutreffend 0.56 | High |
| [#1329](https://github.com/socketio/socket.io-client-swift/issues/1329) | Connection succeeds, even after timeout triggered | 2021 | Defekt, potenziell aktuell 0.98 | im Fork bereits adressiert 0.92 | Important |
| [#1330](https://github.com/socketio/socket.io-client-swift/issues/1330) | Reconnection getting failed on Lock Screen iOS | 2021 | Defekt, potenziell aktuell 1.00 | nicht anwendbar 0.46 | Important |
| [#1336](https://github.com/socketio/socket.io-client-swift/issues/1336) | Idea: Improve release notes for 16.x (Link to upgrading notes?) | 2021 | Dokumentationslücke 1.00 | noch zutreffend 0.63 | Routine |
| [#1341](https://github.com/socketio/socket.io-client-swift/issues/1341) | SIGTRAP | 2021 | Defekt, potenziell aktuell 0.98 | nicht anwendbar 0.57 | Important |
| [#1344](https://github.com/socketio/socket.io-client-swift/issues/1344) | Getting ERROR SocketManager: Invalid HTTP upgrade. code=400, type=upgr | 2021 | Defekt, potenziell aktuell 0.92 | nicht anwendbar 0.98 | Routine |
| [#1346](https://github.com/socketio/socket.io-client-swift/issues/1346) | Crash inside the SocketIOClient | 2021 | Defekt, potenziell aktuell 0.97 | Unzureichende Evidenz 1.00 | Routine |
| [#1353](https://github.com/socketio/socket.io-client-swift/issues/1353) | Socket.io v16.0.0-16.0.1 emit event twice? | 2021 | Defekt, potenziell aktuell 0.98 | noch zutreffend 0.40 | Important |
| [#1361](https://github.com/socketio/socket.io-client-swift/issues/1361) | Issue with socket.io v4 and socket.io-client-swift v15.0.0 | 2021 | Defekt, potenziell aktuell 0.49 | im Fork bereits adressiert 0.94 | Routine |
| [#1363](https://github.com/socketio/socket.io-client-swift/issues/1363) | Not Receiving Private Events for Subscribed Channels | 2021 | Defekt, potenziell aktuell 0.64 | Unzureichende Evidenz 0.91 | Important |
| [#1365](https://github.com/socketio/socket.io-client-swift/issues/1365) | Add completion handler to SocketIOClient connect, disconnect, and emit | 2021 | Feature-Wunsch 1.00 | noch zutreffend 0.68 | Routine |
| [#1374](https://github.com/socketio/socket.io-client-swift/issues/1374) | SocketIOClient always return connected status when the internet has sh | 2021 | Defekt, potenziell aktuell 0.66 | noch zutreffend 0.36 | Important |
| [#1380](https://github.com/socketio/socket.io-client-swift/issues/1380) | Emit doesn't work | 2021 | Defekt, potenziell aktuell 0.60 | Unzureichende Evidenz 0.43 | Routine |
| [#1389](https://github.com/socketio/socket.io-client-swift/issues/1389) | Timestamp sometimes Int and sometimes String | 2021 | Defekt, potenziell aktuell 0.96 | entspricht JS-Client 0.90 | Routine |
| [#1391](https://github.com/socketio/socket.io-client-swift/issues/1391) | Compatibility table link does not work | 2021 | Dokumentationslücke 0.92 | noch zutreffend 0.47 | Routine |
| [#1396](https://github.com/socketio/socket.io-client-swift/issues/1396) | SSL Pinning with URLSessionDelegate doesnt use websocket protocol but  | 2021 | Defekt, potenziell aktuell 0.60 | im Fork bereits adressiert 0.94 | Important |
| [#1400](https://github.com/socketio/socket.io-client-swift/issues/1400) | `WSS` protocol does not trigger secure config | 2022 | Defekt, potenziell aktuell 0.98 | noch zutreffend 0.87 | High |
| [#1401](https://github.com/socketio/socket.io-client-swift/issues/1401) | App crash when connecting to socket | 2022 | Defekt, potenziell aktuell 0.80 | Unzureichende Evidenz 0.57 | Important |
| [#1403](https://github.com/socketio/socket.io-client-swift/issues/1403) | websocket 重连错误，  guard !status.active else 第一次之后，永远return | 2022 | Defekt, potenziell aktuell 1.00 | im Fork bereits adressiert 0.91 | High |
| [#1404](https://github.com/socketio/socket.io-client-swift/issues/1404) | Socket.IO-Client-Swift  version is 15.2 but connect server of socket.i | 2022 | Defekt, potenziell aktuell 0.56 | im Fork bereits adressiert 0.99 | Important |
| [#1411](https://github.com/socketio/socket.io-client-swift/issues/1411) | Please support Objective-C | 2022 | Feature-Wunsch 1.00 | nicht anwendbar 0.90 | Routine |
| [#1415](https://github.com/socketio/socket.io-client-swift/issues/1415) | Socket `disconnect` not fired when device loses network | 2022 | Defekt, potenziell aktuell 1.00 | entspricht JS-Client 0.79 | High |
| [#1416](https://github.com/socketio/socket.io-client-swift/issues/1416) | Swift 6 Rewrite | 2022 | Feature-Wunsch 0.98 | im Fork bereits adressiert 0.98 | Routine |
| [#1417](https://github.com/socketio/socket.io-client-swift/issues/1417) | SocketClient deinit never called. | 2022 | Defekt, potenziell aktuell 0.55 | im Fork bereits adressiert 0.44 | Important |
| [#1421](https://github.com/socketio/socket.io-client-swift/issues/1421) | Crash when using '<', '>', '\' in connectParams | 2022 | Defekt, potenziell aktuell 0.98 | noch zutreffend 0.99 | High |
| [#1422](https://github.com/socketio/socket.io-client-swift/issues/1422) | Connecting to the server with nginx load balancer sends socket.io iOS  | 2022 | Defekt, potenziell aktuell 1.00 | im Fork bereits adressiert 0.43 | High |
| [#1423](https://github.com/socketio/socket.io-client-swift/issues/1423) | Behaviour change: connect on manager | 2022 | Dokumentationslücke 0.71 | entspricht JS-Client 0.78 | Routine |
| [#1424](https://github.com/socketio/socket.io-client-swift/issues/1424) | Socket .on method is not calling until I emit anything | 2022 | Defekt, potenziell aktuell 0.66 | nicht anwendbar 0.71 | Routine |
| [#1427](https://github.com/socketio/socket.io-client-swift/issues/1427) | ERROR: Property 'defaultSocket' not found on object of type 'SocketMan | 2022 | Defekt, potenziell aktuell 0.68 | nicht anwendbar 0.71 | Routine |
| [#1428](https://github.com/socketio/socket.io-client-swift/issues/1428) | Doing Polling issue from swift client when using v4.5.2 socket.IO in a | 2022 | Defekt, potenziell aktuell 0.69 | noch zutreffend 0.51 | High |
| [#1438](https://github.com/socketio/socket.io-client-swift/issues/1438) | How to get the underlying `NSError` object in an `on:callback:` for ev | 2023 | Feature-Wunsch 0.96 | im Fork bereits adressiert 0.97 | Routine |
| [#1439](https://github.com/socketio/socket.io-client-swift/issues/1439) | 你能支持oc，16.0.1吗 when I add @objc to emitWithAck  warning：Method cannot  | 2023 | Feature-Wunsch 0.37 | nicht anwendbar 0.99 | Routine |
| [#1449](https://github.com/socketio/socket.io-client-swift/issues/1449) | SocketIOClientOption.cookies ignored in Starscream with HTTPCookieStor | 2023 | Dokumentationslücke 0.51 | nicht anwendbar 0.52 | Important |
| [#1455](https://github.com/socketio/socket.io-client-swift/issues/1455) | Socket io gives a connection error when connecting back from going to  | 2023 | Defekt, potenziell aktuell 0.91 | Unzureichende Evidenz 0.60 | Important |
| [#1459](https://github.com/socketio/socket.io-client-swift/issues/1459) | Socket.IO-Client-Swift version 16 Crash on iOS 16, built with Xcode 15 | 2023 | Defekt, potenziell aktuell 0.97 | nicht anwendbar 0.97 | Routine |
| [#1466](https://github.com/socketio/socket.io-client-swift/issues/1466) | LOG SocketManager: Tried connecting an already active socket | 2023 | Defekt, potenziell aktuell 0.83 | entspricht JS-Client 0.32 | Important |
| [#1470](https://github.com/socketio/socket.io-client-swift/issues/1470) | Potential Memory Management Issue with emitWithAck and timingOut(after | 2023 | Defekt, potenziell aktuell 0.55 | im Fork bereits adressiert 0.81 | Important |
| [#1477](https://github.com/socketio/socket.io-client-swift/issues/1477) | Implement Connection State Recovery | 2024 | Feature-Wunsch 1.00 | im Fork bereits adressiert 0.93 | Important |
| [#1496](https://github.com/socketio/socket.io-client-swift/issues/1496) | Binary data in base64 encoding (Polling) is not padded, causing compat | 2024 | Defekt, potenziell aktuell 0.99 | im Fork bereits adressiert 0.64 | Routine |
| [#1497](https://github.com/socketio/socket.io-client-swift/issues/1497) | Socket stopped listening event after 30 to 40 mins | 2024 | Defekt, potenziell aktuell 0.71 | Unzureichende Evidenz 0.80 | Important |
| [#1498](https://github.com/socketio/socket.io-client-swift/issues/1498) | "The operation couldn’t be completed. (SocketIO.EngineError error 0.)" | 2024 | Defekt, potenziell aktuell 0.45 | noch zutreffend 0.51 | Routine |
| [#1502](https://github.com/socketio/socket.io-client-swift/issues/1502) | ERROR SocketManager: The operation couldn’t be completed. (xxxx.Engine | 2024 | Defekt, potenziell aktuell 0.86 | nicht anwendbar 0.83 | Routine |
| [#1505](https://github.com/socketio/socket.io-client-swift/issues/1505) | Compatible page 404 | 2024 | Dokumentationslücke 0.94 | nicht anwendbar 0.48 | Routine |
| [#1506](https://github.com/socketio/socket.io-client-swift/issues/1506) | What is the proper way to update `connectPayload` on reconnection? | 2024 | Feature-Wunsch 0.79 | im Fork bereits adressiert 0.69 | Routine |
| [#1507](https://github.com/socketio/socket.io-client-swift/issues/1507) | Timeout or way to cancel `socketClient.once()` so that `.once()` can b | 2024 | Feature-Wunsch 0.95 | noch zutreffend 0.79 | Important |
| [#1509](https://github.com/socketio/socket.io-client-swift/issues/1509) | handleAck crash in V16.1.1 | 2024 | Defekt, potenziell aktuell 1.00 | noch zutreffend 0.73 | High |
| [#1512](https://github.com/socketio/socket.io-client-swift/issues/1512) | Any message incuding slash will be added escape character after callin | 2025 | Defekt, potenziell aktuell 0.92 | noch zutreffend 0.83 | Important |
| [#1513](https://github.com/socketio/socket.io-client-swift/issues/1513) | Socket is not getting connect when coming from background to foregroun | 2025 | Defekt, potenziell aktuell 0.82 | noch zutreffend 0.52 | Important |

## Wiederkehrende Nutzerfragen (Lernpunkte für Doku)

Grundlage: 565 Items der Kategorien Support-Frage und Dokumentationslücke. Gezählt wird nur der Titel, damit eingefügte Logauszüge die Themen nicht verfälschen. Ein Titel kann mehrere Themen treffen; 204 Titel treffen keines.

| Thema | Titel |
| --- | ---: |
| Verbindung kommt nicht zustande / Handshake / URL / path | 192 |
| Binärdaten / JSON / Datentypen | 46 |
| Reconnect / Hintergrund / Netzwechsel | 38 |
| SSL / TLS / Zertifikate / Proxy | 30 |
| Objective-C / Bridging | 30 |
| Headers / Cookies / Query / Auth | 29 |
| Namespaces / Räume | 25 |
| Server-Versionen / Protokoll (v2/v3/v4) | 23 |
| Acks / Callbacks / Timeouts | 22 |
| Threading / Main-Queue / UI | 13 |
| Logging / Debugging | 11 |
