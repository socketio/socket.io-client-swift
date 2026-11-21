# Ephemeral TLS fixtures

`generate-native-tls.mjs` uses Node and OpenSSL to generate a private test CA,
a seven-day localhost leaf and an explicitly expired leaf in a temporary
per-test-process directory. The valid leaf never exceeds platform lifetime
limits. Tests do not override their verification clock or install roots.
No generated private key or certificate is committed. Unit and HTTPS/WSS
integration tests use the same temporary certificate set and trust policy.
