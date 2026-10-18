# Mekari Project for Mac (v1), SPEC

A native macOS client for **Mekari Project**, the company's internal Asana clone. It talks to the
existing backend. The backend API contract is **canonical in
`aviandri/asana-clone-be` → `docs/SPEC.md`** (§2 conventions, §5 shapes, §6 endpoints, §12
workspaces incl. clarifications W1–W8). This document only adds what is Mac-specific. If the two
disagree, the BE spec wins; ask the orchestrator before changing either.

## 1. Scope

**v1 = core daily use.** Everything else stays in the web app and is reachable via "Open in Browser".

| In v1 | Not in v1 (open in web) |
|---|---|
| Sign in / sign out, server URL | Accept invite, create account |
| Workspace switcher (⌘1…⌘9) | Workspace settings, admin, invites |
| My Tasks | Goals / OKRs (§10) |
| Projects: List and Board views | Reporting (§11), Calendar view |
| Task inspector: title, description, assignee, due date, priority, complete, subtasks, followers, comments + activity | Teams browse / team admin, project settings & members |
| Inbox (notifications), mark read / all read | Profile editing |
| Search (⌘K) | |
| Menu bar extra: due today/overdue, quick add, unread count | |
| Local notifications for new inbox items | |

Creating tasks, sections and projects: tasks and subtasks **yes**; sections **yes** (List view "Add
section"); new projects **no** in v1 (link to the web).

## 2. Platform & stack

- macOS **14 Sonoma+**, universal binary (arm64 + x86_64). Swift 5.10+ (Swift 6 language mode
  welcome but not required), SwiftUI-first, AppKit only where SwiftUI can't (e.g. `NSWorkspace`).
- **Observation** (`@Observable`) for state; Swift concurrency (`async/await`, `@MainActor` for
  UI-facing models). No Combine in new code, no third-party UI frameworks.
- Dependencies: none by default. Any SwiftPM dependency needs orchestrator approval.
- Product name **Mekari Project**, bundle id `com.mekari.project`, URL scheme `mekariproject`.
- Distribution v1: **unsigned** (ad-hoc signed `-` so it runs on Apple Silicon), shipped as a zipped
  `.app` CI artifact and a GitHub Release on tags `v*`. Install note: right-click → Open the first
  time. Signing + notarization come later (needs an Apple Developer account).

## 3. Repo layout & the Linux constraint

The dev box is **Linux with no Xcode**. Only CI (GitHub `macos-15` runners) can build the app.
So the design keeps as much as possible in a **platform-neutral Swift package** that builds and
tests on Linux, and keeps the app target a thin layer of SwiftUI views.

```
Package.swift                 SwiftPM, tools 5.10; products: MekariProjectKit, MekariProjectFeatures
Sources/MekariProjectKit/     Models (Codable), APIClient, errors, TokenStore, date helpers
Sources/MekariProjectFeatures/ @Observable view models / stores (no SwiftUI, no AppKit imports)
Tests/…                       XCTest; run with `swift test` on Linux AND macOS
Tests/ContractTests/          hits a real seeded BE when MP_BASE_URL is set; skipped otherwise
App/                          macOS app target (SwiftUI views, menu bar, notifications, assets)
App/Resources/Assets.xcassets AppIcon (generated from brand SVG), AccentColor
project.yml                   XcodeGen spec → MekariProject.xcodeproj (generated in CI, not committed)
.github/workflows/ci.yml      linux: swift test (+ contract job); macos: xcodegen → build, test, archive
```

Rules:
- `MekariProjectKit` and `MekariProjectFeatures` must compile on Linux: `import FoundationNetworking`
  behind `#if canImport(FoundationNetworking)`; Keychain code behind `#if canImport(Security)`, with an
  in-memory `TokenStore` used on Linux and in tests.
- Features may import Kit and Observation only. Views hold no business logic. If it can be unit
  tested, it lives in Features.
- Every view model is constructible with a **fake API** (`FakeMekariAPI` in Kit, seeded with demo
  data), used for SwiftUI previews and tests.

## 4. Networking & auth

- `APIClient` (actor or `Sendable` final class) wraps `URLSession`, base URL = server URL +
  `/api/v1`. JSON camelCase, ISO-8601 timestamps (with and without fractional seconds), `dueDate`/
  `startDate` as date-only `YYYY-MM-DD` mapped to a `LocalDate` value type (not `Date`).
- **Session:** the BE uses an httpOnly cookie `sid` (JWT, 7 days). The client **disables automatic
  cookie handling** (`httpShouldSetCookies = false`, no shared cookie storage), reads `sid` from the
  login response's `Set-Cookie`, stores it in the **Keychain** (`TokenStore`), and sends
  `Cookie: sid=<token>` on every request. A `401` anywhere → clear the token, return to sign-in.
  No BE change needed.
- **Workspace header:** every request except `/auth/*` and `/workspaces` sends `X-Workspace-Id` for
  the window's current workspace (BE §12 "Current workspace"). On switch: `POST
  /workspaces/:id/switch`, then reload all stores. A `404` from a scoped collection endpoint while
  a header is set → refetch `/auth/me` without a header and adopt its `currentWorkspace` (lost
  access, same as the web FE).
- Errors decode the BE envelope `{error:{code,message,details}}` into `APIError` (code enum incl.
  `unknown`, message, field issues). Network failures → `APIError.transport`. UI shows `message`.
- Polling (no push API exists): notifications every **60 s** while the app is active, **5 min**
  in the background or menu-bar-only; My Tasks refresh on window focus. Use `If-None-Match` only if
  the BE ever adds ETags; not required.
- Server URL: entered on the sign-in screen (placeholder `https://…`), validated with `GET /health`,
  remembered in `UserDefaults`. One server per app install in v1.

## 5. App structure & UX

Native Mac look: `NavigationSplitView` (sidebar | content | inspector), system materials, SF
Symbols, standard toolbar and keyboard behaviour, light and dark mode. Accent colour is the brand magenta
`#E0257F`. App icon is the magenta gradient tile (`#B0136B → #E0257F → #FF5FA2`) from the web
app's `public/favicon.svg`. Do not imitate the web UI pixel for pixel; follow the macOS HIG.

**Sign-in window:** server URL, email, password, "Sign in". Errors inline (401: "Wrong email or
password", 429: rate limited). Links: "Accept an invite in the browser".

**Main window:**
- **Sidebar:** workspace menu at top (name, colour tile, Guest pill when `myRole == GUEST`, ⌘1…⌘9
  in `Me.workspaces` order, "Open workspace settings in browser" for admins). Then: My Tasks, Inbox
  (unread badge), Projects (the workspace's visible, non-archived projects, by name; colour dot).
  Guests see only their projects (the BE already filters).
- **My Tasks:** sections "Overdue", "Today", "Upcoming", "Later", "No date"; show completed toggle.
  Checkbox completes (optimistic, revert on error). Inline "Add task" creates a personal task
  assigned to me.
- **Project:** segmented control List / Board (start on the project's `defaultView`; CALENDAR →
  List). List: sections with tasks, inline add per section, drag to reorder and move between
  sections (float `position`, BE §2). Board: columns = sections, drag cards between columns. Read-only
  for `COMMENTER`, and for anyone without edit rights (BE §4).
- **Task inspector** (trailing column, or a separate window via ⌘O / double-click): all v1 fields
  editable in place. Assignee and follower pickers use `GET /users?q=`; per W8 entries carry `role`,
  so show a "Guest" badge. Subtasks list with add/complete. Comments + activity in order (`GET
  /tasks/:id/stories`), composer at the bottom (⌘↩ to send); render markdown basics and mentions
  `@[Name](id)` as tokens; typing `@` offers the user picker.
- **Inbox:** notifications newest first, unread bold; click marks read and opens the task.
  "Mark all as read".
- **Search (⌘K):** a palette (min 2 chars, debounce 250 ms) with Tasks / Projects / People groups.
  Return opens the result.
- **Open in Browser (⇧⌘O):** opens the current project or task on the web app (base = server URL;
  paths `/projects/:id`, `/projects/:id?task=:taskId`, `/my-tasks?task=:id`).

**Menu bar extra** (`MenuBarExtra`, window style): unread count in the icon; list of overdue and
due-today tasks (complete inline); a quick-add field (title + optional due date, creates a personal
task assigned to me); "Open Mekari Project". Setting: "Show in menu bar" (default on). Closing the
last window keeps the app alive in the menu bar if enabled.

**Local notifications:** when polling finds new unread notifications, post a `UserNotifications`
banner ("Alice commented on *Fix login*"); clicking opens the task. Ask permission on first sign-in.
Setting to turn off.

**Settings window (⌘,):** server URL (sign out to change), show in menu bar, notifications on/off,
launch at login (`SMAppService`).

**Deep links:** `mekariproject://task/<id>` and `mekariproject://project/<id>` open in the app
(auto-switching workspace like the web FE when the resource is in another workspace the user
belongs to; if no access, show "You don't have access").

**Accessibility:** every interactive control has an accessibility label; key views carry
`accessibilityIdentifier`s (used by UI tests): `signin.server`, `signin.email`, `signin.password`,
`signin.submit`, `sidebar.workspaceMenu`, `sidebar.myTasks`, `sidebar.inbox`, `task.row.<id>`,
`task.inspector`, `search.field`, `menubar.quickAdd`.

## 6. Quality gates (CI)

- **linux / kit:** `swift build` + `swift test` (Kit and Features) on `ubuntu-latest` (swift 5.10
  or 6.x image).
- **linux / contract:** like the BE's `contract` job: check out `asana-clone-be` main, postgres
  service, migrate + full seed, start BE, run `swift test --filter ContractTests` with
  `MP_BASE_URL`. Covers login/cookie, `/auth/me`, workspace header and switch, my tasks, project
  tasks, create/patch/complete task, comments, notifications, search, guest restrictions (W1, W7, W8).
- **macos / app:** `macos-15`, `brew install xcodegen`, `xcodegen generate`, `xcodebuild build` and
  `test` (unit tests + a small XCUITest smoke against `FakeMekariAPI` via launch argument
  `-UITestFakeAPI`), then on `main` / tags: archive Release universal, ad-hoc sign, `ditto` zip,
  upload artifact; on `v*` tags create a GitHub Release.
- All three must be green to merge. No warnings-as-errors in v1, but no new warnings in Kit/Features.

## 7. Workflow

- Same rules as the other repos: feature branches, PRs to `main`, the orchestrator reviews and merges,
  stacked PRs use merge commits. Push via `git@github-personal:aviandri/asana-clone-mac.git`.
- Heavy commands on the dev box go through `/home/claude/projects/asana-clone/heavy.sh timeout <s> <cmd>`.
- Contract questions go to the orchestrator; don't change BE behaviour from this repo.
- Planned PRs:
  1. **Scaffold & CI** (platform): Package.swift with empty targets, project.yml, app stub that
     launches, CI workflow (all three jobs; contract job may start with a single health test), icon
     generation, README install notes, Linux Swift toolchain on the box.
  2. **Kit** (Kit engineer): models, APIClient, TokenStore (Keychain + memory), errors, LocalDate,
     `FakeMekariAPI` with demo data, unit tests, first contract tests.
  3. **Features** (Kit engineer): Session, Workspaces, MyTasks, Project (list/board, reorder math),
     TaskDetail (+stories, composer, mentions), Inbox + NotificationPoller, Search, QuickAdd. Tests,
     plus the full contract suite.
  4. **App shell** (Mac UI engineer): sign-in, split view, sidebar, workspace menu, My Tasks, task
     inspector, settings window.
  5. **App complete** (Mac UI engineer): projects list/board with drag and drop, inbox, search palette,
     menu bar extra, local notifications, deep links, open in browser, XCUITest smoke.
  6. **Release** (platform): universal archive, zip, GitHub Release on tags, README install steps.
