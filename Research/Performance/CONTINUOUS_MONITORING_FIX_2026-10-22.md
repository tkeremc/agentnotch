# Sürekli tarama ve doğrulama düzeltmesi

Tarih: 22 Ekim 2026. Karşılaştırma tabanı: `1b77ca5`. Yeni sürüm: bu belgeyle birlikte hazırlanan çalışma ağacı değişiklikleri.

## Kapsam

[İlk performans incelemesindeki](PERFORMANCE_AUDIT_2026-10-22.md) sürekli tarama ve doğrulama sorunları önceliklendirilmiştir: P01, P02, P03 ve bunların gereksiz arayüz yayını etkisi olan P04. Claude runtime dosyaları da değişiklik odaklı okunur. Görünüm, animasyon eğrileri, medya entegrasyonu, hook olay sözleşmeleri ve dosya deposu davranışları değiştirilmemiştir.

Hook yardımcılarının olay başına kuyruk temizliği (P08), medya sorguları, görsel küçültme ve diğer bağımsız iyileştirmeler bu paketin kapsamında değildir.

## Uygulanan davranış

| Kaynak | Normal yenileme | Tam yenileme |
| --- | --- | --- |
| Codex JSONL oturumları | Değişen bilinen dosya artımlı okunur | Başlangıç, klasör/topoloji değişimi, saat geri alınması veya kurtarma |
| Codex/Claude olay kuyruğu | Olay klasörü değişince yeni olaylar işlenir | Başlangıç veya kurtarma |
| Hook yapılandırması ve manifest | İlgili dosya veya paket helper'ı değişince doğrulanır | Başlangıç veya kurtarma |
| Codex sohbet başlığı indeksi | İndeks değişince okunur | Başlangıç veya kurtarma |
| Claude runtime JSON kayıtları | Dosya/klasör değişince okunur | Başlangıç veya kurtarma |
| Ajan sessizliği, izin yaşı, kota süresi | Bellekteki veriden hesaplanır | Dosya taraması gerektirmez |

- Yeni ortak `LocalMonitorDriver`, FSEvents ve native vnode bildirimlerini aynı serial utility kuyruğunda işler.
- Recursive FSEvents yalnız izinli `sessions/` ve `agentnotch/events/` dizinlerine açılır. Yapılandırma/helper dosyaları için bütün hesap dizinine recursive stream açılmaz; bunlar tekil native bildirimlerle izlenir.
- Ana thread'de yalnız sabit izleme kökleri alınır; değişebilir okuyucu listesi worker kuyruğunda değerlendirilir.
- FSEvents'in bu ortamda tek başına bildirim teslim etmediği gözlendiği için native bildirim desteği eklenmiştir. Üretim davranışı yalnız FSEvents teslimine bağlı değildir.
- Her sağlayıcı için native izleme en fazla **128 tanımlayıcı** kullanır. Fazla, erişilemeyen veya henüz oluşmamış yolların değişimi metadata karşılaştırmasıyla yakalanır; değişmeyen dosyanın içeriği okunmaz.
- Bir saniyelik tick, zaman aşımı projeksiyonunu ve yalnız native izlemesi olmayan yolların metadata kontrolünü yapar. Bir saniyelik tam tarama/hash döngüsü kaldırılmıştır.
- Bildirimler ilk olaydan itibaren **100 ms** içinde birleştirilir; her yeni olayda süre yeniden başlatılıp teslim süresiz ertelenmez.
- Bildirim kaybı, silinmiş/yenilenmiş kökler ve uyku sonrası kaçırılmış değişiklikler için **60 saniyelik** kurtarma uzlaştırması vardır. Olay kaybı flag'leri ayrıca tam uzlaştırma ister.
- Native izleme yeni dosya keşfinden sonra kurulduğunda, okuma ile izleyicinin kurulması arasındaki yazımı kaçırmamak için bir defalık yeniden kontrol yapılır.
- Atomik dosya değişiminde eski inode'a bağlı native izleyici kapatılıp yeni yol için yeniden kurulur.
- Gerçek okuma hataları kısa gecikmeyle tekrar denenir. Gelecek tarihli olaylar zamanları geldiğinde yeni bildirim beklemeden yeniden değerlendirilir.
- `isInstalled` sonucu `needsRepair` kararında tekrar kullanılır; aynı turdaki ikinci tam doğrulama kaldırılmıştır.
- Store alanları yalnız değer değiştiğinde yayınlanır.
- Stop/retry/yeniden bağlantı akışları eski kuyruğun arayüze sonuç yayınlamasını generation kontrolüyle engeller; stop native tanımlayıcıları ve stream'i kapatır.

## Korunan doğruluk kuralları

- Yeni, silinmiş, kısalmış ve atomik değiştirilmiş JSONL dosyaları ele alınır.
- Hedefli dosya bildirimi, symlink ile değiştirilmiş üst dizinden dışarı okumaya izin vermez; gerektiğinde güvenli tam keşfe dönülür.
- Değişmeyen dosyalardaki diğer hesap kanıtı korunur; hedefli okuma çoklu hesap belirsizliğini yanlışlıkla gidermez.
- İleri tarihli kota/olay kaydı doğru zamana kadar ertelenir; saat geri alınırsa uzlaştırma yapılır.
- Sessizlik tamamlanmış görev olarak kabul edilmez; eski ajan durumu bellekte bilinmiyora geçer.
- Claude kota penceresi yeni dosya yazılmasa da süresi dolunca kullanılamaz olur.
- Claude runtime içeriği önbellekte olsa bile canlı süreç kimliği yeniden doğrulanır; çıkmış veya PID'si yeniden kullanılmış süreç çalışıyor gösterilmez.
- Kurma, onarma ve kaldırmanın tam sahiplik ve güvenlik kontrolleri korunur. Uygulama entitlement'ları değiştirilmemiştir.

## Testler

```sh
AGENTNOTCH_TEST_SCOPE=codex bash Tests/run.sh
```

Yeni `MonitorPerformanceTests` şunları doğrular:

1. Codex'te 302 değişikliksiz zaman ilerlemesi sırasında ilave oturum keşfi, dosya açma, olay taraması veya kurulum doğrulaması yapılmaması; ajan sessizliğinin yine de sona ermesi.
2. Olay ve yapılandırma değişikliklerinin bağımsız okuma/doğrulama yollarını geçersiz kılması.
3. 40 oturum dosyasından biri değişince yalnız o dosyanın açılması; hesap belirsizliği, silme ve atomik değiştirme davranışları.
4. Gelecek tarihli kullanım kaydının dosya açmadan uygun hâle gelmesi ve saat geri alınınca uzlaştırma.
5. Üst klasörü symlink ile değiştirilmiş hedefli yolun dışarı veri okutmaması.
6. Claude quota süresi ilerlerken kuyruk/runtime taraması ve kurulum doğrulaması yapılmaması.
7. Önbellekli runtime kaydında ölmüş/yeniden kullanılmış süreç kimliğinin reddedilmesi.
8. Gerçek native bildirimle dosyaya ekleme ve atomik değiştirme teslimi.
9. 128 tanımlayıcı sınırının dışındaki dosyanın metadata fallback ile kurtarma taramasından önce fark edilmesi.
10. Yeni çok katmanlı oturum klasörünün ve sonradan atomik değiştirilen oturumun canlı store'a ulaşması.
11. Gelecek tarihli izin olayının yeni dosya bildirimi olmadan zamanında işlenmesi.
12. Bildirim ipucu verilmemiş yazımın açık kurtarma turunda bulunması.

Doğrulama sonucu:

| Kontrol | Sonuç |
| --- | --- |
| Swift bileşen/regresyon testleri | **108/108 geçti**; önceki 96 teste 12 izleme testi eklendi |
| Codex native helper testleri | **9/9 geçti** |
| Claude native helper testleri | **13/13 geçti** |
| Native medya regresyon kontrolleri | Geçti |
| Release build | Geçici compiler seçeneğiyle başarılı; arm64 ve x86_64 |
| Deep/strict codesign doğrulaması | Geçti |
| Derlenen uygulamanın App Sandbox entitlement'ı | `true` |
| Derlenen uygulamanın genel network client entitlement'ı | Yok |
| `git diff --check` | Geçti |
| İmzalı sandbox probe | Başarılı değil; aşağıdaki ortam sınırına bakınız |

Release çıktısı: `/private/tmp/agentnotch-monitor-release/Build/Products/Release/agentnotch.app`.
Kurulu `/Applications/agentnotch.app` bu çalışma tarafından değiştirilmemiştir.

## Sentetik önce/sonra ölçümü

Tekrarlanabilir ölçüm:

```sh
python3 -B Research/Performance/benchmark-monitors.py \
  --baseline 1b77ca5 --app /Applications/agentnotch.app
```

Betik eski ve yeni kaynakları `swiftc -O` ile ayrı derler. Yalnız geçici sentetik Codex/Claude dizinleri oluşturur; gerçek bağlantı dosyalarını değiştirmez. Paket helper'ları yalnız fixture kurulumunun doğrulama girdisi olarak okunur.

Koşullar:

- 100 sentetik Codex oturum dosyası.
- Her sağlayıcıda 1000 sentetik olay.
- İlk okuma sonrasında 120 değişikliksiz izleyici turu.
- Yeni sürümün 60 saniyelik kurtarma davranışını temsil etmek için 60. ve 120. turda tam uzlaştırma.
- Dosyalar değişmez; normal zamansal projeksiyonlar devam eder.
- İki sürümün ajan sayısı ve kullanım yüzdesinden üretilen kontrol toplamı aynıdır: **15000**.

22 Ekim 2026 tek koşu sonucu:

| Ölçüt | `1b77ca5` | Yeni kaynak |
| --- | ---: | ---: |
| İzleyici döngülerinin süreç CPU süresi | 12,113352 saniye | 0,241463 saniye |
| Döngülerin duvar saati süresi | 13,619001 saniye | 0,264976 saniye |
| Kontrol toplamı | 15000 | 15000 |

Bu iş yükünde izleyici döngülerinin CPU süresi **%98,01 azalmıştır**.

**Bu sonuç tüm uygulamanın CPU tüketimi, bellek veya pil kazancı değildir.** UI, native bildirim sürücüsü, metadata fallback maliyeti, ilk açılış, aktif yazan ajanlar ve gerçek kullanıcı veri seti ölçüme dahil değildir. Tek koşudur; medyan/p95 gibi tekrarlı istatistik içermez. Benchmark'ın 120 turu duvar saatinde 120 saniye beklenerek çalıştırılmaz; izleyicilere mantıksal zaman verilerek yürütülür.

## Derleme ve ortam sınırları

Standart Release build, bu ortamda SwiftUI macro alt sürecinin sandbox'ı başlatamaması nedeniyle `sandbox_apply: Operation not permitted` ve `SwiftUIMacros.StateMacro ... malformed response` hatalarına takılmıştır.

Kaynak/proje ayarları değiştirilmeden, yalnız derleme komutunda compiler alt süreç sandbox kısıtı için geçici seçenek kullanılmıştır:

```sh
xcodebuild -project agentnotch.xcodeproj -scheme agentnotch \
  -configuration Release -derivedDataPath /private/tmp/agentnotch-monitor-release \
  'OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox' build
```

Bu seçenek uygulamanın App Sandbox entitlement'ını değiştirmez ve proje dosyasına kaydedilmemiştir. Normal geliştirme ortamında standart build komutu kullanılmalıdır.

İmzalı, dar sandbox izinli bildirim denemesi ayrıca hazırlanmıştır:

```sh
python3 -B Research/Performance/sandbox-monitor-probe.py
```

Bu probe sentetik oturum/olay/yapılandırma dosyalarına dış süreçten yapılan değişikliklerin bildirilmesini ve sentetik `auth.json` dosyasına erişimin reddedilmesini denetler. Buradaki çalıştırmada imzalı probe süreci `main` giriş işareti dahi yazılmadan başlangıç aşamasında **SIGABRT (`exit=-6`)** ile durduğu için canlı sandbox teslimi **doğrulanamamıştır**. Probe sonucu başarılı sayılmamalıdır. Mevcut entitlement'lar genişletilmemiştir.

Native bildirimler gerçek dosya işlemleriyle bileşen testlerinde doğrulanmıştır. Bu kanıt, imzalı sandbox uygulamasındaki canlı doğrulamanın yerine geçmez.

## İlgili kaynaklar

- [Ortak bildirim sürücüsü](../../Sources/Features/Widgets/Monitoring/LocalMonitorDriver.swift)
- [Codex izleyici ve store](../../Sources/Features/Widgets/Codex/CodexStore.swift)
- [Codex oturum okuyucusu](../../Sources/Features/Widgets/Codex/CodexUsageReader.swift)
- [Claude izleyici ve runtime okuyucusu](../../Sources/Features/Widgets/Claude/ClaudeStore.swift)
- [Performans/doğruluk regresyon testleri](../../Tests/MonitorPerformanceTests.swift)
- [Apple: File-level FSEvents](https://developer.apple.com/documentation/coreservices/kfseventstreamcreateflagfileevents)
- [Apple: MustScanSubDirs](https://developer.apple.com/documentation/coreservices/1455361-fseventstreameventflags/kfseventstreameventflagmustscansubdirs)
- [Apple: FSEvents dispatch queue lifecycle](https://developer.apple.com/documentation/coreservices/1444164-fseventstreamsetdispatchqueue)
