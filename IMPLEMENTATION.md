# Architecture and safety boundaries

## Protocol layering

`SwiftUI → AppModel → SessionServing/F50Session → JSON-RPC length frames → MemoryTLS (NIOSSL) → BLELink → CoreBluetooth`

Production has one implementation of SessionServing: F50Session. The mock implementation exists only in the unit-test target. There is no network proxy, cleartext fallback or fake-success transport.

Each connection gets a new BLE delegate/manager, GATT discovery, TLS context, pin verification, framing state, request IDs and authorization state. Scan identifiers and Info are untrusted selection hints. Only a matching SHA-256 leaf DER pin permits TLS; versions are restricted to TLS 1.3 and ALPN must equal f50mgr/1.

NIO EmbeddedChannel is used as an in-memory byte transport on the main thread, including its custom certificate callback. Its synthetic connect address does not create a socket. Embedded time advances by monotonic elapsed time, not arbitrary timer draining. Teardown aborts the TLS handler's underlying memory channel before draining, avoiding a wait for a nonexistent peer close_notify.

## BLE and RPC

- Scan only the management UUID, explicit user action, 15-second window, at most 32 retained discoveries.
- Fresh link: power → connect → discover → indicate-only subscription → Info hint → OPEN/ACK → TLS.
- All writes use withResponse. The fragment limit is capped by both CoreBluetooth maximumWriteValueLength values and 512, avoiding the withResponse API's larger prepared/long-write allowance.
- One in-flight ATT write; bounded 128 KiB queue; finite monotonic phase/write/handshake deadlines. No arbitrary sleeps for indication confirmations.
- JSON frame length 1...65536; bounded incremental decoder, strict UTF-8, matching response ID, mutually exclusive result/error, structured events.
- One outstanding RPC, per-method timeouts, cancel/timeout closes the session. Old callbacks and cancellations cannot enter a new session generation.
- AppModel owns polling/keepalive scheduling so an independent hidden ping cannot race a protected action.

## Authorization and actions

The existing V12 configured access code is used only in pinned TLS when a user requests a protected operation. The authorization response must explicitly confirm scope=connection and expires_in_s=null. It is not persisted or automatically retried.

Mutation path is action.prepare → display the unmodified device summary → explicit user confirmation → consume local action ID → action.commit. The local deadline is monotonic. Background, disconnect and new TLS invalidate authorization, private SMS cache and uncommitted intent. No reconnect intent replay.

Wi-Fi state must be explicitly read and contain a known mode plus pending=null before proposing a change. Confirm/rollback are explicit buttons, never background automation. Server guard state remains authoritative. Lock result statuses are translated without claiming verification for ambiguous replies.

## Privacy / lifecycle

No analytics, account/cloud login, SMS logs, credential storage or automatic Bluetooth scan on startup. Demo fixtures never satisfy live requests. Actual backgrounding disconnects and clears private data; inactive (including OS permissions/pairing) overlays UI without aborting the protocol. iOS screenshot prevention is not claimed.

Only read-only dashboards and synthetic tests were used during development. Real hardware validation is outstanding and must start with read-only connection tests. SMS sends/deletes, Wi-Fi/band changes, reboot and other mutations require user authorization; never use them as an unsolicited smoke test.

## Scope

This is a native management client, not a claim of full Android parity. Existing multi-AD public broadcasts cannot be faithfully reconstructed through the exposed CoreBluetooth advertisement dictionary. No GATT data is presented as broadcast data. Public advertisement protocol, Android, backend and device state are unchanged.

Optional owner enrollment, system switching, cell locks and background notification/resident behavior are out of scope for this version. Golden application/GATT framing vectors are tested; optional enrollment/login vectors are retained as reference, not claimed as implemented.
