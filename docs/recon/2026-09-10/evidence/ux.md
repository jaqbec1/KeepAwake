# Native macOS UX reconnaissance

Scope: AppKit source at dced7ae. Read-only assessment. The earlier user confirmed that the native menu opens; no new VoiceOver, keyboard, multi-display, or appearance tests were performed in this pass.

## Confirmed issue: session outcomes are hidden

Sources/App.swift:206-214 saves a completion reason in `message`, while statusTitle at 70-78 returns Ready for an ordinary idle state. Sources/Menu.swift:136-137 renders that generic status and puts the completion reason only in a tooltip. A timer finishing, battery cutoff, heartbeat failure, or authorization cancellation therefore loses its visible explanation. The actual immediate-stop incident shows why this matters.

P2 recommendation: display the latest result directly in the menu, with a concise reason and the next action when recovery is needed. Provide a small Copy diagnostics action containing app/macOS versions, mode, session state, and relevant errors. Keep private paths, credentials, and unrelated process data out of diagnostics.

Acceptance: cancel authorization, expire a timer, simulate low battery and helper disconnection. In each case reopening the menu shows why the session ended without hovering. VoiceOver can discover the same outcome. A completed recovery visibly reports normal sleep restored.

## Preserve native AppKit controls

The real NSMenu, standard checkmarks, SF Symbols, and native alerts match the user's explicit correction. There is no demonstrated need to rewrite the view layer in SwiftUI. A rewrite would not fix the helper lifecycle or test coverage.

Menu.swift:19-25 and 196-203 manually opens a menu using screen coordinates and activates the application. Investigate replacing this with NSStatusItem.menu, Apple's direct menu association, only after an interaction test proves the behavior we need. Do not claim current multi-monitor placement or keyboard access is broken without reproducing it.

Acceptance: open/dismiss by mouse and keyboard; restore focus to the previous app; move between displays and scale factors; test the auto-hidden menu bar and limited menu-bar space; test reopening the app from Finder; confirm Stop remains reachable and status-item order survives relaunch. Treat the native NSStatusItem route as an experiment, not a mandated rewrite.

## Clarify the product contract

Explain ordinary idle prevention and closed-lid override briefly at first use, with administrator authorization only for the latter. Keep conservative charger defaults. Do not claim a kernel setting alone proves the laptop remained awake with its lid closed.

Keep full run diagnostics in a small support view or copy action rather than exposing process internals in the primary menu. Do not add triggers, themes, graphs, account systems, or a large settings window before recovery and verification are dependable.

## Skills applied as review lenses

Impeccable's product register supports familiarity and visible state. Its native audit is chiefly iOS/Android; its touch sizes, Dynamic Type score, navigation gestures, and mobile numeric scoring are not macOS evidence. Use AppKit documentation and a real macOS interaction checklist instead. The skill's context and product register had already been loaded in this conversation; its native audit and product reference were read for this pass.

Apple source: https://developer.apple.com/documentation/appkit/nsstatusitem/menu
