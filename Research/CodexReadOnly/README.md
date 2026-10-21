# Codex yerel veri erişimi — ilk aşama kanıtı

2026-10-20, Codex CLI 0.163.0. Bu klasör bir araştırma aracıdır; uygulamaya
derlenmez. Widget, hook, Codex yapılandırması, üretim entitlement'ı veya oturum
açma akışı eklenmedi. Kimlik doğrulama dosyaları okunmadı, App Server bağlantısı
ve ağ isteği yapılmadı. Önceden değişmiş `Resources/Localizable.xcstrings`
dosyası korunmuştur.

## Sonuç

Standart `~/.codex/sessions` konumundaki mevcut kayıtlardan son bilinen kota
alınabiliyor. Yerel dosya gözlemiyle iş başlangıcı/bitişi de ayrıştırılabiliyor;
kesin canlı ajan sayısı ve onay bekleme durumu bu kaynakla kanıtlanamıyor.

Mevcut sandbox entitlement'larıyla dizin erişimi reddediliyor. Ayrı, ad-hoc
imzalı test uygulamasında yalnız aşağıdaki **salt okunur** istisna eklenince
sandbox açıkken, giriş/klasör seçimi/Codex yapılandırması olmadan nested JSONL
dosyası okunabildi:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.codex/sessions/</string></array>
```

Bu anahtar yalnız test uygulamasına eklendi; ana projenin
`Configuration/agentnotch.entitlements` dosyası değiştirilmedi.

## Tekrar çalıştırılabilir veri deneyi

Repo kökünde:

```sh
python3 -B Research/CodexReadOnly/probe.py --sessions "$HOME/.codex/sessions"
python3 -B -m unittest discover -s Research/CodexReadOnly -p 'test_*.py' -v
```

İlk komut tek snapshot üretir; henüz üretim dosya izleyicisi değildir. İkinci
komut gerçek Codex dizinini açmadan sentetik durumları sınar. Araç yalnız
verilen dizindeki normal `.jsonl` dosyalarını okur; symlink'leri izlemez.
Mesajlar, istemler, tool argümanları ve kimlik değerleri çıktıya aktarılmaz.
Hesap/kullanıcı bilgisi mevcutsa yalnız fingerprint kullanılır. Bu bilgi
kaydın yaratıcı kimliğidir; şu an giriş yapılmış hesabın doğrulanması değildir.

Snapshot şunları bildirir:

- Son kota gözleminin zamanı, kullanılan/kalan yüzde, pencere süresi ve reset
  zamanı. Süreler sabit varsayılmaz. Reset zamanı geçince kota kendiliğinden
  %100 sayılmaz; `resetHasPassed` ve gözlem yaşı korunur.
- `recent_unclosed_turn`: yakın zamanda çalışma olayı görülen, bitişi henüz
  kaydedilmemiş görev. Kesin canlılık veya mutlaka model çalışması anlamına
  gelmez; uzun araç/ağ beklemesi de olabilir.
- `terminal_observed`: eşleşen bitiş/kesilme olayı var. Bu araştırma aracı
  tamamlandı/başarısız/kesildi durumlarını tek terminal sinyalinde tutar;
  ürün bunları ayrıca ayrıştırmalıdır.
- `stale_unknown`: bitiş görülmedi ama çalışma kanıtı eski. Varsayılan 120
  saniye yalnız araştırma eşiğidir; görev sona erdi veya çöktü demek değildir.
- `unknown`: yeterli veya güvenle ayrıştırılabilen veri yok. Erişim hataları
  ayrıca belirtilir; sıfır çalışan olarak sunulmaz.

`authoritativeLiveAgentCount` her zaman `null`, `approvalState` ise
`unavailable` döner. Bu sayede verinin kanıtlamadığı bir iddia üretilmez.

## Gerçek kayıtlardaki ölçümler

Araştırma sırasında 44 oturum dosyası incelendi; dosyalar ve kota gözlemleri
erişilebilirdi. Son snapshot 2026-10-19 21:39:39 UTC / 20 Ekim 00:39:39 Türkiye
saatinde alındı; bu değerler o gözleme aittir, güncel kota taahhüdü değildir.

- Son gözlemde 300 dakikalık pencerede %80, 10080 dakikalık pencerede %82
  kullanım hakkı kalmıştı. Kota değişiklikleri yeni token_count kayıtlarıyla
  görüldü; kota için sunucuya ayrı bir istek yapılmadı.
- 15 fork dosyası ebeveynin geçmişini kopyalıyordu. Ham unmatched başlangıç
  sayısı 18 iken kendi geçmiş sınırı uygulanınca o andaki 3 araştırma
  oturumuna indi: kök ve iki alt ajan.
- İlk `session_meta` gerçek kimliktir. Sonraki kopya `session_meta` kayıtları
  ebeveyne ait olabilir. İncelenen 15/15 fork'ta ilk kendi başlangıcı,
  `subagent_history_start_ordinal + 1` fiziksel satırındaydı. Bu gözlenen bir
  iç format davranışıdır; gelecekteki sürümler için garanti değildir.
- Alt ajanların bitiş kayıtları daha sonraki snapshot'ta görüldü. Son okumada
  42 terminal sinyali, yalnız bu kök oturum için 1 güncel açık görev sinyali
  ve sınırı ayrıştırılamayan 1 eski alt ajan için `unknown` vardı.
- SQLite'da `inProgress` görünen 8 kaydın 5'i 30–75 gün eskiydi ve ilgili
  rollout dosyaları artık yoktu. `thread_spawn_edges.open` değeri 83'tü.
  Bu nedenle DB durumları canlı ajan sayısı olarak kullanılamaz.
- `task_complete.error` içeren 3 kota-limit hatası ve 3 `turn_aborted`
  kesilmesi gözlendi. Bir araç çağrısının başarısız olması, tek başına ajanın
  başarısız sonlandığı anlamına gelmiyor.
- Özel onay-bekleme olayı gözlenmedi. `item_completed` araç bittikten sonra
  geliyor; buradan onay, uzun araç çalışması ve ağ beklemesi ayrılamıyor.

Sentetik testler: **21/21 geçti**. Kopya fork geçmişi, kimlik/bucket ayrımı,
kesilme ve hata sonlanması, eşleşmeyen turn, eski kayıt, metadata ile sahte
tazelik, yarım/bozuk JSONL, geçersiz/aşırı sayı, null kota, geçmiş reset,
symlink kapsamı ve mesajların çıktıya taşınmaması sınandı.

## Gerçek App Sandbox testi

Aynı makinede ad-hoc imzalı, penceresiz minimal `.app` varyantları kullanıldı.
`codesign --verify --strict` geçti. Araç yürütme sandbox'ı test uygulamasının
kendi App Sandbox'ını başlatmayı engellediğinde, yalnız yürütme bağlamı için
gerekli izinli tekrar yapıldı; uygulamanın App Sandbox'ı kapatılmadı.

| Varyant | Sessions erişimi | Nested JSONL read | Komşu Codex dosyaları |
| --- | --- | --- | --- |
| Sandbox olmayan kontrol | Başarılı | Sınanmadı | Açılabildi |
| Mevcut dosya erişim entitlement'ları | errno 1, reddedildi | Dizin reddedildiği için sınanmadı | Sınanmadı |
| Sandbox + dar sessions istisnası | Başarılı | 1 bayt okundu, errno 0 | version.json ve session_index.jsonl errno 1 ile reddedildi |

Okunan baytın değeri ve JSONL dosya adı çıktıya verilmedi. Auth dosyaları hiç
açılmadı. Kaynak dosyalara yazma denenmedi; read-only kısıtının yazmayı reddi
ayrıca sınanmadı. Dar test uygulaması `sessions` dışındaki veriyi okuyamadı.

Bu test yerel ad-hoc dağıtımı kanıtlar. Developer ID/notarization veya Mac App
Store kabulü ayrıca doğrulanmalıdır. Apple anahtarı temporary exception olarak
belgeliyor ve App Store için gerekçelendirme istiyor. Standart dışı
`CODEX_HOME`, farklı diskler, farklı macOS sürümleri ve hesap değişimi bu
deneyin kapsamı dışındadır.

Çalışma anına ait ham kanıtlar (geçici dizinler temizlenebilir):

- `/tmp/agentnotch-codex-readonly-snapshot-final.json`: filtrelenmiş son veri snapshot'ı.
- `/tmp/agentnotch-codex-event-reliability.json`: anonim olay/DB sayımları.
- `/tmp/agentnotch-codex-sandbox.fcUmlE/sandbox-research.md`: imzalama ve
  çalıştırma komutlarıyla tam sandbox raporu.
- Aynı dizinde `probe.c`, `exception-probe.c`, entitlement dosyaları,
  imzalı test bundle'ları ve ham stdout bulunur. Kaynaklar yalnız bu makinedeki
  test hedeflerini kullanır; üretim entegrasyon kodu değildir.

## Sonraki uygulama adımı

Yerel dağıtım için dar sessions erişimiyle tek bir izleyici ve Swift veri
katmanı yapılabilir. Kullanıcıya yeniden giriş veya Codex dosyası düzenleme
gerekmemesi bu deneyde mümkün bulundu. Dosya izleme/yeniden okuma performansı,
restart, dosya değişimi, gerçek uygulama imzası ve diğer hesap/konum senaryoları
henüz ürün düzeyinde sınanmadı. Widget'ın kota alanı son gözlem olarak, ajan
alanı gözlenen durum ve bilinmiyor ayrımıyla sunulmalıdır. Kesin onay bekleme
gereksinimi varsa ayrıca hooks veya desteklenen runtime olay kaynağı gerekir.

Kaynaklar:

- [OpenAI Hooks](https://learn.chatgpt.com/docs/hooks): transcript formatının
  kararlı arayüz garantisi yoktur; hooks için trust review gerekir.
- [Apple App Sandbox Temporary Exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html):
  home-relative read-only kapsamı ve App Store gerekçelendirmesi.
