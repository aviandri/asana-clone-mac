# Mekari Project for Mac

Native macOS (14+) client for Mekari Project, the company's internal work-management app.

- Spec: [`docs/SPEC-MAC.md`](docs/SPEC-MAC.md)
- Backend API contract: `aviandri/asana-clone-be` → `docs/SPEC.md`

Status: v1 feature-complete; trial pre-release [`v0.1.0-rc1`](https://github.com/aviandri/asana-clone-mac/releases/tag/v0.1.0-rc1).

## Layout
| Path | What |
|---|---|
| `Package.swift` | SwiftPM (tools 5.10, macOS 14): `MekariProjectKit`, `MekariProjectFeatures` |
| `Sources/MekariProjectKit/` | models, API client, token store (platform-neutral) |
| `Sources/MekariProjectFeatures/` | `@Observable` view models (Kit + Observation only, no SwiftUI) |
| `Tests/` | XCTest, run on Linux and macOS; `Tests/ContractTests` needs a live backend |
| `UITests/` | XCUITest smoke (macOS only): launches with `-UITestFakeAPI`, finds `sidebar.myTasks` |
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

## Known limitation: Keychain prompts on unsigned builds
v1 builds are ad-hoc signed, so the legacy Keychain ties the session token's access to that build's
code signature. After an update, macOS may ask once whether "Mekari Project" may use the saved
item. The app reads the token **once at launch** (then keeps it in memory) and rewrites it on
sign-in, so it's at most one prompt per update. Denying it just means signing in again. This goes
away once builds are signed with a team ID (data-protection keychain).

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
| `macos-app` | `macos-15`: `swift test`, XcodeGen, `xcodebuild build test` (unsigned), universal Release archive, ad-hoc signed, launch smoke (5 s with `-UITestFakeAPI`), zipped; uploaded as an artifact on pushes to `main` and tags |
| `release` | `v*` tags only: GitHub Release with the zip and generated notes |

## Installing (unsigned builds)
Releases are universal (Apple Silicon + Intel) and need macOS 14 Sonoma or later. They're ad-hoc
signed but not notarized, so macOS asks for confirmation the first time.

1. Download `MekariProject-<version>.zip` from the
   [latest release](https://github.com/aviandri/asana-clone-mac/releases/latest).
   Builds of `main` are also attached to each CI run as the `MekariProject-<sha>` artifact.
2. Unzip it (double-click) and move **Mekari Project.app** to **Applications**.
3. The first time, **right-click the app → Open**, then confirm **Open**. Or clear the quarantine
   flag from Terminal:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Mekari Project.app"
   ```
4. Sign in with your Mekari Project server URL, email and password.

## Releasing
Push a tag `vMAJOR.MINOR.PATCH` (or `vMAJOR.MINOR.PATCH-rc1` for a prerelease) on `main`; only the
orchestrator tags. CI stamps the version (`MARKETING_VERSION` from the tag, build number = run
number), builds and launch-smokes the universal app, and the `release` job creates a GitHub Release.
The release has the zip attached and notes generated from the merged PR titles.
