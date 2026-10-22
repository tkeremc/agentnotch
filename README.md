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
Kontroller, başka bir uygulama odaktayken ilk tıklamada çalışır. Komutlar açık
medya bağlantısından gönderilir; her basışta yeni yardımcı süreç başlatılmaz.
Kapak normal metadata içinde yoksa sistemin ayrı kapak isteği de denenir;
geç gelen sonuçlar parça kimliğiyle eşleştirilir.
Alınan kapak bellekte tutulur. Aynı oturumda pencere odağı değişince eksilen
metadata alanları kapağı silmez; kaynak, parça veya kapak açıkça değişince
önceki görsel bırakılır.
Bilinen sorun: Zen’in sistem medya akışında kapak bulunmayan oturumlarda görsel
hâlâ görünmeyebilir. Kapak sorunu henüz çözülmüş kabul edilmemelidir; tarayıcı
adresini okuyarak kapağı indiren ek bir entegrasyon bulunmaz.

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

## Codex widget’ı

Widget düzenleme kataloğundan **Codex** eklenebilir. Kart, Codex’in bu Mac’te
en son kaydettiği kota pencerelerini, kalan kullanım yüzdesini, yenilenme
zamanını ve bilginin yaşını gösterir. Yeniden hesap girişi veya API anahtarı
gerekmez. Kota henüz kaydedilmemişse ya da birden çok hesaba ait kayıt varsa
bilinmeyen değerler yüzde sıfır gibi gösterilmez. GPT ikonu taşıyan 180 pt
yüksekliğindeki kartta kota pencereleri solda, ajanlar ve izin uyarıları sağdadır.

Ana ajan ve alt ajan etkinliği mevcut oturum kayıtlarından salt okunur olarak
izlenir; sohbet başlığı, klasör ve üst/alt ilişkiler gösterilir. Başlıklar yalnız
salt okunur `session_index.jsonl` metadata dosyasından alınır; başlık yoksa
ajan/proje adı gösterilir. Liste kaydırılabilir. Başlangıç,
bitiş, kesilme, görev hatası ve araç hatası birbirinden ayrılır. Kapalı çentikte
çalışma yeşil, izin isteği turuncu, hata kırmızı gösterilir. Kaynak yazmayı
bırakırsa durum bilinmiyor olur; tamamlanmış sayılmaz.

İzin uyarıları için karttaki **Bağlan** düğmesini veya ayarlardaki
**Codex bağlantısı** bölümünü kullan. Karttaki **Bağlan**, ayarlar penceresini
açar. Ayarlar açıkken çentik menüsü kapanır ve fare girişini engellemez;
pencere kapatılınca veya küçültülünce normal davranış geri gelir.
Uygulama standart `.codex` konumunu
kendisi bulur; klasör seçmen gerekmez. **Etkinleştir** onayı verilince mevcut
hook tanımlarını koruyarak kendi kullanıcı düzeyi entegrasyonunu ekler.
Hook, uygulama paketindeki imzalı yardımcı programı doğrudan çalıştırır;
`.codex` içine çalıştırılabilir dosya kopyalanmaz. Önceki kurulum için
**Onar** görünür. Onarım yalnız sahipliği doğrulanmış eski tanımları ve
eski yardımcı kopyasını değiştirir; kullanıcı tarafından değiştirilmiş dosyalar
korunur. Uygulamanın konumu değişirse bağlantı yeniden onarılmalıdır.
Vazgeçersen hiçbir kurulum dosyası yazılmaz. Ardından Codex’te `/hooks`
üzerinden yeni tanımları inceleyip güvenilir olarak onaylamak gerekir;
AgentNotch bu güven kararını otomatik yazmaz. Sonraki desteklenen yerel
oturumlarda proje/ajan etkinliği ve izin isteği olayları otomatik iletilir.

İzin isteği geldiğinde kapalı çentiğin sağında turuncu bir gösterge belirir;
tıklamak widget çekmecesini açar. Açık kartta proje ve varsa kısa izin gerekçesi
görünür. Bu bildirim Codex’in onay ekranının yerine geçmez. İstek kimliği
eşleşen araç sonucu, görev bitişi veya kesilme uyarıyı temizler. Codex istek
kimliği sağlamadığında başka bir paralel araç sonucuna bakarak kapandığı
varsayılmaz; belirsiz eski istek beş dakika sonra bilinmiyor olur.

Ayarlardaki **Bağlantıyı kaldır** yalnız AgentNotch tanımlarını ve varsa
sahipliği doğrulanmış eski yardımcı kopyasını kaldırır; paket içindeki
program ve diğer hook’lar korunur. Yeniden ekleme aynı tanımları
çoğaltmaz. Değişen hook tanımları Codex’te tekrar güven onayı gerektirebilir.
İlk açılış sihirbazı henüz eklenmedi; aynı kurulum/kaldırma katmanı hazırdır.

Ortak yardımcı Xcode tarafından `Native/CodexHookBridge.swift` kaynağından
derlenip paketlenir. Prompt, komut, tool çıktısı veya kimlik bilgisi kaydetmez;
yalnız sınırlı olay metadata’sını özel yerel kuyruğa yazar. Kota ve görev yaşam
döngüsü için `sessions` kayıtları, sohbet adı için `session_index.jsonl` okunur. Alt ajan hook kimliği gerektiğinde
hook'un sağladığı transcript'in ilk metadata satırından sınırlı olarak çıkarılır;
konuşma metni saklanmaz. İstek kimliği olmayan onaylar, yalnız tek bir eşleşen
PreToolUse çağrısı varsa opak girdi özetiyle araç kimliğine bağlanır; aynı girdili
paralel çağrılar tahmin edilmez. App Sandbox açık kalır: standart `sessions` için
salt okunur; yalnız `hooks.json` ve entegrasyonun kendi `agentnotch/` dizini için
yazma istisnası vardır. Atomik hook güncellemesinin geçici dosyası kendi
dizininde hazırlanır; Codex dizininin tamamına erişim açılmaz. Dosya deposu
bookmark’ları kendi read-only bayraklarını korur.

Uygulama ortamına aktarılmış mutlak `CODEX_HOME` ve önceden kaydedilmiş
klasör izni de tanınır. Standart konum dışındaki dizinlere erişim sandbox
izinleriyle sınırlıdır; erişilemeyen özel konum yerine başka bir Codex
kurulumuna sessizce bağlanılmaz. Tüm kullanıcı dizini veya kimlik dosyaları
taranmaz.

Bulut görevlerinin tamamının gözlemlendiği veya sessiz bir ajanın hâlâ çalıştığı
varsayılmaz. Kota reset zamanı geçmişse yeni gözlem gelene kadar güncelleme
beklenir. Yerel ad-hoc build doğrulaması, Mac App Store istisna onayı anlamına
gelmez. Mimari ve test planı: `Research/CodexReadOnly/IMPLEMENTATION_PLAN.md`.

## Yerel izleyicilerin kaynak tüketimi

Codex ve Claude izleyicileri oturum dosyalarını, olay kuyruğunu ve bağlantı
kurulumunu ayrı değişiklik kaynakları olarak izler. Normal durumda bir araç
olayı yalnız olay kuyruğunu yeniler; aynı olay helper hash'ini yeniden
hesaplatmaz veya bütün Codex geçmişini taratmaz. Oturum dosyası değiştiğinde
bilinen JSONL dosyasının yalnız eklenen bölümü okunur. Yeni klasörler ve
kurtarma gerektiren değişikliklerde keşif yeniden yapılır.

Native dosya/klasör bildirimleri FSEvents ile birlikte kullanılır. Her sağlayıcı
başına en fazla 128 native dosya tanımlayıcısı tutulur; izlenemeyen veya henüz
oluşmamış yollar hafif metadata kontrolüyle takip edilir. Değişmeyen içerikler
bu kontrolde okunmaz. Bildirimler 100 ms'lik pencerede birleştirilir; yoğun olay
akışı teslimi süresiz ertelemez. Bildirim kaybına karşı 60 saniyede bir tam
uzlaştırma yapılır. Bir saniyelik zamanlama, sessizlik/kota sürelerini bellekte
ilerletir ve yalnız native izlemesi olmayan yolların metadata'sını kontrol eder.

Bağlantı dosyaları veya paket helper'ı değişmedikçe kurulum doğrulaması
önbellekten kullanılır. Kurma, onarma ve kaldırmadaki sahiplik/güvenlik
kontrolleri korunur. Widget kaldırılınca veya uygulama gizlenince bildirim
kaynakları ve dosya tanımlayıcıları kapatılır. Ayrıntılar ve ölçüm sınırları:
[izleme düzeltmesi doğrulama raporu](Research/Performance/CONTINUOUS_MONITORING_FIX_2026-10-22.md).

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

## Claude widget’ı

Widget kataloğundan **Claude** eklenebilir. Codex ile aynı düzeni kullanır;
5 saatlik/haftalık kalan kota, yenilenme zamanı, ana/alt ajanlar ve izin
bekleme durumları gösterilir. Claude simgeleri kapalı çentiğin sağında görünür.
Türkçe ve İngilizce desteklenir. Ek giriş veya API anahtarı gerekmez.

Mevcut Claude Code oturumları yerel süreç kimliğiyle doğrulanan metadata’dan
salt okunur izlenir. Ayrıntılı alt ajan ve kota takibi için karttaki **Bağlan**
düğmesinden **Claude bağlantısı** ayarına git ve bağlantıyı etkinleştir.
Sonra yeni bir Claude Code oturumu başlatıp mesaj gönder. Kota, desteklenen
aboneliklerde ilk API yanıtından sonra Claude’un `statusLine` verisiyle gelir;
API/Bedrock/Vertex gibi kaynaklarda bu abonelik kotası bulunmayabilir.
Proje veya yönetilen ayarlar kullanıcı düzeyi bağlantıyı geçersiz kılabilir.

Bağlantı yalnız `~/.claude/settings.json` içine agentnotch hook’larını ve
mevcut durum çubuğunu saran bir komut ekler; önceki durum çubuğunun ayarları,
girdisi ve normal çıktısı korunur. Takılan durum çubuğu komutu iki saniyede
sonlandırılır. **Bağlantıyı kaldır**, yalnız kendi hook’larını siler ve önceki
durum çubuğunu geri getirir; sonradan seçilmiş bağımsız durum çubuğunu korur.
Uygulama taşınır veya helper güncellenirse **Bağlantıyı onar** kullanılabilir.
Widget’ı kaldırmak izlemeyi durdurur; hook bağlantısını ayarlardan ayrıca
kaldırabilirsin.

Kimlik bilgileri, API anahtarları veya sohbet içerikleri okunmaz. Ağ isteği
yapılmaz. Olay kaydı yalnız oturum/ajan kimliği, proje klasörü adı, araç adı,
izin eşleştirmesi için araç girdisinin SHA-256 özeti ve durum/kota alanları
barındırır; komutlar ve araç çıktıları kaydedilmez. Olaylar yedi gün / 4096
kayıtla sınırlanır. Claude’un özel `sessions` metadata formatı değişirse
bilinmeyen durum gösterilir; statusline çağrısı tek başına çalışıyor kanıtı
sayılmaz. Süresi dolan veya 15 dakikadan eski kota güncel yüzde gibi sunulmaz.

`CLAUDE_CONFIG_DIR` başlangıç ortamında tanımlıysa dikkate alınır. Sandboxed
uygulamanın otomatik erişimi standart `~/.claude/sessions/` ve yalnız
`settings.json` / `agentnotch/` yazma yollarıyla sınırlıdır; özel dizinlerde
macOS erişimi yoksa bağlantı hata durumu gösterilir. `projects/`, geçmiş
sohbetler ve kimlik dosyaları için erişim istisnası eklenmez.

Araştırma, resmî kaynaklar ve veri sınırları:
[Claude araştırma notu](Research/ClaudeReadOnly/README.md).
