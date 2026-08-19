# Apple II Emulator: Code Conventions

## Scope and style

- Keep the app native: Swift, SwiftUI, AppKit, Foundation and AVFoundation only. Do not add a third-party dependency for a small utility.
- Prefer clear, hardware-named state and short focused methods over opaque abstractions.
- Preserve the existing Chinese user-facing UI text unless a change explicitly requires copy revision.
- Keep UI work on `@MainActor`; never block the main thread with file I/O, audio rendering, or long-running work.

## Emulator correctness

- Treat the CPU, memory map, soft switches, video, Disk II and speaker as hardware. Do not replace their behavior with UI-level shortcuts.
- All emulated time is expressed in 6502 cycles. New timing-sensitive behavior must be driven from the CPU cycle source, never frame counts or wall-clock sleeps.
- I/O effects that depend on access timing (especially `$C030`, disk I/O and paddles) must occur at the relevant bus-access cycle, not merely at instruction completion.
- Keep the CPU instruction model and `AppleIIMemory` bus separate. `MOS6502` must access memory through its `read`/`write` helpers so timing and soft-switch behavior remain observable.
- Preserve supported image formats and their semantics: `.dsk`/`.do` DOS order, `.po` ProDOS order, `.d13`, `.nib`, and 5.25-inch `.2mg`/`.2img` only.

## Audio

- `$C030` toggles a one-bit speaker flip-flop. Record every edge with its emulated cycle; never turn each access into an independent host-side click.
- Generate PCM into a bounded producer/consumer buffer. The audio callback must only dequeue prepared samples and must not inspect emulator state or allocate memory.
- `Sources/AppleIIRealtime` is the one permitted C11 target: use it only for lock-free realtime primitives with explicit atomic memory ordering. Do not add a package dependency merely to obtain an atomic queue.
- Keep CPU execution and audio on a shared monotonic time base. UI timer jitter must not change audio pitch.
- Avoid arbitrary audio filters. Any filtering/noise suppression must be documented as a speaker-path approximation and kept configurable if it materially changes game audio.

## SwiftPM resources and game library

- SwiftPM flattens processed resource directories into `AppleIIEmulator_AppleIIEmulator.bundle`. Enumerate `Bundle.module.bundleURL` when listing packaged game images; do not assume a `Games/` subdirectory exists at runtime.
- Keep the packaged game menu deterministic: sort titles case-insensitively and group large libraries by initial.
- Downloaded images belong under `Sources/AppleIIEmulator/Resources/Games/` when they are intended to ship in the app. Do not make the shipped game menu depend on the workspace `Downloads/` directory.

## Building and the Logo app

- Use `swift build` for normal compile verification. Avoid `swift test` as a routine smoke test until any tests that retain the emulator timer are made to terminate reliably.
- The distributable, icon-bearing app is `build/AppleIIEmulator.app`. Its executable and SwiftPM resource bundle must be updated together from `.build/arm64-apple-macosx/debug/`.
- After replacing the app executable or resources, re-sign locally and verify before launch:

  ```sh
  codesign --force --deep --sign - build/AppleIIEmulator.app
  codesign --verify --deep --strict build/AppleIIEmulator.app
  ```

- Do not leave both `swift run` and `build/AppleIIEmulator.app` instances open. Prefer the Logo app for user testing.

## Release signing and Apple notarization

- A public GitHub Release is a distributable, not a development build. Do not
  upload an ad-hoc-signed (`codesign --sign -`) app as a release asset.
- Before creating or replacing a public release asset, sign the app with the
  configured `Developer ID Application` identity, Hardened Runtime and a
  secure timestamp. Keep the signing identity out of source control.
- Submit the final ZIP (made with `ditto -c -k --sequesterRsrc --keepParent`)
  to Apple notarization using a `notarytool` Keychain profile. Never put an
  Apple ID password, app-specific password, API key, or `.p8` file in the
  repository, command output, or release notes.
- Wait for notarization to succeed, staple the ticket to
  `build/AppleIIEmulator.app`, then validate it with both
  `xcrun stapler validate build/AppleIIEmulator.app` and
  `spctl --assess --type execute --verbose=4 build/AppleIIEmulator.app`.
- Upload the ZIP to GitHub only after signature verification, notarization,
  stapling and Gatekeeper assessment all pass. If notarization credentials are
  unavailable, stop before publishing and ask the user to provide an existing
  Keychain profile name or App Store Connect API-key details.

## Validation

- Build after source changes that affect the app target.
- For hardware changes, add or update a focused regression test where practical; preserve existing soft-switch and disk boot tests.
- When a visual or audio behavior is changed, launch the Logo app and verify the changed path manually.
