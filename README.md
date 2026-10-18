# Mekari Project for Mac

Native macOS (14+) client for Mekari Project, the company's internal work-management app.

- Spec: [`docs/SPEC-MAC.md`](docs/SPEC-MAC.md)
- Backend API contract: `aviandri/asana-clone-be` → `docs/SPEC.md`

Status: under construction (v1 scaffold).

## Layout
| Path | What |
|---|---|
| `Package.swift` | SwiftPM (tools 5.10, macOS 14): `MekariProjectKit`, `MekariProjectFeatures` |
| `Sources/MekariProjectKit/` | models, API client, token store (platform-neutral) |
| `Sources/MekariProjectFeatures/` | `@Observable` view models (Kit + Observation only, no SwiftUI) |
| `Tests/` | XCTest, run on Linux and macOS; `Tests/ContractTests` needs a live backend |
| `App/` | the macOS app target (SwiftUI), `App/Resources/Assets.xcassets` |
| `project.yml` | XcodeGen spec → `MekariProject.xcodeproj` (generated, not committed) |

## Developing on Linux (no Xcode)
Kit and Features build and test with the Linux Swift toolchain; the app target only builds in CI.
```sh
source /home/claude/projects/asana-clone/swift-env.sh   # Swift 6.0.3 on the dev box
swift build && swift test                                # contract tests are skipped
# against a running, seeded backend (BE `npm run seed`):
MP_BASE_URL=http://127.0.0.1:3000 swift test --filter ContractTests
```
On the shared dev box, run builds through `heavy.sh timeout <secs> …`.

Linux rules (SPEC-MAC §3):
- `import FoundationNetworking` behind `#if canImport(FoundationNetworking)`; Keychain code behind
  `#if canImport(Security)`.
- Tests of `@MainActor` types: make the test method `async` and put `@MainActor` on the method,
  not on the `XCTestCase` class. On Linux, XCTest can't call a synchronous test of a
  `@MainActor` class (the build fails with "call to main actor-isolated instance method … in a
  synchronous nonisolated context"). Use `await fulfillment(of:)` instead of `wait(for:)`.

## Developing on a Mac
```sh
brew install xcodegen
xcodegen generate && open MekariProject.xcodeproj   # scheme: MekariProjectApp
```

## App icon
`App/Resources/AppIcon.svg` is the web favicon on the macOS icon grid. Regenerate the PNGs after
changing it:
```sh
npm i --prefix /tmp/resvg @resvg/resvg-js@2.6.2
NODE_PATH=/tmp/resvg/node_modules node scripts/make-app-icon.mjs
```

## CI
| Job | Runs |
|---|---|
| `linux-kit` | `swift build` + `swift test` in the `swift:6.0` container |
| `linux-contract` | BE `main` (Postgres service, migrate, full seed) + `swift test --filter ContractTests` |
| `macos-app` | `macos-15`: `swift test`, XcodeGen, `xcodebuild build test` (unsigned), universal Release archive, ad-hoc signed, zipped; uploaded as an artifact on pushes to `main` and tags |

## Installing a build (unsigned)
Download the `MekariProject-<sha>` artifact from a `main` CI run and unzip it. Move
`Mekari Project.app` to Applications. The first time, right-click → Open (it's ad-hoc signed, not
notarized).
