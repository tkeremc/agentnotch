# agentnotch

SwiftUI ve AppKit ile yazılmış, menü çubuğunda çalışan bir macOS uygulaması.
Fare çentiğe geldiğinde saat ve müzik çalar widget’larının bulunduğu çekmece açılır.
Sol üstteki ev ve çekmece ikonları widget’lar ile dosya deposu arasında geçiş yapar.
macOS 14 ve üzerini destekler; harici paket bağımlılığı yoktur.

## Çalıştırma

1. Bu klasördeki `agentnotch.xcodeproj` dosyasını Xcode ile aç.
2. `agentnotch` şemasını ve `My Mac` hedefini seç.
3. `⌘R` ile çalıştır.
4. Fareyi çentiğe getir. Çentiksiz ekranda alan üst ortada görünür.
5. Menü çubuğundaki simgeden ayarlara ulaşabilir veya uygulamayı kapatabilirsin.

Proje yerel geliştirme için ad-hoc imzalanır; geliştirme ekibi seçmek gerekmez.
Xcode proje dosyası, kaynaklar ve kaynak görseller bu Git deposunun içindedir.

## Müzik çalar

Sistemin Şu An Çalınan bilgisine katılan müzik ve video uygulamalarını otomatik
izler; Music, Spotify ve tarayıcıların paylaştığı medya oturumları bu kaynağı
kullanabilir. Çentik kapalıyken kapak için yalnız sola 44 pt genişler. Kapağa
tıklamak ana sayfayı açar. Oynatma duraklatıldığında küçük kapak 10 saniye
sonra animasyonla çentiğin içine çekilir; oynatma sürdürülünce geri gelir.
Duraklatılmış parça ve kontroller açık çekmecede kalır. Açık kartta başlık, sanatçı/kanal, kaynak uygulama,
süre ve önceki–oynat/duraklat–sonraki düğmeleri bulunur. Medya kaynağı kapak
paylaşmıyorsa müzik simgesi gösterilir; bilinmeyen süre uydurulmaz.

Yeni kurulumda saat ve müzik çalar birlikte gelir. Kayıtlı widget seçimleri
korunur; mevcut kurulumda üstteki düzenle düğmesinden **Müzik çalar** eklenebilir.
Widget kaldırıldığında veya çentik gizlendiğinde medya dinleyicisi kapanır.
Bağlantı kurulamazsa karttaki **Yeniden bağlan** düğmesi yeniden dener.

Medya katmanı `Sources/Features/Widgets/Media/` içindedir. Xcode, özgün
`Native/NowPlayingBridge.m` kaynağını derleyip imzalar ve küçük Perl host ile
uygulamaya paketler; indirme, Homebrew veya kullanıcı kurulumu gerekmez.
Uygulamanın sandbox’ı açık kalır; yalnız `com.apple.mediaremoted.xpc` ve
`com.apple.mediacontrol.xpc` servisleri için Mach lookup istisnası tanımlıdır.
Automation, Accessibility veya ağ izni kullanılmaz.

Sistem genelindeki medya verisi public macOS API’sinde sunulmadığından bu
özellik private MediaRemote API’sini kullanır. macOS 15.4 ve sonrasındaki
istemci kısıtı için sistem Perl host tekniği kullanılır; teknik dayanak
[MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter) projesidir.
Projeye bu kaynaktan kod veya hazır binary eklenmemiştir. Apple bu API’yi
ileride değiştirebilir; bu entegrasyon Mac App Store dağıtımına uygun kabul
edilmemelidir. Sistem Şu An Çalınan bilgisine katılmayan uygulamalar algılanmaz.

## Dosya deposu

Finder’da bir dosya ya da klasörü sürüklemeye başladığında çentiğin altında küçük
bir depo göstergesi belirir. Dosyaları çentiğe yaklaştırdığında depo
otomatik açılır; kesikli çerçeveli alana bıraktığında dosyaların bağlantıları
saklanır. Dosyaların asılları yerlerinde kalır ve depo uygulama yeniden
başlatıldığında korunur. Aynı dosya tekrar eklenmez.

Bir dosyayı geri almak için kartın ikonunu dışarı sürükleyip Finder’a veya dosya
kabul eden başka bir uygulamaya bırak. Hedef kabul ederse kart depodan kalkar;
iptal edilen veya reddedilen sürüklemede kalır. Finder’a bırakmak dosyayı
kopyalar, asıl dosyayı taşımaz. Kartın üstündeki çöp kutusu da yalnızca depo kaydını kaldırır.
Silinen ya da erişimi kaybolan dosyalar depoda erişilemiyor olarak gösterilir.

Depo yerel dosya ve klasörleri destekler; metin, web bağlantısı ve henüz dosyaya
dönüşmemiş sürükleme içerikleri (örneğin Mail ekleri için file promise) desteklenmez.
Kayıtlar uygulamanın Application Support dizininde `AgentNotch/FileShelf.json`
dosyasında salt okunur security-scoped bookmark olarak tutulur.

## Klasör yapısı

```text
agentnotch/
├── agentnotch.xcodeproj/      # Xcode hedefi, derleme ayarları ve ortak şema
├── Sources/                     # Uygulamaya derlenen Swift kodları
│   ├── App/                     # Başlangıç, uygulama yaşam döngüsü, menü
│   ├── Localization/            # Dil çözümleme, kaynak seçimi ve tip güvenli metin anahtarları
│   └── Features/
│       ├── Island/               # Çentik yüzeyi ve açılma/kapanma yönetimi
│       │   ├── Animation/        # Hareket ve geçiş hesapları
│       │   └── Window/           # Native panel ve fare takibi
│       ├── Settings/             # Kalıcı tercihler ve ayarlar ekranı
│       └── Widgets/
│           ├── Clock/            # Saat görünümü ve tarih/saat biçimlendirme
│           ├── Media/            # Medya oturumu, kapak ve oynatıcı görünümü
│           ├── Layout/           # Kart konumları ve çekmece boyutları
│           ├── Models/           # Widget türleri ve boyut tanımları
│           └── Views/            # Listeleme, düzenleme ve widget kataloğu
├── Resources/
│   ├── Assets.xcassets/          # Paketlenen uygulama ikonu ve menü simgesi
│   └── Localizable.xcstrings     # İngilizce/Türkçe çeviriler ve çoğul kuralları
├── Configuration/
│   └── Info.plist               # Uygulama kimliği ve macOS bilgileri
├── Tests/                       # Mevcut davranış testleri ve çalıştırıcısı
└── Branding/                    # Düzenlenebilir SVG'ler ve ikon üretim aracı
```

Klasörler kodu sorumluluğuna göre düzenler. Üretim kodu tek bir `AgentNotch`
Swift modülüne derlenir; klasörler arasında ayrıca `import` yazman gerekmez.
`Branding` ve `Tests` altındaki Swift dosyaları uygulama hedefine derlenmez.

## Nerede neyi değiştireceğim?

| Yapmak istediğin | İlgili dosya |
| --- | --- |
| Uygulamanın başlangıcını değiştirmek | `Sources/App/AgentNotchApp.swift` |
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
| Müzik çaları ve medya bağlantısını değiştirmek | `Sources/Features/Widgets/Media/` ve `Native/` |
| Saat ve tarih biçimini değiştirmek | `Sources/Features/Widgets/Clock/ClockReadout.swift` |
| Metin çevirmek veya yeni dil eklemek | `Resources/Localizable.xcstrings` ve `Sources/Localization/` |

Akış: `AgentNotchApp` uygulamayı başlatır. `AppDelegate`, ortak `NotchSettings`
nesnesini ve `IslandController` nesnesini oluşturur. Controller native pencereyi,
fare olaylarını ve animasyonu yönetir; `IslandState` üzerinden arayüzü günceller.
`IslandView`, widget çekmecesini gösterir. `WidgetDrawerLayout` hem arayüzün hem
native pencerenin kullandığı boyutları hesaplar.

`NotchSettings`, tercihleri `UserDefaults` ile saklar. Mevcut `island.*`
anahtarları ve `com.local.NotchLab` uygulama kimliği ad değişikliğinde korunur;
böylece kayıtlı tercihler kullanılmaya devam eder.

## Çoklu dil

İlk açılışta **Sistem varsayılanı** seçilidir. macOS'un tercih edilen diller
listesindeki ilk desteklenen dil kullanılır: `tr-TR`, `tr-CY` gibi Türkçe
varyantları Türkçeye; `en-US`, `en-GB` gibi İngilizce varyantları İngilizceye
eşlenir. Listede desteklenen dil yoksa İngilizce kullanılır. Kullanıcı
**Ayarlar → Genel → Dil** alanından **İngilizce** veya **Türkçe** seçerek bu
seçimi geçersiz kılabilir; tekrar Sistem seçeneğine dönerek otomatik seçimi
açabilir. Tercih `island.language` anahtarında `system`, `en` veya `tr` olarak
saklanır. Eksik/eski/geçersiz değerler otomatik seçimle açılır.

`NotchSettings` ortak dil durumunu tutar; `AppLocalization` açık dil bundle'ını
seçer ve `L10nKey` anahtarlarını String Catalog'dan çözer. İngilizce kaynak ve
fallback dilidir. Uygulamanın menüsü, açık ayarlar penceresinin başlığı, çentik,
widget'lar, araç ipuçları ve erişilebilirlik metinleri yeniden başlatmadan
çevrilir. macOS locale değişimi bildirildiğinde otomatik seçim yenilenir;
kullanıcının açık dil tercihi korunur. Global `AppleLanguages` değiştirilmez.
Ada controller'ı, animasyonlar ve sürükleme durumu dil değişiminde yeniden
oluşturulmaz. Sistem renk seçicisi gibi macOS'un yönettiği pencereler kendi
sistem dilini kullanabilir.

Tarih/gün adları seçilen dili, sayı/tarih biçimleri sistem bölgesini ve saat
sistem saat dilimini kullanır. Saat her iki dilde de 24 saat düzenindedir.
Dosya deposu hataları hazır metin yerine hata türü ve dosya adını saklar;
böylece ekranda duran hata da yeniden çevrilir. Dosya adları ve yollar aynen
korunur. Öğe sayıları katalogdaki gerçek çoğul kurallarıyla biçimlendirilir.

Yeni kullanıcı metni eklerken:

1. `L10nKey` içine anlamlı, sabit bir anahtar ekle (`settings.language` gibi).
2. `Localizable.xcstrings` içine İngilizce/Türkçe çevirileri ve çevirmen
   açıklamasını ekle. Dinamik anahtarlar kullanıldığı için katalog kayıtları
   `extractionState: manual` olarak tutulur.
3. Görünümde `settings.localization.text(.settingsLanguage)` kullan. Dinamik
   metni birleştirmek yerine katalogdaki `%@` / konumsal `%1$@` yer tutucularına
   argüman geçir. Sayılar için uygun türü kullan; `shelfItemCount` `%lld` ve
   `Int64` ile çoğul kullanımına örnektir. Arayüz köküne aynı locale'i geçir.
4. `bash Tests/run.sh` çalıştır. Testler her tip güvenli anahtarın her iki dilde
   gerçekten derlenmiş kaynakta bulunmasını doğrular.

Yeni dil eklerken `AppLanguage` ve `LanguagePreference` türlerini, tercih adını,
katalog çevirilerini ve Xcode `knownRegions` listesini genişlet. İki proje
başlatıcısında da kaynak üyeliğini tutarlı tut. Çeviriler Swift koduna gömülmez;
Xcode'un String Catalog editörü veya XLIFF içe/dışa aktarma akışı kullanılabilir.

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
xcodebuild -project "agentnotch.xcodeproj" \
  -scheme "agentnotch" -configuration Debug \
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
