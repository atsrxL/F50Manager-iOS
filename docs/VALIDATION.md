# Verification record

Environment: macOS, Xcode 26.3 (17C529), iOS Simulator 26.3, deployment target iOS 17.0. Verified 2026-10-30. All compilation was local under the iOS/macOS-only exception; no MS-A2 host or VM was started.

## Verified

- iOS Simulator Debug build and XCTest: real NIOSSL memory TLS1.3 round trip (including 1-byte fragment delivery), rejecting wrong pin, wrong/missing ALPN, TLS1.2, oversized input.
- Framing matches the original synthetic protocol fixture; min-MTU chunks, every split boundary, bounded queues, UTF-8 and matched JSON-RPC response IDs.
- Input limits: ASCII phone/IDs, GSM7 extension septets, UCS2/non-BMP/control characters, supported bands.
- Authorization lifetime, private-state clearing on background, demo isolation, explicit prepare/commit, no second commit/replay after failure.
- Unknown data and source age stay unknown; a null source-specific age does not inherit another source's fresh age.
- iPhone demo navigation, disabled write operations, accessibility XXXL landing, no overlap between status and navigation controls.
- Release `generic/platform=iOS` build: **BUILD SUCCEEDED**, Mach-O architecture **arm64**, code signing disabled and `codesign -dv` reports no signature.
- Final iPhone 17 Pro: **29 unit tests + 2 UI tests = 31 passed, 0 failures**, TEST SUCCEEDED.
- Final iPad Pro 11-inch (M5): **29 unit tests + 2 UI tests = 31 passed, 0 failures**, TEST SUCCEEDED.
- Both runs exercised the final source. Public synthetic screenshots are retained in `docs/screenshots/`; concise test/build logs are in ignored `artifacts/validation/`.

The earlier visual review found overlapping top banners/navigation on iPhone; RootView now lays the status area out outside TabView and a geometry assertion guards the regression. The first iPad UI test assumed the iPhone TabBar accessibility hierarchy; selector changed to the platform-neutral button query (the app itself remained navigable).

## Reproduction

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/build.sh test
DESTINATION='platform=iOS Simulator,name=iPad Pro 11-inch (M5)' ./scripts/build.sh test
./scripts/build.sh device
```

Actual release run additionally used `-configuration Release -derivedDataPath build/DeviceDerivedData`. Test runs disabled parallel testing and selected existing simulators explicitly. No new simulator runtime or compiler/toolchain was installed.

A dependency-only Xcode warning about CNIOWindows's missing umbrella header may appear while building for iOS; it did not prevent builds/tests. No application-source compiler warnings remained.

## Artifact

`artifacts/F50Manager-0.1.0-unsigned.ipa`: unsigned arm64 app, approximately 8.8 MiB.

SHA-256:
`4dc59717fa9309c281bd061df51cb5325b5c7b835ecaf7b3eafe61b68e3e30e8`

No developer profile/certificate/Team or real device private key is included. Synthetic TLS test fixtures are in the test target only. Real-device installation requires the user's own signing.

## Not verified / not performed

- Physical F50 ↔ iPhone/iPad Bluetooth discovery, system pairing, MTU, indication confirmation, sustained data and reconnect interoperability.
- Real SMS content, sending/deleting, RAT/band changes, Wi-Fi switching/guard recovery or reboot.
- Background delivery/resident behavior, optional owner enrollment, Android system switching or public multi-AD broadcast reconstruction: not provided by this version.
- Signed-device install, TestFlight or App Store delivery.

No real F50 was accessed, provisioned, reconfigured or restarted. Passing simulator/offline tests is **not** a device-ready claim.

## Cleanup and retained files

The task-local `build/` tree (including both DerivedData trees, package checkouts, intermediate app bundles and full result bundles) measured **1,657,792 KiB, about 1.58 GiB**, then was removed after preserving the IPA, public screenshots and concise logs. Remaining local `build` / `target` directories for this client: **0 bytes**. `artifacts/` is about **8.8 MiB** and is Git-ignored.

Both selected simulator devices were already shut down by Xcode at cleanup; no simulator was left running by this task. Cleanup did not restart them merely to uninstall the test app. No shared Xcode cache, existing simulator runtime, unrelated build tree or other project files were deleted. No tools/runtimes were installed. No remote host cleanup/shutdown was scheduled because none was started.

## Suggested next hardware validation

1. User-approved exclusive BLE window; release other management clients.
2. Install with user signing, allow Bluetooth, select known provisioned identity.
3. Observe pairing/OPEN/TLS/ALPN and read only hello/dashboard/Wi-Fi/lock state.
4. Disconnect/background/reconnect; confirm private state and authorization do not survive the session, and identity mismatch is fail-closed.
5. Only with separate user confirmation, test one protected operation and its outcome/recovery. Never use unsolicited SMS, network changes, reboot or OS switching as a smoke test.
