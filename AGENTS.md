# AgentNotch geliştirme rehberi

Bu dosya projeye katkı sunan geliştiriciler ve kod ajanları için geçerlidir.
AgentNotch, kişisel bir ihtiyaçtan doğmuş, MIT lisanslı bir macOS uygulamasıdır.
Mevcut davranışı koruyan, anlaşılır ve kapsamı belirli değişiklikler yap.

## Proje yapısı

- `Sources/App/`: Uygulama başlangıcı, yaşam döngüsü ve menü çubuğu.
- `Sources/Features/Island/`: Çentik paneli, hover ve animasyonlar.
- `Sources/Features/Widgets/`: Saat/takvim, medya, Codex, Claude ve ortak izleme.
- `Sources/Features/FileShelf/`: Kalıcı dosya bağlantıları ve sürükle/bırak.
- `Sources/Features/Settings/`: Tercihler ve ayarlar arayüzü.
- `Sources/Localization/` ve `Resources/Localizable.xcstrings`: Türkçe/İngilizce metinler.
- `Native/`: Uygulamaya derlenip paketlenen medya ve hook yardımcıları.
- `Configuration/`: Uygulama bilgileri ve sandbox izinleri.
- `Tests/`: Üretim tiplerini kullanan testler; çalıştırıcısı `Tests/run.sh`.
- `Research/`: Araştırma, sentetik görsel kontroller ve izole sandbox denemeleri.

## Geliştirme kuralları

- macOS 14 desteğini koru. Yeni paket bağımlılıklarını gerekçelendir.
- Yeni Swift dosyalarını ilgili klasöre ve Xcode hedefinin dosya listesine ekle.
- Görünümlerde veri okuma veya hook kurulumu yapma; mevcut store ve installer
  ayrımını koru. Dosya tarama ve ayrıştırma işlerini ana iş parçacığında çalıştırma.
- Kullanıcıya görünen metinleri `L10nKey` ve String Catalog üzerinden ekle;
  Türkçe ve İngilizce karşılıklarını birlikte güncelle.
- `island.*` tercih anahtarlarını ve `com.local.NotchLab` uygulama kimliğini
  veri geçişi planı olmadan değiştirme; mevcut kullanıcı tercihleri bunlara bağlıdır.
- İlgisiz kullanıcı değişikliklerini geri alma. Değişikliği görev kapsamıyla sınırla.

## Veri ve izin sınırları

- Hook kurma, onarma ve kaldırma işlemlerini kullanıcının açık uygulama içi
  onayıyla yap. Başlatma, izleme veya test sırasında sessizce hook kurma.
- Diğer hook'ları, Claude'un mevcut statusline ayarını ve kullanıcı
  değişikliklerini koru. Codex'in güven kararlarını otomatik değiştirme.
- Kimlik bilgilerini okuma; prompt, komut, konuşma veya araç çıktısını olay
  kuyruğuna kaydetme. Olay metadata'sını sınırlı ve yerel tut.
- Eksik kota veya belirsiz etkinlik için bilinmiyor/güncelleme bekleniyor
  durumunu kullan. Sessizliği çalışıyor veya tamamlandı kanıtı sayma.
- Sandbox izinlerini dar tut. Dosya okumalarında sahiplik, symlink ve boyut
  kontrollerini; atomik yazma ve süreçler arası eşzamanlılık korumalarını sürdür.
- Dosya deposu asılları taşımaz veya silmez; bağlantıları ve salt okunur
  security-scoped bookmark davranışını koru.
- Widget kaldırıldığında veya panel gizlendiğinde ilgili izleyicilerin
  durmasını, dosya tanımlayıcılarının kapanmasını ve önbelleklerin bırakılmasını koru.

## Doğrulama

Komutları bu dosyanın bulunduğu proje kökünde çalıştır:

```sh
xcodebuild -project agentnotch.xcodeproj -scheme agentnotch \
  -configuration Debug -derivedDataPath build build
bash Tests/run.sh
```

Codex/Claude/izleme değişiklikleri için odaklı testler:

```sh
AGENTNOTCH_TEST_SCOPE=codex bash Tests/run.sh
```

- Davranış değişikliklerinde ilgili regresyon testlerini ekle veya güncelle.
  Yalnız dokümantasyon değişikliklerinde uygulama derlemesi gerekmez.
- Testlerde geçici dizin ve izole tercihler kullan; gerçek Codex/Claude
  ayarlarını, hesaplarını veya hook güvenini değiştirme.
- Bileşen testlerini tam uygulama derlemesinden; sentetik kontrolleri gerçek
  istemci ve GUI kontrollerinden ayrı raporla. Sandbox kaynaklı engelleri belirt.
- Arayüz değişikliklerinde Türkçe/İngilizce görünümü ve ilgili hover,
  sürükle/bırak, kaydırma veya animasyon davranışını elle doğrula.
- CPU, bellek veya pil kazancı iddiasını gerçek önce/sonra ölçümüne dayandır.
  Çalıştırmadığın testi veya yapmadığın ölçümü başarılı gibi sunma.
- Dağıtım için Release derlemesini ayrıca doğrula. Medya özelliğinin private
  MediaRemote API'sine bağlı olduğunu ve App Store uygunluğu varsayılmadığını koru.

Test kapsamları ve elle kontrol adımları için `Tests/README.md` dosyasına bak.
MIT lisansını ve `Design/ThirdParty/` altındaki lisans bildirimlerini koru.
