# Widget tests

Run on macOS with Xcode's command-line tools:

```sh
bash Tests/run.sh
```

The runner compiles all production Swift files under `Sources/` as a testable dynamic
library and tests their actual internal types. It does not copy source into
fixtures, start the app, or change the Xcode project. Build products and module
caches use a temporary directory removed on exit. Persistence tests use unique
`UserDefaults` suites and remove them afterward; application preferences remain
untouched.

Coverage includes ordered narrow/wide packing, row heights, responsive columns,
scroll viewport caps, editing geometry and callbacks, widget persistence and
sanitization, safe reorder bounds, and Turkish clock formatting across midnight.
File shelf coverage includes persistence, duplicate/symlink identity, same-name
files, missing originals, stale and invalid bookmarks, balanced scoped access,
corrupt archive recovery, atomic write failure, and incoming drag page restoration.
Extra card descriptors are layout fixtures, not additional registered widgets.
Only the clock kind exists, so real multi-kind reorder and drag interaction must
be verified when another kind is introduced.

Manual app checks remain necessary for hover reversals, native panel clipping
and mouse passthrough, edit mode staying open, drag/drop, scrolling, theme
contrast, and the seconds setting.

File shelf manual checks:

- Drag one file, several files, and a folder from Finder toward the collapsed notch;
  verify a compact hint first appears below the notch while the file is still far
  away, then the shelf expands and the dropzone highlights on approach. Releasing
  the file elsewhere must dismiss the hint; text drags must not show it.
- Drop, switch home/shelf, then restart: entries remain and originals are untouched.
- Drag a card into Finder and a file-accepting app: only accepted copy operations
  remove its entry. Escape, rejected targets, and dropping back into the shelf
  keep the entry. Modifier keys must never move the original.
- Cancel or retreat from an incoming drag: depot content remains throughout the
  closing animation; the previous page is restored only after the panel is hidden.
  Repeat with rapid retreat/reentry and animations disabled.
- Drag text or a web URL: do not switch automatically or accept the drop.
- Delete an original outside the app and reopen the shelf: show an unavailable card
  that can still be removed. Verify this after restarting the sandboxed signed app.
- Check physical notch clearance, scroll interaction, transparent mouse passthrough,
  widget editing, and Reduce Motion with both pages.
- Switch home/shelf repeatedly while open: content fades through the background,
  width stays equal to home, and height changes on the same animation timeline.
  Toolbar buttons stay in place; the hidden shelf must not intercept file drops.
  Repeat with animations disabled and Reduce Motion enabled; switching is immediate.
