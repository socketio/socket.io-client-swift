# Documentation

[Project overview](../README.md) · [Contributing](../CONTRIBUTING.md)

Start with the application guides. Implementation reviews and historical evidence
are separate references, not prerequisites for using the library.

## Choosing a client

[Why this fork?](Guides/WhyThisFork.md) compares the inspected official Swift
client with this continuation, links the source snapshots, and explains the
trade-offs. Start there when deciding whether to adopt the package; go directly
to the application guides when you are ready to integrate it.

## Application guides

| Topic | Read |
| --- | --- |
| Requirements, SPM installation and the first connection | [Getting started](Guides/GettingStarted.md) |
| Supported servers, platforms and removed protocol modes | [Compatibility](Guides/Compatibility.md) |
| Listeners, payloads, binary data, volatile events and catch-all APIs | [Events and payloads](Guides/Events.md) |
| Callback/async acknowledgements, timeouts and ordered retries | [Acknowledgements and delivery](Guides/Acknowledgements.md) |
| Authentication, namespaces, reconnection and session recovery | [Connection lifecycle](Guides/Connections.md) |
| Transports, queues, cookies, TLS and resource limits | [Configuration and concurrency](Guides/Configuration.md) |
| Missing callbacks and connection failures | [Troubleshooting](Guides/Troubleshooting.md) |

Examples using `socket` assume an existing socket used on its manager's serial
`handleQueue`. Examples are independent recipes, not one file to paste wholesale.

## Migration and releases

| Topic | Read |
| --- | --- |
| Start a 16.x → 17 migration | [Migration overview](Guides/Migration.md) |
| Removed APIs, protocol and Swift concurrency changes | [Socket.IO 4 / Swift 6 migration](SocketIO4Swift6Migration.md) |
| URLSession transport, TLS and backend differences | [Native transport migration](NativeWebSocketTransport.md) |
| 17.1.0 fixes, options and compatibility notes | [Release 17.1.0](Release17.1.0.md) |
| 17.0.1 fixes, options and compatibility notes | [Release 17.0.1](Release17.0.1.md) |
| Published 17.0.0 release and its recorded validation | [Release 17](Release17.md) |
| Version history | [Changelog](../CHANGELOG.md) |

## Library development

| Topic | Read |
| --- | --- |
| Components, ownership and source locations | [Architecture](Development/Architecture.md) |
| Local prerequisites, commands and CI jobs | [Testing](Development/Testing.md) |
| Release checks and version/tag handling | [Releasing](Development/Releasing.md) |
| Where files belong and how documentation is maintained | [Repository layout](Development/RepositoryLayout.md) |
| Purpose and prerequisites of each helper | [Script index](../scripts/README.md) |

## API reference

The documentation comments beside the implementation are the reference for this
checkout. Use Xcode's Quick Help or read the linked declarations. The removed
16.x generated website is not an API reference for version 17.

| API | Declaration |
| --- | --- |
| Manager and namespace ownership | [SocketManager](../Source/SocketIO/Manager/SocketManager.swift) |
| Events, authentication, connection lifecycle | [SocketIOClient](../Source/SocketIO/Client/SocketIOClient.swift) |
| Configuration options | [SocketIOClientOption](../Source/SocketIO/Client/SocketIOClientOption.swift) |
| Callback and async acknowledgement delivery | [SocketTimedEmitter](../Source/SocketIO/Ack/SocketTimedEmitter.swift) |
| TLS policy | [SocketTLSConfiguration](../Source/SocketIO/Security/SocketTLSConfiguration.swift) |
| WebSocket resource limits | [SocketWebSocketOptions](../Source/SocketIO/Engine/Transport/SocketWebSocketOptions.swift) |

## Parity and evidence

[PARITY.md](../PARITY.md) defines the supported scope. The
[contract manifest](JavaScriptParityContracts.json) and
[test inventory](JavaScriptTestInventory.csv) are executable CI inputs, not disposable
review notes. Their existing paths remain stable for the validators.

The [evidence index](ReviewEvidence/README.md) distinguishes live validation inputs
from historical snapshots and links the detailed reviews. A historical pass or
coverage percentage describes its recorded commit only; inspect CI for the exact
revision you plan to use.

## Historical material

The [archive index](Archive/README.md) preserves the old usage pages and links to
material already removed during the SPM-only cleanup. It is not an alternate
installation guide and does not restore retired distribution mechanisms.
