# Widget tests

Run on macOS with Xcode's command-line tools:

```sh
bash Tests/run.sh
```

The runner compiles all three production Swift files as a testable dynamic
library and tests their actual internal types. It does not copy source into
fixtures, start the app, or change the Xcode project. Build products and module
caches use a temporary directory removed on exit. Persistence tests use unique
`UserDefaults` suites and remove them afterward; application preferences remain
untouched.

Coverage includes ordered narrow/wide packing, row heights, responsive columns,
scroll viewport caps, editing geometry and callbacks, widget persistence and
sanitization, safe reorder bounds, and Turkish clock formatting across midnight.
Extra card descriptors are layout fixtures, not additional registered widgets.
Only the clock kind exists, so real multi-kind reorder and drag interaction must
be verified when another kind is introduced.

Manual app checks remain necessary for hover reversals, native panel clipping
and mouse passthrough, edit mode staying open, drag/drop, scrolling, theme
contrast, and the seconds setting.
