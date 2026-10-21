# App tests

Codex coverage includes the actual packaged native hook helper, isolated
install/remove fixtures, incremental quota reading, conservative permission
correlation, and a helper → disk spool → background store integration test.
No real Codex configuration, hook trust, or login state is changed. The runner
supplies `AGENTNOTCH_TEST_CODEX_HELPER` to the Swift integration fixture.

Visual QA uses the real SwiftUI card with synthetic disconnected, working,
permission-request and stale/unknown data in both languages:

```sh
/bin/sh Research/CodexReadOnly/render.sh /tmp/agentnotch-codex-visual
```

This renders a temporary AppKit application; it does not install hooks. Inspect
the PNGs under the output directory's `images/` folder. Real Codex hook trust
and the connection confirmation remain interactive checks, separate from the
synthetic integration test.

The widget-to-settings handoff has a separate GUI regression check:

```sh
python3 Research/CodexReadOnly/settings-flow-check.py
```

It runs the actual AppDelegate in its own bundle and preferences domain, verifies
that settings collapses the editing drawer and releases mouse input, checks that
expansion stays disabled until settings closes, and automatically cancels the
real consent dialog. No hook helper is bundled and no installation is accepted.
Screenshots are written to the printed temporary directory. Codex location
metadata may be read to display the consent dialog.

The connection tests discover an isolated home and exercise cancel, consent,
duplicate clicks and missing installations without showing a folder picker.
A separate signed App Sandbox probe uses exact hooks-file and own-directory
grants against a temporary fixture, including denied credential access:

```sh
python3 Research/CodexReadOnly/sandbox-hooks-probe.py
```

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

The runner also compiles the shipping `Resources/Localizable.xcstrings` with
`xcstringstool` into a temporary resource bundle. Localization tests load that
bundle through the production `AppLocalization` API, so they exercise compiled
`.strings` and plural `.stringsdict` resources.

Coverage includes ordered narrow/wide packing, row heights, responsive columns,
scroll viewport caps, editing geometry and callbacks, widget persistence and
sanitization, safe reorder bounds, and Turkish and English clock formatting across
midnight with explicit locales and time zones. Localization coverage includes
ordered system language negotiation, regional language codes, English fallback,
manual choice persistence, invalid saved values, live system refresh, reset,
complete typed key/catalog parity and compiled EN/TR translations, literal user
payload substitution, English singular/plural and Turkish counts (including
64-bit values and locale-specific number formatting), and retranslating retained
file errors.
File shelf coverage includes persistence, duplicate/symlink identity, same-name
files, missing originals, stale and invalid bookmarks, balanced scoped access,
corrupt archive recovery, atomic write failure, and incoming drag page restoration.
Extra card descriptors are layout fixtures, not additional registered widgets.
Only the clock kind exists, so real multi-kind reorder and drag interaction must
be verified when another kind is introduced.

The native file drag tests use real macOS pasteboards and need a desktop session
with pasteboard access. Restricted execution environments may deny pasteboard
writes and prevent those tests from running successfully. Xcode macro plugins
also need permission to start their own compiler sandbox; the standard runner
keeps the compiler's default sandbox behavior.

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

Language manual checks:

- On first launch, verify Turkish system preferences choose Turkish and English
  preferences choose English; unsupported preferences fall back to English.
- Open settings, choose English and Turkish, and check the open settings window,
  menu bar menu, island navigation, widget picker, file shelf, tooltips, and
  accessibility labels update immediately. Verify an already visible file error
  also updates and preserves its original filename.
- Restart to verify the manual choice persists. Choose System Default and verify
  the current supported system language is selected again.
- Check long English and Turkish labels fit, and the clock keeps 24-hour time
  while its date and weekday follow the selected language.


## Müzik çalar kontrolü

Otomatik testler oynatma zamanını, duraklatmayı, parça değişiminde kapak
kimliğini, bozuk/eksik veriyi, ileri/geri kısıtını ve bağlantı yokken pasif
kontrolleri sınar. Sol kapağın sağ çentik kenarını oynatmaması, sabit canvas’a
sığması ve widget ekleme/kaldırma kalıcılığı da gerçek üretim tipleriyle sınanır.

Canlı kontrol: sistem Şu An Çalınan’a bilgi veren bir uygulamada müzik/video aç;
sol kapağı ve ana sayfadaki kartı kontrol et. Oynat/duraklat ve ileri/geri
kaynağın desteklediği ölçüde çalışmalıdır. Kaynak kapanınca kart boş duruma
dönmeli; widget kaldırıldığında sol genişleme ve helper kapanmalıdır. Kapak
vermeyen kaynaklarda müzik simgesi beklenir.

## Codex düzeltmesi için kapsamlı kontroller

```sh
AGENTNOTCH_TEST_SCOPE=codex bash Tests/run.sh
```

Bu kapsam gerçek Codex veri/store/UI kaynaklarını, kurulum geçişini ve
EN/TR yerelleştirmelerini derler. Ayarlar macro süreci ve ilgisiz pasteboard
kontrolleri bu bileşen çalışmasının kapsamı dışındadır; tam suite ayrıca
`bash Tests/run.sh` ile çalışır. Shell entegrasyon testi hooks.json'daki gerçek
komutu `/bin/zsh -lc` üzerinden geçici event dizinine çalıştırır. Gerçek Codex
config veya trust dosyası değiştirilmez.

v2 kurulumunda sandbox içinden executable üretilmez: paket helper'ına doğrudan
başvurulur. `sandbox-hooks-probe.py` gerçek native helper'ı derleyip geçici
sandbox uygulamasının kurduğu komutu dış shell'den çalıştırarak olay teslimini
kontrol eder. Ana/alt ajan ilişkisi, fork geçmişi, yeniden görevlendirme, geciken
eski tur olayları, terminal hata, tool hatası, uzun iş heartbeat'i ve hook öncesi
salt okunur çalışma görünürlüğü regression kapsamındadır.
