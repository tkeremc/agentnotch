# agentnotch

Tek beyaz çentik, düz koyu zemin. Yazı, renkli vurgu ve efekt içermez.

- `app-icon.svg`: düzenlenebilir 1024 × 1024 uygulama ikonu.
- `notch-mark.svg`: şeffaf zeminli beyaz simge.
- `../Resources/Assets.xcassets/AppIcon.appiconset`: macOS için 16–1024 piksel PNG dosyaları.
- `../Resources/Assets.xcassets/NotchMark.imageset`: menü çubuğu ve ayarlar için vektörel PDF. Template olarak sistemin açık/koyu görünümüne uyarlanır.

Kaynak SVG ve native asset dosyalarını aynı geometriden yeniden üretmek için kaynak klasöründe:

```sh
swift -module-cache-path /tmp/agentnotch-icon-cache Branding/generate-icons.swift
```

SVG düzenleme kaynağıdır; uygulama ikonu Xcode'un AppIcon asset catalog desteğiyle paketlenir. macOS 14 desteği korunur.
