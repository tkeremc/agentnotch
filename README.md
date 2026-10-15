# leagent notch

SwiftUI ve AppKit ile yazılmış, menü çubuğunda çalışan bir macOS uygulaması.
Fare çentiğe geldiğinde widget çekmecesi açılır. Şu anda saat widget'ı bulunur.
macOS 14 ve üzerini destekler; harici paket bağımlılığı yoktur.

## Çalıştırma

1. Bu klasördeki `leagent notch.xcodeproj` dosyasını Xcode ile aç.
2. `leagent notch` şemasını ve `My Mac` hedefini seç.
3. `⌘R` ile çalıştır.
4. Fareyi çentiğe getir. Çentiksiz ekranda alan üst ortada görünür.
5. Menü çubuğundaki simgeden ayarlara ulaşabilir veya uygulamayı kapatabilirsin.

Proje yerel geliştirme için ad-hoc imzalanır; geliştirme ekibi seçmek gerekmez.
Xcode proje dosyası, kaynaklar ve kaynak görseller bu Git deposunun içindedir.

## Klasör yapısı

```text
NotchLab/
├── leagent notch.xcodeproj/      # Xcode hedefi, derleme ayarları ve ortak şema
├── Sources/                     # Uygulamaya derlenen Swift kodları
│   ├── App/                     # Başlangıç, uygulama yaşam döngüsü, menü
│   └── Features/
│       ├── Island/               # Çentik yüzeyi ve açılma/kapanma yönetimi
│       │   ├── Animation/        # Hareket ve geçiş hesapları
│       │   └── Window/           # Native panel ve fare takibi
│       ├── Settings/             # Kalıcı tercihler ve ayarlar ekranı
│       └── Widgets/
│           ├── Clock/            # Saat görünümü ve tarih/saat biçimlendirme
│           ├── Layout/           # Kart konumları ve çekmece boyutları
│           ├── Models/           # Widget türleri ve boyut tanımları
│           └── Views/            # Listeleme, düzenleme ve widget kataloğu
├── Resources/
│   └── Assets.xcassets/          # Paketlenen uygulama ikonu ve menü simgesi
├── Configuration/
│   └── Info.plist               # Uygulama kimliği ve macOS bilgileri
├── Tests/                       # Mevcut davranış testleri ve çalıştırıcısı
└── Branding/                    # Düzenlenebilir SVG'ler ve ikon üretim aracı
```

Klasörler kodu sorumluluğuna göre düzenler. Üretim kodu tek bir `NotchLab`
Swift modülüne derlenir; klasörler arasında ayrıca `import` yazman gerekmez.
`Branding` ve `Tests` altındaki Swift dosyaları uygulama hedefine derlenmez.

## Nerede neyi değiştireceğim?

| Yapmak istediğin | İlgili dosya |
| --- | --- |
| Uygulamanın başlangıcını değiştirmek | `Sources/App/NotchLabApp.swift` |
| Açılışı ve ayarlar penceresini yönetmek | `Sources/App/AppDelegate.swift` |
| Menü çubuğuna seçenek eklemek | `Sources/App/NotchMenu.swift` |
| Bir tercihi kaydetmek veya varsayılanını değiştirmek | `Sources/Features/Settings/NotchSettings.swift` |
| Ayarlar ekranına alan eklemek | `Sources/Features/Settings/NotchSettingsView.swift` |
| Hover, ekran seçimi ve panel davranışını değiştirmek | `Sources/Features/Island/IslandController.swift` |
| Çentik yüzeyini ve üst düğmeleri düzenlemek | `Sources/Features/Island/IslandView.swift` |
| Animasyon hesabını değiştirmek | `Sources/Features/Island/Animation/` |
| Widget kartlarının yerleşimini değiştirmek | `Sources/Features/Widgets/Layout/WidgetDrawerLayout.swift` |
| Widget ekleme, kaldırma ve sıralama arayüzünü düzenlemek | `Sources/Features/Widgets/Views/WidgetDrawerView.swift` |
| Saatin görünümünü değiştirmek | `Sources/Features/Widgets/Clock/ClockWidgetView.swift` |
| Saat ve tarih biçimini değiştirmek | `Sources/Features/Widgets/Clock/ClockReadout.swift` |

Akış: `NotchLabApp` uygulamayı başlatır. `AppDelegate`, ortak `NotchSettings`
nesnesini ve `IslandController` nesnesini oluşturur. Controller native pencereyi,
fare olaylarını ve animasyonu yönetir; `IslandState` üzerinden arayüzü günceller.
`IslandView`, widget çekmecesini gösterir. `WidgetDrawerLayout` hem arayüzün hem
native pencerenin kullandığı boyutları hesaplar.

`NotchSettings`, tercihleri `UserDefaults` ile saklar. Mevcut `island.*`
anahtarları ve `com.local.NotchLab` uygulama kimliği korunmuştur; bu düzenleme
kayıtlı tercihlerin sıfırlanmasını gerektirmez.

## Yeni Swift dosyası veya widget ekleme

Yeni dosyayı Xcode'da ilgili klasör grubunda oluştur ve uygulamanın **Target
Membership** seçeneğinin işaretli olduğunu kontrol et. Finder üzerinden
oluşturursan dosyayı Xcode'a da ekle; proje açık dosya referansları kullanır.
Dosyanın diskteki yerinin de ilgili `Sources/` klasöründe olduğundan emin ol.

Yeni widget için `Widgets/` altında kendi klasörünü oluştur. Türünü ve boyutunu
`WidgetKind` içinde tanımla; görünümünü `WidgetDrawerView.widgetContent` içindeki
`switch` ifadesine bağla. Katalog `WidgetKind.allCases` üzerinden oluşur.
Yerleşim kuralları değişiyorsa `Tests/WidgetTests.swift` içindeki ilgili
senaryoları da güncelle.

Swift'te `private`, erişimi tanımlandığı kapsamla sınırlar. Farklı dosyalardan
kullanılan tipler burada varsayılan `internal` erişimindedir; bu, yalnızca aynı
uygulama modülü içinden kullanılabildikleri anlamına gelir. Tiplerin kendi
yardımcı fonksiyonları ve iç durumları `private` kalır.

## Derleme ve test

Komutları bu README'nin bulunduğu klasörde çalıştır:

```sh
xcodebuild -project "leagent notch.xcodeproj" \
  -scheme "leagent notch" -configuration Debug \
  -derivedDataPath build build

bash Tests/run.sh
```

Test çalıştırıcısı `Sources/` altındaki Swift dosyalarını otomatik bulur.
Testler uygulamayı başlatmadan gerçek üretim tiplerini sınar; geçici derleme
klasörünü ve test tercihlerinin saklandığı alanları temizler. Ayrıntılar ve
elle kontrol edilecek arayüz davranışları [Tests/README.md](Tests/README.md)
dosyasındadır. Bu testler ayrı betikle çalışır; Xcode'da XCTest hedefi yoktur.

İkon kaynakları ve yeniden üretim komutu [Branding/README.md](Branding/README.md)
dosyasındadır. Üretilen ikonlar `Resources/Assets.xcassets` içine yazılır.
