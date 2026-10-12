# Multi-screen workspace (Mac)

## Goal
With more than one monitor, any PrepBoard section or panel can live in its own window on a chosen screen and stay there. PrepBoard recognises each screen setup, restores the arrangement used last time with that setup, and suggests a layout the first time it sees a new one.

## Decisions (agreed with the user)
- **Movable units:** sections (Coding, Docs, Browse…) and panels (Claude, side video).
- **On screen changes:** restore the saved layout for that setup silently; for a new setup with 2+ screens, show a banner suggesting a layout (Apply / Choose / Not now).
- Mac only. iPhone and iPad are unchanged.

## Design
- **Screens.** `WorkspaceScreen` holds a display's UUID, name, frame and visible frame, and whether it's built in. Screens are ranked by area (largest first, external before built-in on ties). The *fingerprint* of a setup is its sorted display UUIDs.
- **Layouts.** A `WorkspaceLayout` is a name plus slots. Each slot holds content (`main(Section)`, `section(Section)`, `claude`, `video`), a screen rank, and a rectangle in 0–1 units of that screen's visible frame, measured from the top-left. Ranks above the number of screens fall back to the last screen, so a 3-screen layout still opens on 2.
- **Recommended layouts** by screen count:
  - 1 screen: Focus (Coding, full screen).
  - 2 screens: Code + Reference (Coding on the largest screen; Browse above Claude on the other) and Study (Documents on the largest; Timeline beside Claude on the other).
  - 3+ screens: Command Center (Coding, Browse, then Timeline above Claude).
  - If Claude Code isn't set up, Claude slots become Documents.
- **Store.** UserDefaults keys hold `workspace.byFingerprint` (the last arrangement for each setup, saved automatically on moves and resizes, debounced), `workspace.named` (layouts you've saved) and `workspace.dismissed` (setups where you chose Not now).
- **`WorkspaceManager`** (AppKit) registers the main window and opens detached windows as `NSWindow` + `NSHostingView`.
  - Each section window has its own `AppState`. All other models and the SwiftData container are shared.
  - Panel windows share the main `AppState`, and the main window hides a panel while it's detached.
  - It watches `didChangeScreenParametersNotification` (debounced) and window moves and resizes.
- **UI.**
  - The rail's context menu offers *Open in New Window* and *Open on ▸ screen*.
  - The Claude and video panels get a detach button.
  - A **Workspace** menu offers Apply Layout ▸, Save Current Layout…, Delete Saved Layout ▸, Move Window to Next Screen (⌃⌥⌘→), Gather Windows Here, and Close Detached Windows.
  - The suggestion banner sits at the top of the main window.

## Testing
- **Unit tests** for ranking, fingerprint, the unit-rect ↔ frame maths (with AppKit's bottom-left origin), capture (frame → slot), recommendations, the Claude fallback, rank fallback and store persistence.
- **Manual check** on the three connected displays (built-in, Acer 27", Smart M50C): read back the window frames with System Events.
