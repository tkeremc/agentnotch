# AgentNotch performans inceleme raporu

- **İnceleme tarihi:** 22 Ekim 2026
- **İncelenen depo:** `/Users/tkeremc/DEV/agentnotch/agentnotch`
- **İncelenen commit:** `1b77ca5` — `Add Claude usage and agent monitoring widget`
- **Amaç:** Uygulamanın çalışma sırasındaki CPU, bellek, GPU, dosya sistemi ve enerji maliyetlerini mümkün olduğunca azaltacak iyileştirmeleri belirlemek.
- **Kapsam sınırı:** Bu çalışma araştırma ve raporlama çalışmasıdır. Üretim kodu, uygulama ayarları veya entegrasyon yapılandırması değiştirilmemiştir.
- **Verilerin niteliği:** Canlı gözlemler ve dosya sayımları inceleme anına aittir; yeniden ölçülmedikçe güncel değer olarak kabul edilmemelidir.

> Bu belge ilk incelemenin bulgularını kaydeder. Sonraki kod değişiklikleri ve
> doğrulama sonuçları [sürekli izleme düzeltmesi raporunda](CONTINUOUS_MONITORING_FIX_2026-10-22.md)
> ayrıca tutulur; ilk ölçümler yeni sürümün ölçümü değildir.

## 1. Genel değerlendirme

En büyük iyileştirme fırsatı, arka planda değişiklik olmadığı hâlde tekrarlanan dosya taramalarını, kurulum doğrulamalarını ve arayüz güncellemelerini azaltmaktır. Bunların önemli bir kısmı mevcut görünümü, animasyonları ve özellikleri koruyarak düzenlenebilir.

Canlı kontrolde uygulamada yaklaşık **%33–36 CPU ve 328,8 MB bellek** görülmüştür. Bunlar araştırma sırasında Codex'in de çalıştığı iki kısa CPU gözlemi ve bir bellek gözlemidir; kontrollü boşta kullanım ölçümü değildir. Kesin başlangıç ortalaması olarak kullanılmamalıdır.

Öncelik sırası:

1. Aynı izleme turunda iki kez yapılan kurulum doğrulamasını kaldırmak.
2. Değişmeyen verileri arayüze yeniden yayınlamamak.
3. Olay klasörlerini ve kurulum dosyalarını değişiklik odaklı izlemek.
4. Codex'in bütün oturum ağacını saniyelik yeniden keşfetmesini kaldırmak.
5. Hook yardımcılarının kuyruk temizliği ve kilit maliyetini azaltmak.
6. SwiftUI bağımlılıklarını ve animasyon karesi başına işi daraltmak.
7. Bellek, kapak çözümleme, fare takibi ve dosya deposu maliyetlerini ölçüme göre iyileştirmek.

**Kesin bir toplam performans kazancı henüz hesaplanamaz.** Belirli işlem yollarındaki tekrar azaltımı kaynak kodundan hesaplanabilir; toplam CPU, bellek veya pil kazancı için kontrollü önce/sonra ölçümü gerekir.

## 2. İnceleme kapsamı ve kanıtlar

Başlangıç ve pencere yaşam döngüsü, çentik animasyonları, fare ve sürükleme takibi, bütün widget'lar, Codex/Claude okuyucuları, native yardımcı programlar, dosya deposu, yerelleştirme ve derleme ayarları değerlendirilmiştir.

| Kontrol | Sonuç |
| --- | --- |
| Asıl proje | `agentnotch/agentnotch.xcodeproj`; üst klasördeki eski proje ile karıştırılmamalı |
| İncelenen sürüm | `1b77ca5` |
| İnceleme sırasında çalışma ağacı | Temiz |
| Çalışan uygulama | `/Applications/agentnotch.app` |
| Gözlenen süreç kimliği | `97054`; yalnız inceleme anı için geçerli |
| Canlı CPU gözlemleri | `%35,6` ve `%33,48` |
| Canlı bellek gözlemi | `328,8 MB`; Etkinlik Monitörü'nün gösterdiği değer |
| Kayıtlı widget'lar | Saat, medya, Codex ve Claude |
| Animasyon tercihi | Açık |
| Çalışan binary | Repodaki Release dSYM ile arm64 ve x86_64 UUID eşleşmesi var |
| Swift optimizasyonu | Eşleşen Release sembollerinde Swift için optimizasyon işareti mevcut |
| Yerel işletim sistemi | macOS `27.0.1`, build `26A434` |
| Yerel Xcode | Xcode `27.0`, build `27A266a` |
| Uygulamanın minimum macOS hedefi | macOS `14.0` |

### 2.1. Mevcut doğrulamalar

Çalıştırılan bileşen doğrulaması:

```sh
AGENTNOTCH_TEST_SCOPE=codex bash Tests/run.sh
```

Bu kapsam, adındaki Codex ifadesine rağmen mevcut çalıştırıcıda Claude testlerini de içerir.

| Test grubu | Sonuç |
| --- | --- |
| Swift bileşen testleri | **96/96 geçti** |
| Codex yardımcı program testleri | **9/9 geçti** |
| Claude yardımcı program testleri | **13/13 geçti** |
| Native medya kontrolleri | Geçti |
| `git diff --check` | Sorun bildirmedi |

Bu sonuçlar mevcut davranış için başlangıç kanıtıdır. Performans kazancını, tam uygulamanın görsel davranışını veya bütün masaüstü etkileşimlerini kanıtlamaz.

Tam masaüstü/pasteboard test paketi ve kontrollü Instruments kaydı bu incelemede tamamlanmamıştır.

### 2.2. Ölçüm sınırları

- Terminalden süreç listesi ve bazı donanım sorguları ortam izinleri nedeniyle alınamamıştır.
- Çağrı yığını örneklemesi terminalden süreç inceleme yetkisine takılmıştır.
- Etkinlik Monitörü üzerinden örnekleme girişimi bilgisayar kullanım aracındaki hataya takılmıştır; kullanılabilir çağrı yığını elde edilmemiştir.
- Bu nedenle CPU'nun hangi yüzdesinin hangi bileşene ait olduğu belirlenememiştir.
- Canlı gözlemler sırasında Codex etkin olduğundan bunlar boşta kullanım ölçümü değildir.
- Bellek değeri uygulamanın ayrıntılı heap veya fiziksel footprint dağılımı olarak yorumlanmamalıdır.
- Ana süreç ölçümü, Perl medya host'unun ve kısa ömürlü hook yardımcılarının bütün maliyetini içermez.
- Kaynak kodundan hesaplanan işlem sayıları, ölçülmüş sistem çağrısı, fiziksel disk okuması veya enerji tüketimi değildir.

## 3. Korunması gereken mevcut iyi uygulamalar

1. Çentik animasyonu durulduğunda `CADisplayLink` kapatılıyor.
2. Çekmece tamamen kapanınca geniş içerik görünüm ağacından çıkarılıyor; saat ve medya zaman çizelgeleri de kaldırılıyor.
3. Seçili olmayan Codex/Claude widget'larının izleyicileri çalıştırılmıyor.
4. Uygulama gizlendiğinde izleyiciler ve medya bağlantısı durduruluyor.
5. Codex oturum içerikleri normal yenilemelerde dosya konumundan itibaren artımlı okunuyor.
6. Medya komutları mevcut bağlantıdan gönderiliyor; her düğme basışında yeni süreç başlatılmıyor.
7. Medya yardımcısı aynı çıktıyı yeniden göndermeyi engelliyor ve kapak önbelleği kullanıyor.
8. Dosya deposu asıl dosyaları kopyalamıyor; security-scoped bookmark saklıyor.
9. Dosya deposu ve ajan listelerinde tembel oluşturulan liste yapıları bulunuyor.
10. İzleyicilerin dosya işleri ayrı utility kuyruklarında; bunların ana iş parçacığına taşınmaması gerekiyor.

Özellikle sabit pencere alanı, açılma/kapanma sıralaması, içerik görünürlüğü ve native dosya sürükleme yaşam döngüsü korunmalıdır. Bunları yeniden tasarlamak ilk performans paketinin gereği değildir.

## 4. Ayrıntılı bulgular

### P01 — Codex'in saniyelik bütün oturum ağacı taraması

**Öncelik:** Çok yüksek. **Uygulama riski:** Orta.

**Kaynak:** [CodexUsageReader.swift](../../Sources/Features/Widgets/Codex/CodexUsageReader.swift), özellikle `refresh`, `discover` ve `read`; başlangıç satırları 109, 205 ve 224.

#### Mevcut davranış

Okuyucu içerik bakımından artımlıdır; ancak dosya keşfi bakımından her yenilemede aynı işi yapar:

1. Oturum dizininin alt klasörlerini dolaşır.
2. Dosya özelliklerini alır.
3. JSONL dosyalarını toplar ve sıralar.
4. Her JSONL dosyasını açar.
5. İlk 128 baytı okur.
6. Dosyanın değişip değişmediğini ve yeni içerik bulunup bulunmadığını kontrol eder.
7. Bütün dosyalardan elde edilmiş durumları tekrar birleştirir.

Geçmişte bitmiş ve artık değişmeyen oturumların da sürekli maliyeti vardır.

#### İnceleme anındaki veri

| Veri | Gözlem |
| --- | ---: |
| JSONL dosyası | 58 |
| JSONL toplam mantıksal boyutu | Yaklaşık 73,3 MiB |
| JSONL satırı | Yaklaşık 19.678 |
| Sıkıştırılmış `.zst` dosyası | 201 |

Sıkıştırılmış dosyalar içerik olarak okunmaz; dizin keşfi sırasında karşılaşılır. Toplam dosya sayısı ile gerçekten açılan JSONL sayısı birbirine karıştırılmamalıdır.

Her saniye bir tam yenileme varsayımıyla 58 JSONL dosyası, **saatte yaklaşık 208.800 dosya açma işlemi** anlamına gelir. Bu nominal hesap, gerçek sistem çağrısı ölçümü değildir. Zamanlayıcı sapmaları ve yenileme koşulları gerçek sayıyı değiştirebilir.

#### Önerilen düzenleme

- İlk açılışta keşif yapmak.
- Sonrasında değişen dosya ve klasörleri takip etmek.
- Aktif oturumların yalnız eklenen bölümlerini okumak.
- Değişmeyen geçmiş dosyaları sürekli açmamak.
- Bildirim kaybına karşı seyrek bir tam uzlaştırma taraması bırakmak.
- Dosya silinmesi, değiştirilmesi, kısalması ve aynı adla yenilenmesini mevcut doğruluk kurallarıyla ele almak.

Ana klasördeki basit bir klasör izleyicisinin bütün alt klasörlerdeki içerik değişikliklerini kapsadığı varsayılmamalıdır. Recursive izleme yöntemi ve mevcut sandbox izinleri gerçek imzalı uygulamada doğrulanmalıdır. Binlerce dosyayı sürekli açık tutan bir çözüm de yeni kaynak maliyeti yaratabilir.

#### Beklenen sonuç ve korunacak davranış

Geçmiş oturum sayısıyla artan sürekli CPU ve dosya sistemi işi belirgin biçimde azalabilir. Kullanıcıya görünen düzenin değişmesi gerekmez.

Yeni dosyanın kaçırılması, hesap belirsizliğinin yanlış çözülmesi, eski kota bilgisinin seçilmesi ve oturum durumunun yanlış birleştirilmesi önlenmelidir. Yalnız son birkaç dosyayı okumak güvenli bir eşdeğer sayılmamalıdır.

**Dayanak:** [Apple: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html), [Apple: Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

### P02 — Aynı izleme turunda çift kurulum doğrulaması

**Öncelik:** Çok yüksek. **İlk adımın riski:** Düşük. **Önbellek aşamasının riski:** Orta.

**Kaynaklar:** [CodexHookInstaller.swift](../../Sources/Features/Widgets/Codex/CodexHookInstaller.swift), `isInstalled` ve `needsRepair`, satır 65 ve 84; [ClaudeHookInstaller.swift](../../Sources/Features/Widgets/Claude/ClaudeHookInstaller.swift), satır 76 ve 95.

#### Mevcut davranış

Her izleme turunda önce `isInstalled` hesaplanır. Ardından bağlantı durumunu belirlemek için çağrılan `needsRepair`, kendi içinde yeniden `isInstalled` hesaplar.

Geçerli kurulum doğrulaması şunları içerebilir:

- Kurulum yollarını kontrol etmek.
- Manifest okumak.
- Yardımcı programın tamamını okumak ve SHA-256 hesaplamak.
- Hook yapılandırmasını okumak ve çözümlemek.
- Entegrasyona ait tanımları karşılaştırmak.

#### Nicel bulgu

| Paketlenmiş yardımcı | Boyut |
| --- | ---: |
| Codex | 192.656 bayt |
| Claude | 230.384 bayt |

İki widget çalışırken ve her biri saniyede iki tam doğrulama yaparken, yalnız helper hash'leri için işlenen nominal veri:

```text
(192.656 + 230.384) × 2 × 3.600
= 3.045.888.000 bayt/saat
≈ 3,05 GB/saat
```

Bu fiziksel SSD okuması veya disk yazması değildir. Sistem önbelleği kullanılsa da okuma, hash, nesne oluşturma ve yapılandırma çözümleme işi tekrarlanır. Hesap, ilgili doğrulama yoluna ulaşan geçerli kurulum ve saniyelik tur varsayımına bağlıdır.

#### Önerilen düzenleme

1. Tek turda kurulum durumunu bir kez hesaplamak ve bütün kararları bu sonuçtan üretmek.
2. Kurulum durumunu önbelleğe almak; ilgili dosya veya uygulama paketi değişince geçersiz kılmak.
3. Kurma, onarma ve kaldırma gibi gerçek değişikliklerden hemen önce tam doğrulamayı korumak.

#### Beklenen sonuç ve korunacak davranış

İlk adım bu doğrulama yolundaki tekrarın yaklaşık yarısını kaldırır. Değişiklik odaklı önbellek, değişmeyen kurulumda tekrarların büyük çoğunluğunu kaldırabilir.

Uygulamanın taşınması, helper güncellenmesi, manifest veya hook dosyasının dışarıdan değiştirilmesi doğru yakalanmalıdır. Hash ve sahiplik kontrolleri kaldırılmamalıdır.

### P03 — Codex/Claude olay klasörlerinin saniyelik listelenmesi ve sıralanması

**Öncelik:** Yüksek. **Risk:** Orta.

**Kaynaklar:** [CodexStore.swift](../../Sources/Features/Widgets/Codex/CodexStore.swift), `CodexMonitor.poll`, satır 126; [ClaudeStore.swift](../../Sources/Features/Widgets/Claude/ClaudeStore.swift), `ClaudeMonitor.poll`, satır 62.

#### Mevcut davranış

İki izleyici de saniyelik zamanlayıcı kullanır. `seenFiles` sayesinde önceden okunmuş olaylar yeniden çözülmez; ancak yeni olay bulunmasa bile klasör listelenir, dosyalar filtrelenir ve tarihe göre sıralanır.

İnceleme anında Codex kuyruğunda **717**, Claude kuyruğunda **223** JSON dosyası vardır. Yaklaşık 940 kaydın listesi ve sıralama girdileri tekrar değerlendirilir. Kaynak kodundaki 4096 sınırına yaklaşıldıkça iş büyür; `prefix(4096)` öncesinde sıralama yapılması dikkate alınmalıdır.

#### Önerilen düzenleme

- Olay klasöründeki değişiklikle okuma başlatmak.
- Kısa aralıkta gelen bildirimleri tek okuma turunda birleştirmek.
- Yeni olayların tamamını mevcut sıralama kurallarıyla işlemek.
- Değişmeyen klasörü tekrar sıralamamak.
- Seyrek kurtarma taraması bırakmak.

#### Beklenen sonuç ve korunacak davranış

Boşta dosya sistemi işi ciddi azalabilir; yoğun olay akışında gereksiz ara taramalar da azaltılabilir.

Bildirimleri birleştirmek, olayları atlamak anlamına gelmemelidir. İzin isteği, araç sonucu, görev bitişi ve kesilme olayları kaybedilmemelidir. Birleştirme penceresi sınırlı olmalı; sürekli olay akışında yenileme sonsuza kadar ertelenmemelidir.

### P04 — Değişmeyen verilerin tekrar yayınlanması

**Öncelik:** Çok yüksek. **Risk:** Düşük–orta.

**Kaynaklar:** [CodexStore.swift](../../Sources/Features/Widgets/Codex/CodexStore.swift), `apply`, satır 417; [ClaudeStore.swift](../../Sources/Features/Widgets/Claude/ClaudeStore.swift), `apply`, satır 374.

#### Mevcut davranış

Kullanım, ajanlar, onaylar, bağlantı, son hook zamanı, gösterge ve küçük ajan listesi her turda yeniden atanır. Önceki değerle eşitlik kontrolü yapılmaz.

`@Published` alanına aynı değerin atanması da yayın üretebilir. Store başına sekiz alan, iki store için nominal olarak saniyede 16 alan yayını oluşturabilir. Bu, saniyede 16 ayrı ekran çizimi demek değildir; SwiftUI güncellemeleri birleştirebilir. Buna rağmen abonelik ve görünüm hesapları gereksiz tetiklenebilir.

#### Önerilen düzenleme

- Eşit değerleri tekrar atamamak.
- Görünen verilerden oluşan tutarlı bir durum modeli değerlendirmek.
- Küçük ajan listesini girdileri değiştiğinde üretmek.
- Controller aboneliklerinde uygun tekrar eleme kullanmak.
- Zamana bağlı durum geçişlerini ayrı planlamak.

#### Beklenen sonuç ve korunacak davranış

Sabit veride bu yoldaki gereksiz yayınlar neredeyse tamamen kaldırılabilir.

Dosya değişmese de beş dakika sonra bilinmiyor olması gereken bir ajan veya süresi dolan kota penceresi güncellenmelidir. Gereken sonraki zamana tek seferlik görev planlamak değerlendirilebilir. Eşitlik kontrolleri gerçek kullanıcıya görünen değişiklikleri gizlememelidir.

### P05 — Ana SwiftUI görünümünün geniş gözlem alanı

**Öncelik:** Yüksek. **Risk:** Orta.

**Kaynak:** [IslandView.swift](../../Sources/Features/Island/IslandView.swift), satır 3; ayrıca [WidgetDrawerView.swift](../../Sources/Features/Widgets/Views/WidgetDrawerView.swift).

#### Mevcut davranış

Ana görünüm çentik durumu, ayarlar, dosya deposu, medya, Codex ve Claude nesnelerini izler. Yalnız bir sağlayıcının kotası değişse bile kök görünüm yeniden değerlendirmeye aday olur. Geniş içerik kapalıyken kaldırılır; kökteki gözlem ilişkileri devam eder.

#### Önerilen düzenleme

- Medya kapağı, ajan göstergeleri ve geniş içeriği daha dar bağımlılıklı alt görünümlere ayırmak.
- Her parçaya yalnız ihtiyacı olan veriyi vermek.
- Ana yüzeyi yerleşim ve geçiş durumuyla sınırlandırmak.
- Gerekirse alan bazlı gözlem için `@Observable` değerlendirmek.

`@Observable` geçişi otomatik performans çözümü değildir. Mevcut Combine abonelikleri de değişeceği için önce küçük, ölçülebilir ayrıştırmalar tercih edilmelidir.

#### Beklenen sonuç ve korunacak davranış

Arka plan veri değişimlerinde ve animasyon sırasında daha az görünüm değerlendirmesi beklenir. Tasarım korunabilir; görünüm kimliği, kaydırma konumu ve animasyon sürekliliği doğrulanmalıdır.

**Dayanak:** [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance).

### P06 — Animasyon karesinde değişmeyen alanların yeniden atanması

**Öncelik:** Orta–yüksek. **Risk:** Düşük–orta.

**Kaynak:** [IslandController.swift](../../Sources/Features/Island/IslandController.swift), `animateFrame`, satır 540.

#### Mevcut davranış

Her animasyon karesinde yedi yayınlanan alan güncellenir. Yalnız medya kanadı hareket ederken bile değişmeyen sayfa veya sürükleme ilerleme değerleri tekrar atanabilir.

#### Önerilen düzenleme

- Yalnız değişen değerleri yayınlamak.
- Kare değerlerini tek tutarlı güncellemede taşımayı değerlendirmek.
- Animasyon durumunun değişmesi gerekmeyen widget içeriklerine yayılmasını sınırlamak.

#### Beklenen sonuç ve korunacak davranış

Açılma/kapanma ve sayfa geçişlerinde CPU ve yerleşim işi azalabilir. Tamamen boşta kullanımda katkısı sınırlıdır; display link zaten durur.

İlk tercih kare hızını düşürmek olmamalıdır. Aynı hareket hesapları, süreler, bitiş eşikleri ve yön değiştirme sürekliliği korunarak kare başına maliyet azaltılmalıdır. Yedi yayın, yedi ayrı çizim anlamına gelmez.

### P07 — Tekrarlanan küçük ajan animasyonları

**Öncelik:** Orta. **Görünmeyen animasyonu durdurmanın riski:** Düşük.

**Kaynak:** [IslandView.swift](../../Sources/Features/Island/IslandView.swift), `CompactAgentMark`, satır 194.

#### Mevcut davranış

Çalışan ajan işaretinde tekrarlanan `symbolEffect(.pulse)` vardır. Çok sayıda aktif ajan sürekli çizim maliyetini artırabilir.

Çekmece açıldığında küçük göstergeler saydamlaştırılır; animasyon koşulunda açıkça çekmecenin kapalı olması kontrol edilmez. SwiftUI'ın görünmez içeriği ne ölçüde durdurduğu ölçülmeden kesin tüketim söylenemez.

#### Önerilen düzenleme

- Tamamen görünmeyen göstergelerde animasyonu durdurmak.
- Uygulama gizliyken animasyonu kapatmak.
- Reduce Motion davranışını korumak.

Görünür nabzı seyrekleştirmek veya sabitlemek görsel davranışı değiştirir; ayrı ürün kararıdır.

#### Beklenen sonuç

Özellikle çok aktif ajanlı kullanımda GPU/çizim yükünde azalma potansiyeli vardır. Miktar canlı izleme ile belirlenmelidir.

**Dayanak:** [Apple: Improving your app's rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency).

### P08 — Hook başına bütün kuyrukta temizlik taraması

**Öncelik:** Yüksek. **Risk:** Orta.

**Kaynaklar:** [CodexHookBridge.swift](../../Native/CodexHookBridge.swift), `prune`, satır 50; [ClaudeHookBridge.swift](../../Native/ClaudeHookBridge.swift), `prune`, satır 57.

#### Mevcut davranış

Her yardımcı çağrısı olay yazmadan önce kuyruk kilidini alır, dosyaları dolaşır, özelliklerini kontrol eder, eski/fazla kayıtları temizler ve yeni olayı yazar.

Kuyruk doluyken küçük bir olay eklemek bütün kuyruğu kontrol etmeyi içerir. Araç öncesi/sonrası hook'ları nedeniyle bu maliyet sık tekrar edebilir. Kısa ömürlü helper maliyeti yalnız ana `agentnotch` sürecinin CPU değerinde görünmez.

Kilit alınamazsa 1 ms aralıklarla tekrar deneme de vardır. Eşzamanlı yoğunlukta bekleme ve tekrar deneme yolu ayrıca ölçülmelidir.

#### Önerilen düzenleme

- Her olayda tam temizlik yerine kontrollü aralıklarla temizlik.
- Boyut ve yaş sınırlarını korumak.
- Eşzamanlı yardımcılar arasında temizliği tek katılımcıya bırakmak.
- Kilit altında geçirilen süreyi azaltmak.
- Uygulama kapalıyken de kuyruğun sınırsız büyümemesini sağlamak.

#### Beklenen sonuç ve korunacak davranış

Yoğun araç kullanımında dosya sistemi işi, kilit çekişmesi ve hook gecikmesi azalabilir. Olay teslimi, atomik yazım, sahiplik ve symlink kontrolleri korunmalıdır. Temizlik aralığı değişse de depolama üst sınırı uygulanmaya devam etmelidir.

### P09 — Codex satır işleme ve tampon kapasitesi

**Öncelik:** Orta–yüksek. **Risk:** Orta.

**Kaynak:** [CodexUsageReader.swift](../../Sources/Features/Widgets/Codex/CodexUsageReader.swift), `read`, satır 224.

#### Mevcut davranış

Okuyucu 64 KiB parçalar alır; baytları tek tek dolaşıp satır tamponuna ekler. İlk açılışta ve büyük yeni içerikte bu yol pahalı olabilir.

Satır tamamlandığında tampon `keepingCapacity: true` ile temizlenir. Büyük satırı işlemiş dosyanın tampon kapasitesi daha sonra da tutulabilir.

İncelenen dosyalarda en büyük satır yaklaşık **856 KiB**, her dosyanın en büyük satır boyutlarının toplamı yaklaşık **8,17 MiB** bulunmuştur. İkinci sayı gerçek heap tahsisi değildir; kapasiteyi değerlendirmek için göstergedir. **328,8 MB gözlenen belleğin tamamını bu tamponlarla açıklayan kanıt yoktur.**

#### Önerilen düzenleme

- Satır sonlarını blok içinde bulup aralıklarla işlemek.
- Gereksiz bayt başına eklemeyi azaltmak.
- Çok büyümüş tampon kapasitesini uygun zamanda bırakmak.
- Kısmi son satırı ve uzun satır sınırını korumak.
- Silinmiş dosyalara ait yardımcı indeksleri de temizlemek.
- Dosya kimliği eşlemeleri gibi uzun ömürlü sözlüklerin büyümesini sınırlandırmak.

#### Beklenen sonuç ve korunacak davranış

İlk taramada ve büyük çıktı akışında CPU azalması; geçmişe bağlı bellek büyümesinin sınırlandırılması beklenir.

Kısmi yazım, bozuk satır, uzun satır, dosya değişimi/kısalması, ileri tarihli kayıt ve saat geri alınması senaryoları korunmalıdır. Önbellek kapasitesini gereğinden sık bırakmak yeniden tahsis maliyetini artırabileceği için denge ölçülmelidir.

### P10 — İzleyici durunca önbelleklerin tutulması

**Öncelik:** Orta. **Risk:** Düşük–orta.

**Kaynaklar:** [CodexStore.swift](../../Sources/Features/Widgets/Codex/CodexStore.swift), `stop`, satır 287; [ClaudeStore.swift](../../Sources/Features/Widgets/Claude/ClaudeStore.swift), `stop`, satır 244.

#### Mevcut davranış

Zamanlayıcılar durur; monitor nesneleri ve bazı son veriler tutulur. Bu tekrar açılmayı hızlandırır; widget kaldırıldığında veya uygulama uzun süre gizli kaldığında bellek aynı ölçüde düşmeyebilir.

#### Önerilen yaşam döngüsü

| Durum | Yaklaşım |
| --- | --- |
| Çekmece kapalı | Küçük göstergeler ve uyarılar için izleme devam eder |
| Uygulama kısa süre gizli | Sınırlı yeniden açılış önbelleği tutulabilir |
| Widget kaldırılmış | Widget'a ait büyük okuyucu durumları bırakılabilir |
| Bellek baskısı oluşmuş | Yeniden üretilebilir önbellekler temizlenebilir |

#### Beklenen sonuç ve davranış etkisi

Kullanılmayan özelliklerde daha düşük bellek ve uzun oturumlarda daha kontrollü büyüme beklenir. Önbellek bırakılırsa tekrar açma veya ekleme sırasında yeniden okuma gerekebilir. Bellek ile yeniden açılma hızı arasında tercih vardır.

### P11 — Medya sorguları, kapak çözümleme ve bulanık arka plan

**Öncelik:** Orta. **Risk:** Orta.

**Kaynaklar:** [NowPlayingBridge.m](../../Native/NowPlayingBridge.m), `fetch`, satır 286 ve periyodik timer, satır 399; [NowPlayingStore.swift](../../Sources/Features/Widgets/Media/NowPlayingStore.swift), `receive`, satır 266; [MediaWidgetView.swift](../../Sources/Features/Widgets/Media/MediaWidgetView.swift), `artworkBackdrop`, satır 205.

#### Mevcut davranış

Medya yardımcısı sistem bildirimlerini dinler; ayrıca iki saniyede bir sorgu yapar. Her turda metadata, süreç ve oynatma durumu için üç asenkron API çağrısı vardır.

Yalnız periyodik kontrolün nominal maliyeti:

- Saatte 1800 sorgu turu.
- Saatte 5400 API çağrısı.

Bildirim ve kontrol düğmesi sonrası sorgular buna eklenebilir. Bunlar ölçülmüş fiziksel IPC veya enerji sayıları değildir.

Kapak Base64 çözümü ve `NSImage` oluşturulması ana aktörde yapılır. Sıkıştırılmış kapak boyutu için sınır vardır; bu, açılmış görsel belleğini sınırlamaz.

Örnek olarak tek bir 3000 × 3000 RGBA yüzey yaklaşık **34,3 MiB**, 256 × 256 yüzey yaklaşık **0,25 MiB** tutar. Gerçek tüketim temsil biçimi, kopyalar ve çizim yüzeylerine bağlıdır; uygulamanın gerçekten bu boyutları aldığı ölçülmemiştir.

Kartta kapaktan üretilen bulanık arka plan da bulunur. Mevcut kapak kimliği ve çıktı tekrar eleme mekanizmaları korunmalıdır.

#### Önerilen düzenleme

- Medya yokken veya uzun süredir duraklatılmışken kurtarma sorgusunu seyrekleştirmek.
- Bildirimlerin güvenilir olduğu durumda gereksiz ara sorguları azaltmak.
- Timer'a uygun tolerans tanımak.
- Kapak yokluğunda tekrar deneme sıklığını incelemek.
- Görseli en büyük gösterim boyutu ve Retina ölçeğine göre küçülterek çözmek.
- Ağır çözümlemeyi ana iş parçacığından uzaklaştırmak.
- Geç gelen kapağı aynı parça kimliğiyle eşleştirmeye devam etmek.
- Gerekirse küçük bir bulanık arka plan temsilini önbelleğe almak.

#### Beklenen sonuç ve korunacak davranış

Medya beklerken daha az sorgu; büyük kapaklarda daha düşük bellek ve ana iş parçacığında daha az duraklama mümkündür.

Bütün periyodik kontrolleri kaldırmak risklidir. Private MediaRemote davranışı kaynak uygulama ve macOS sürümüne bağlıdır; kurtarma kontrolü bildirim kaçırılmasını telafi eder. Perl host'u kaldırmak ilk performans paketi için güvenli bir varsayım değildir.

Küçük kapağın duraklamadan 10 saniye sonra geri çekilmesi, duraklatılmış metadata'nın açık kartta korunması, komut ACK'leri ve geç gelen kapağın yanlış parçaya bağlanmaması değişmemelidir.

### P12 — Fare ve sürükleme takibindeki tekrarlar

**Öncelik:** Orta. **Basit tekrar elemenin riski:** Düşük. **Takip modelini değiştirmenin riski:** Orta–yüksek.

**Kaynak:** [IslandController.swift](../../Sources/Features/Island/IslandController.swift), mouse monitoring, satır 243; drag timer, satır 365.

#### Mevcut davranış

Global ve yerel mouse monitörlerinde hareketler takip edilir. Her harekette geometrik kontrol ve mouse passthrough güncellemesi yapılabilir.

Herhangi bir sol fare basışında 50 ms aralıklı sürükleme timer'ı başlar; saniyede 20 kontrol demektir. Sürükleme olayları da ayrıca inceleme tetikleyebilir.

#### Önerilen düzenleme

- `ignoresMouseEvents` değerini yalnız değiştiğinde atamak.
- Aynı olay turundaki yinelenen kontrolleri azaltmak.
- Sabit geometriyi gerektiğinde yeniden hesaplamak.
- Gerçek sürüklemenin anlaşılmasından sonra gereken kontrolleri ayırmak.

#### Beklenen sonuç ve korunacak davranış

Fare yoğun kullanılırken ve uzun basılı tutma/sürüklemede maliyet azalabilir.

Global takibi tamamen kaldırmak veya yalnız çentiğe girildiğinde sürükleme algılamak uzaktaki dosya ipucunu bozabilir. Native sürükleme döngülerinde bazı mouse olaylarının kesilmesini mevcut timer telafi eder. Şeffaf pencere alanının alttaki uygulamayı engellememesi ve çentiğe yaklaşım davranışı korunmalıdır.

### P13 — Dosya deposunda senkron yenileme ve ikon istekleri

**Öncelik:** Orta. **Risk:** Orta.

**Kaynaklar:** [FileShelfStore.swift](../../Sources/Features/FileShelf/FileShelfStore.swift), `refresh`, satır 146; [FileShelfView.swift](../../Sources/Features/FileShelf/FileShelfView.swift), `card`, satır 79.

#### Mevcut davranış

Depo yenilenirken bütün bookmark'lar çözülür, dosya varlığı ve okunabilirliği ana aktörde kontrol edilir. Az sayıda yerel dosyada düşük maliyetlidir; harici disk, ağ konumu veya çok sayıda kayıt sayfa geçişini bekletebilir.

Kart görünümü hesaplanırken dosya ikonu istenir. Sistem önbelleği bulunabilir; uygulama seviyesinde tekrarları sınırlamak yine de değerlendirilebilir.

#### Önerilen düzenleme

- İkonları sınırlı önbellekte tutmak.
- Aynı yenileme taleplerini birleştirmek.
- Uygun dosya kontrollerini arka planda yapıp sonucu tutarlı yayınlamak.
- Yenileme sırasında mevcut kartları görünür tutmak.
- Bookmark erişim başlangıç/bitiş dengesini korumak.

#### Beklenen sonuç ve korunacak davranış

Özellikle büyük veya yavaş depoda daha akıcı açılış beklenir.

Asenkron yenilemenin eski sonucu daha yeni ekleme/silme işlemini ezmemelidir. Önce diske kaydedip sonra kartı kaldırma garantisi korunmalıdır. Asıl dosyalar kopyalanmamalı/taşınmamalı; sürükleme iptalinde kayıt kalmalı; yalnız kabul edilmiş kopyalamada kaldırılmalıdır. Çöp düğmesi ve erişilemeyen kayıtların görünürlüğü korunmalıdır.

### P14 — Saat, Claude runtime ve ajan listesinde tamamlayıcı iyileştirmeler

**Öncelik:** Düşük–orta. Büyük tarama sorunlarından sonra ele alınmalıdır.

#### Saat

**Kaynaklar:** [WidgetDrawerView.swift](../../Sources/Features/Widgets/Views/WidgetDrawerView.swift), satır 100; [ClockReadout.swift](../../Sources/Features/Widgets/Clock/ClockReadout.swift).

Saniyeler kapalıyken de saniyelik timeline kullanılır. Bu durumda dakika sınırına hizalı yenileme yeterli olabilir. Görünür saatte dakikada 60 zamanlama fırsatı yaklaşık bire iner. Çekmece kapalıyken saat zaten kaldırılır; arka plan katkısı sınırlıdır.

Saat dilimi, sistem saati veya dil değişince anında yenileme korunmalıdır. `Date.FormatStyle` kullanımı olumludur; ölçüm olmadan karmaşık biçimlendirme önbelleği öncelikli değildir.

#### Claude runtime

**Kaynak:** [ClaudeStore.swift](../../Sources/Features/Widgets/Claude/ClaudeStore.swift), `ClaudeRuntimeReader`, satır 395.

Runtime kayıtları her turda yeniden okunup çözülür. Süreç başlangıç zamanı karşılaştırmasında `DateFormatter` oluşturulur. Dosya içeriği önbelleği ve formatter tekrar kullanımı değerlendirilebilir.

PID yeniden kullanımını önleyen süreç başlangıç kimliği, kullanıcı sahipliği ve canlı süreç doğrulaması korunmalıdır. Yalnız PID'nin önbelleğe alınması yeterli değildir. İnceleme anında tek runtime JSON kaydı vardır; bugünkü maliyetin yüksek olduğu ölçülmemiştir.

#### Ajan ağacı

**Kaynak:** [CodexWidgetView.swift](../../Sources/Features/Widgets/Codex/CodexWidgetView.swift), `visibleAgents`, satır 45.

Görünür sıralama, her ajan için bütün listeyi dolaşarak çocuk arayabilir. Ebeveyn → çocuk indeksi oluşturmak ve görünür listeyi bir kez hesaplamak çok ajanlı kullanımda işi azaltabilir. Mevcut `LazyVStack`, sıralama, döngü koruması ve ebeveyn/çocuk görünümü korunmalıdır.

## 5. Davranış etkisi sınıflandırması

| Düzenleme | Beklenen fayda | Kullanıcıya görünen etki |
| --- | --- | --- |
| Aynı turdaki çift kurulum doğrulamasını kaldırmak | Okuma/hash azalır | Beklenmez |
| Eşit değerleri tekrar yayınlamamak | Arayüz ve abonelik işi azalır | Doğru eşitlik/zaman kurallarıyla beklenmez |
| Değişmeyen dosyaları tekrar açmamak | CPU ve dosya sistemi işi azalır | Doğru izleme kurulursa beklenmez |
| Görünmeyen animasyonları durdurmak | Çizim/GPU işi azalabilir | Beklenmez |
| Değişmeyen animasyon alanlarını atamamak | Kare başına iş azalır | Beklenmez |
| Görünüm bağımlılıklarını daraltmak | Gereksiz hesaplama azalır | Tasarım korunabilir; geçiş testi gerekir |
| Saniyesiz saati dakika başında yenilemek | Saatin zamanlama işi azalır | Doğru hizalamayla beklenmez |
| Büyük kapağı uygun çözünürlükte çözmek | Bellek ve çözümleme maliyeti azalır | Retina ve kalite kontrolü gerekir |
| Widget kaldırılınca önbelleğini bırakmak | Bellek azalır | Yeniden eklemede tekrar okuma olabilir |
| İzlemeyi doğrudan 1'den 5 saniyeye çıkarmak | Tarama sayısı nominal %80 azalır | Uyarı ve durumlar gecikebilir |
| Görünür ajan nabzını kaldırmak | Sürekli çizim azalabilir | Görsel davranış değişir |
| Animasyon kare hızını düşürmek | Animasyon maliyeti azalabilir | Akıcılık etkilenebilir |
| Geçmişin yalnız birkaç dosyasını okumak | İlk açılış hızlanabilir | Kota/hesap/ajan doğruluğu etkilenebilir |
| Medya yardımcısını çekmece kapanınca kapatmak | Süreç maliyeti azalır | Küçük kapak ve otomatik güncellemeler etkilenir |

İlk uygulama paketi davranışı koruyan işlerden oluşturulmalıdır. Rastgele geçmiş kesme, gerekli hook olaylarını azaltma, izin eşleştirmesini basitleştirme veya güvenlik kontrollerini kaldırma performans çözümü sayılmamalıdır.

## 6. Kazanç beklentileri ve hesaplama sınırları

### 6.1. Bileşen bazında hesaplanabilen değişimler

| Alan | Hesaplanabilen veya hedeflenebilen değişim |
| --- | --- |
| Aynı turdaki iki kurulum doğrulaması | İkiye karşı bir doğrulama: bu yoldaki tekrar yaklaşık %50 azalır |
| Değişmeyen kurulumda tam doğrulama | Değişiklik odaklı önbellekle tekrarların büyük çoğunluğu kaldırılabilir |
| Saniyelik tam keşif yerine 60 saniyelik kurtarma taraması | Periyodik tam tarama 3600'den 60'a iner: %98,3 azalma; olayların tetiklediği işler ayrıca vardır |
| Değişmeyen store alanlarının yayınları | Sabit durumda bu yayınlar kaldırılabilir; gerçek değişiklikler devam eder |
| Saniyesiz görünür saat | Dakikada 60 yerine yaklaşık bir güncelleme fırsatı |
| Büyük görseller | Gelen piksel boyutuna bağlı; tek görselde onlarca MiB fark mümkün |
| Boşta display link | Zaten duruyor; buradan büyük ek kazanç beklenmez |

60 saniyelik kurtarma taraması uygulanmış veya kesin seçilmiş bir ayar değildir; işlem sayısını göstermek için örnektir. Normal olay teslimi hızlı tutulabilir; yalnız kurtarma taramasına kalan kaçırılmış değişikliğin fark edilmesi gecikebilir. Gerçek aralık, izleme güvenilirliği ve kabul edilen gecikmeyle seçilmelidir.

Bu yüzdeler toplam uygulama CPU tüketimindeki yüzdeler değildir. Aynı işi etkileyen iyileştirmeler üst üste toplanmamalıdır.

### 6.2. Toplam CPU kazancı neden şimdiden kesin verilemiyor?

Basitleştirilmiş hesap:

```text
Toplam göreli azalma
= mevcut maliyet içinde iyileştirilen işin payı
  × o işteki göreli azalma
```

Yalnız yöntemi göstermek için CPU'yu %34 kabul edip iyileştirilen bölümün maliyetinin %90 azaltıldığını varsayarsak:

| İyileştirilen işin mevcut CPU içindeki varsayımsal payı | Toplam CPU azalması | %34'ten hesaplanan yeni CPU |
| --- | ---: | ---: |
| %30 | %27 | Yaklaşık %24,8 |
| %60 | %54 | Yaklaşık %15,6 |
| %80 | %72 | Yaklaşık %9,5 |

**Bu tablo tahmin veya vaat değildir.** Kısa canlı gözlemi başlangıç kabul ederek kurulmuş varsayımsal modeldir; gerçek maliyet dağılımı bilinmemektedir.

Mevcut bulgular özellikle değişiklik olmayan arka plan kullanımında büyük iyileştirme potansiyeli gösterir. Ancak toplam CPU'nun %80 düşeceği veya belleğin belirli bir değere ineceği söylenemez.

### 6.3. Bellek ve pil

328,8 MB belleğin okuyucu durumları, SwiftUI/AppKit tahsisleri, görseller ve önbellekler arasındaki dağılımı ölçülmelidir. Bellek bırakılması, Etkinlik Monitörü değerinin anında aynı miktarda düşmesini garanti etmez.

Pil kazancı CPU azalmasına eşit değildir. GPU, yardımcı süreçler, sistem servisleri ve diğer uygulamalar toplam tüketimi etkiler. Gerçek enerji karşılaştırması aynı senaryolarda ve benzer sistem koşullarında yapılmalıdır.

## 7. Önerilen uygulama sırası

| Sıra | İş paketi | Amaç |
| --- | --- | --- |
| 1 | Kontrollü Release ölçümü | Gerçek maliyet dağılımını ve karşılaştırma tabanını oluşturmak |
| 2 | Çift doğrulama ve gereksiz yayınlar | Düşük riskle doğrulanabilir tekrarları kaldırmak |
| 3 | Kurulum ve olay klasörü izleme | Boşta tarama işini azaltmak |
| 4 | Codex oturum keşfi ve değişen dosya okuma | En büyük ölçeklenme sorununu ele almak |
| 5 | Hook temizliği ve kilit süresi | Yoğun ajan kullanımındaki ek maliyeti azaltmak |
| 6 | SwiftUI bağımlılıkları ve kare güncellemeleri | Arayüz hesabını daraltmak |
| 7 | Tamponlar, kapaklar ve önbellek yaşam döngüsü | Bellek ve ilk açılışı iyileştirmek |
| 8 | Fare, depo, saat ve liste ayrıntıları | Kalan maliyetleri ölçüme göre tamamlamak |

Her paket ayrı ölçülmelidir. Birbiriyle bağımsız büyük değişiklikleri aynı anda uygulamak, kazanç kaynağını ve davranış bozulmasını ayırt etmeyi zorlaştırır.

Başlangıç için en uygun somut paket: **çift kurulum doğrulamasını kaldırmak ve değişmeyen yayınları elemek**. Sonrasında dosya izleme mimarisi ele alınmalıdır.

## 8. Ölçüm ve kabul planı

### 8.1. Karşılaştırma koşulları

- Aynı makine, benzer sistem yükü ve aynı güç koşulları.
- Aynı Release yapılandırması; debugger ek yükünün ayrılması.
- Aynı kayıtlı widget'lar ve özellik ayarları.
- Karşılaştırılabilir oturum/olay verisi; canlı kayıtların büyümesinin hesaba katılması.
- Isınma sonrası sabit süreli kayıtlar ve yeterli tekrar.
- Ana süreçle birlikte medya host'u ve kısa ömürlü yardımcıların değerlendirilmesi.
- İlk açılış ile önbellekli yeniden açılışın ayrı raporlanması.

### 8.2. Senaryolar

| Senaryo | Kontrol |
| --- | --- |
| Çentik kapalı, medya/ajan etkinliği yok | Gerçek boşta maliyet |
| Codex/Claude açık, görev yok | İzleyicinin değişikliksiz maliyeti |
| Tek aktif ajan | Normal etkin kullanım |
| Çok aktif ajan | Liste, gösterge ve olay ölçeklenmesi |
| Yoğun araç çağrısı | Hook süreçleri, kilit, kuyruk ve tarama |
| Eşzamanlı izin istekleri | Teslim gecikmesi ve doğru eşleştirme |
| Medya oynuyor/duraklatılmış/yok | Sorgu, timeline, küçük kapak ve host maliyeti |
| Çekmece açık | Saat, medya ve ajan listesi güncellemeleri |
| Hızlı açılma/kapanma | Animasyon sürekliliği ve kare maliyeti |
| Ana sayfa/depo geçişi | Maske, opaklık, boyut ve içerik sıralaması |
| Büyük/yavaş dosya deposu | Bookmark, ikon ve ana iş parçacığı beklemesi |
| Widget kaldırma ve tekrar ekleme | İzleyici/önbellek yaşam döngüsü |
| Uygulamayı gizleme ve yeniden açma | İşlerin durması ve yeniden başlama |
| Uyku/uyanma ve saat değişimi | İzleyici, timeout ve stale durumları |
| Uzun süreli çalışma | Bellek, indeks, dosya tanımlayıcı ve süreç büyümesi |

### 8.3. Ölçütler

| Ölçüt | Amaç |
| --- | --- |
| Ortalama ve yüksek yüzdelikli CPU | Sürekli yük ve sıçramaları karşılaştırmak |
| Ana iş parçacığı süresi | Hover, düğme ve geçiş tepkisini değerlendirmek |
| SwiftUI güncelleme sayısı/nedeni | Gereksiz görünüm hesaplarını bulmak |
| Dosya açma, metadata ve okuma sayıları | Tarama azalımını doğrulamak |
| Bellek dağılımı ve uzun süreli büyüme | Tampon, görsel ve önbellek etkisini ayırmak |
| GPU ve animasyon izleri | Gizli veya sürekli animasyon maliyetini görmek |
| İzin uyarısı teslim süresi | Performans uğruna uyarıların gecikmemesi |
| Yardımcı süreçlerin toplam maliyeti | Tüketimin başka sürece taşınmadığını doğrulamak |
| İlk açılış/tekrar açılış süresi | Bellek azaltımının açılış etkisini ölçmek |
| Timer ve uyanma davranışı | Boşta gereksiz periyodik işi görmek |

SwiftUI Instruments, Time Profiler, bellek araçları ve dosya sistemi izleri birlikte kullanılmalıdır. Tek bir kısa CPU ekran görüntüsü yeterli kabul kanıtı değildir.

**Dayanak:** [Apple: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).

### 8.4. Davranış kabul koşulları

- Değişmeyen geçmiş dosyalar her saniye açılmamalı.
- Değişmeyen veriler tekrar yayınlanmamalı.
- Görünmeyen animasyonlar çalışmamalı.
- Animasyon durulduğunda display link kapanmalı.
- Yeni dosya, dosya değişimi ve kaçırılmış bildirim kurtarması doğru çalışmalı.
- Sessizlik tamamlanmış görev olarak yorumlanmamalı.
- Kota reseti yeni veri olmadan sıfır kullanım olarak gösterilmemeli.
- Hesap belirsizliği ve bilinmeyen durumlar korunmalı.
- İzin uyarıları doğru araç/görev sonucuyla kapanmalı; paralel çağrılar karıştırılmamalı.
- Eski olaylar bitmiş işi yeniden çalışıyor durumuna getirmemeli.
- Uygulama taşınması veya helper değişimi onarım durumuna doğru yansımalı.
- Medya kontrolü, kapak kimliği ve duraklama sonrası 10 saniyelik küçük kapak davranışı korunmalı.
- Şeffaf pencere alanı alttaki uygulamayı engellememeli.
- Dosya sürükleme ipucunun uzaktan görünmesi ve yaklaşınca açılması korunmalı.
- Depo/ana sayfa kapanışında okunabilir içerikler üst üste binmemeli; önceki sayfa erken geri gelmemeli.
- Asıl dosyalar korunmalı; iptal/reddedilen sürüklemede depo kaydı silinmemeli.
- Bookmark erişimleri dengeli olmalı; kaydetme hatasında kart kaybolmamalı.
- Dil, saat dilimi ve Reduce Motion davranışları korunmalı.

## 9. Nihai öneri

Önce kontrollü ölçüm tabanı oluşturulmalı; ardından düşük riskli tekrarlar kaldırılmalıdır. En büyük mimari kazanç, değişmeyen kurulumların ve geçmiş dosyaların sürekli taranmasını önlemekten beklenmektedir.

Hedef, mevcut özellikleri ve akıcılığı korurken **değişiklik olmayan zamanlarda uygulamanın gerçekten beklemesini sağlamak** olmalıdır. Toplam CPU, bellek ve pil kazancı her iş paketinden sonra ölçülerek bu rapora eklenmelidir.

## 10. Kaynaklar

### Proje kaynakları

- [Uygulama README](../../README.md)
- [Test çalıştırıcısı](../../Tests/run.sh)
- [Test açıklamaları](../../Tests/README.md)
- [IslandController](../../Sources/Features/Island/IslandController.swift)
- [IslandState](../../Sources/Features/Island/IslandState.swift)
- [IslandView](../../Sources/Features/Island/IslandView.swift)
- [CodexUsageReader](../../Sources/Features/Widgets/Codex/CodexUsageReader.swift)
- [CodexStore](../../Sources/Features/Widgets/Codex/CodexStore.swift)
- [ClaudeStore](../../Sources/Features/Widgets/Claude/ClaudeStore.swift)
- [CodexHookInstaller](../../Sources/Features/Widgets/Codex/CodexHookInstaller.swift)
- [ClaudeHookInstaller](../../Sources/Features/Widgets/Claude/ClaudeHookInstaller.swift)
- [CodexHookBridge](../../Native/CodexHookBridge.swift)
- [ClaudeHookBridge](../../Native/ClaudeHookBridge.swift)
- [NowPlayingBridge](../../Native/NowPlayingBridge.m)
- [NowPlayingStore](../../Sources/Features/Widgets/Media/NowPlayingStore.swift)
- [FileShelfStore](../../Sources/Features/FileShelf/FileShelfStore.swift)

### Apple belgeleri

- [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
- [Improving your app's rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
- [Optimize SwiftUI performance with Instruments — WWDC25](https://developer.apple.com/videos/play/wwdc2025/306/)

Arşiv belgeleri genel API ve enerji ilkeleri için kullanılmıştır. Önerilen izleme ve zamanlama davranışları uygulamanın desteklediği macOS sürümlerinde ayrıca doğrulanmalıdır.
