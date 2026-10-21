# Codex widget uygulama planı

## Kullanıcı deneyimi

Codex kartı widget kataloğundan eklenir. Aboneliğin son bilinen kısa/uzun dönem
kotası, yenilenme zamanı ve son güncelleme gösterilir. Tek kullanıcı düzeyi
hooks entegrasyonu desteklenen yerel oturumların görev/alt ajan ve izin isteği
olaylarını iletir. Yeniden hesap girişi veya elle dosya düzenleme gerekmez.

İlk kurulum ekranı sonraki aşamadır. Bu sürümde onun kullanacağı kurulum ve
kaldırma katmanı ile widget içinden açıkça etkinleştirilebilen bağlantı akışı
hazırlanır. Geliştirme/test sırasında gerçek Codex hooks/config/trust dosyaları
değiştirilmez; tüm kurulum testleri geçici Codex dizinlerinde çalışır.

## İş paketleri

1. **Ortak hook yardımcısı:** native, paketlenen tek executable; sınırlı JSON
   girdisinden yalnız olay kimliği, oturum/turn/alt ajan kimliği, proje adı,
   araç adı ve kısa izin gerekçesini atomik yerel olay dosyalarına aktarır.
   Prompt, shell komutu, cevap ve kimlik bilgisi saklanmaz. Stdout boş kalır;
   Codex'in izin kararına veya konuşmasına müdahale etmez.
2. **Kurulum/kaldırma:** kullanıcı düzeyi hooks.json'a yalnız kendi tanımlarını
   ekleyen, mevcut tanımları koruyan, idempotent ve geri alınabilir installer.
   Güven onayı Codex'te kalır; trust hash'leri otomatik yazılmaz. Tanımlar
   değiştiğinde yeniden güven onayı gerekebileceği açıkça belirtilir.
3. **Durum modeli:** olay bazında görev ve alt ajan durumları; tekrar/gecikmiş
   olaylar, eşzamanlı izinler, farklı turn'ler, bitiş ve kesilme ayrıştırılır.
   PermissionRequest 'izin isteği' anlamına gelir; başka hook otomatik izin
   verebileceğinden kesin kullanıcı bekleme iddiası yapılmaz. PostToolUse araç
   çıktı ürettikten sonra gelir; onayın verildiği anı kanıtlamaz. Çözülemeyen
   eski istek bilinmiyor olur, kendiliğinden tamamlanmış sayılmaz.
4. **Kota okuyucusu:** yalnız sessions altında artımlı JSONL; fork geçmişi,
   kısmi satır, dosya değişimi/kısalması, geçersiz alan ve çoklu hesap ayrımı.
   Kota son gözlem olarak kalır; reset geçmiş diye yenilenme uydurulmaz.
5. **Store ve arayüz:** panel yaşam döngüsüyle açılıp kapanan tek store;
   arka planda kota ve hook olaylarını okur. İki sütunlu kartta kota, kısa ajan
   listesi ve turuncu izin bildirimi; kapalı çentikte küçük bildirim göstergesi.
   Bağlantı yok/bekliyor/bilinmiyor ve yeniden deneme TR/EN yerelleştirilir.
6. **Doğrulama:** event/helper/installer/reader testleri; geçici kurulumla
   uçtan uca olay aktarımı; mevcut Swift testleri ve Xcode build; gerçek
   SwiftUI kartının bağlanmamış/çalışan/izin/eskimiş durumlarının render kontrolü.

## Erişim ve teslim sınırları

App Sandbox korunur. Standart ~/.codex/sessions için read-only; yalnız
~/.codex/hooks.json ve ~/.codex/agentnotch/ için read-write istisna vardır.
Atomik hooks.json güncellemesi kendi dizininde hazırlanıp rename ile değiştirilir;
üst Codex dizininin tamamı için erişim açılmaz. Kurulumda NSOpenPanel yoktur:
konum otomatik keşfedilir, kullanıcı yalnız Etkinleştir/Vazgeç onayı verir.
Keşif, yenileme ve iptal hiçbir kurulum dosyası yazmaz.

Standart konum, uygulamaya aktarılmış mutlak CODEX_HOME ve önceden kaydedilmiş
security-scope izni kullanılır. GUI uygulaması terminaldeki aktarılmamış ortamı
okumuş sayılmaz. Özel konumlar mevcut sandbox erişimiyle sınırlıdır; bulunamayan
özel konum yerine varsayılan kuruluma sessizce yazılmaz. Symlink, yabancı sahip
ve dosya hedefleri reddedilir. Kimlik/config dosyaları taranmaz. Codex'in kendi
hook güven kararı ayrıca kullanıcıya aittir. App Store/Developer ID dağıtım onayı
bu yerel build'in kanıtladığı kapsamın dışındadır.

Yerel kayıt erişimi sürekli tüm sohbetleri yeniden taramayacak; oturum
keşfi sınırlı aralıkla, dosya içeriği artımlı işlenir. Olaylar sıralanır,
yeniden başlatmada eski onaylar tazeymiş gibi gösterilmez. Hook akışı dışındaki
bulut görevleri kapsanmış sayılmaz.

Referans: https://learn.chatgpt.com/docs/hooks

## Tamamlanan doğrulama

- Ortak native helper, 9 olay tanımı ve installer/remove katmanı tamamlandı.
- Swift durum modeli, artımlı kota okuyucu ve arka plan store tamamlandı.
- Widget kataloğu, TR/EN kart, sağ izin göstergesi ve ayarlardaki açık
  bağlan/kaldır akışı tamamlandı. Karttaki Bağlan, ayarlar penceresine yönlendirir;
  ayarlar açıkken çentik kapalı ve fareye geçirgendir. GPT ikonlu kart 180 pt;
  kota solda, ajan/izin bilgileri sağdadır. Tam ilk açılış sihirbazı sonraki aşamadır.
- `bash Tests/run.sh`: **91/91 Swift testi**, **8/8 paketlenmiş helper testi**
  ve native medya serializer kontrolü geçti. Gerçek helper → geçici spool →
  store akışında izin, ilgisiz çıktı, eşleşen çıktı, bitiş ve durdurma sınandı.
- Otomatik konum keşfi, iptalde sıfır yazma, onaydan sonra kurulum, çift
  tıklama, bulunamayan kurulum ve production ile aynı dizin URL biçimi sınandı.
- İmzalı ayrı sandbox uygulamasında gerçek installer ile **14/14** kontrol
  geçti: olmayan/mevcut hook dosyası, idempotence, kaldırma, yabancı hook ve
  0640 modunu koruma; auth okuma/yazma ve başka kardeş dosyaya yazma reddi.
  Ham `/private/tmp` dizin URL biçimiyle de doğrulandı. Tekrar çalıştırma:
  `python3 Research/CodexReadOnly/sandbox-hooks-probe.py`.
- Araştırma okuyucusunun **21/21** testi geçti.
- Xcode Debug build başarılı; uygulama ve helper **arm64 + x86_64** içeriyor.
  `codesign --verify --deep --strict` başarılı.
- Gerçek SwiftUI kartının dört hali TR/EN render edilip incelendi:
  `/tmp/agentnotch-codex-visual/images/`.
- Üretimle aynı sandbox entitlement'larıyla imzalanan ayrı test uygulaması,
  gerçek Swift kota okuyucusuyla `availability=available files=47 snapshot=true`
  sonucu verdi. Yalnız erişim sonucu yazdırıldı; global hook kurulumu yapılmadı.
- Başlangıçta mevcut olan String Catalog girişleri içerik olarak korundu;
  yalnız Codex anahtarları eklendi. Xcode'un çıkardığı literal marka metni için
  semantic key kapsam testi düzenlendi.

Gerçek Codex hook güven onayı ve canlı insan onay ekranı geliştirme sırasında
otomatik uygulanmadı. Bağlantı için uygulamada tek Etkinleştir onayı vardır;
Codex’in kendi güven incelemesi ayrıca kullanıcı tarafından yapılır. Kullanıcıya ait gerçek
Codex config, hook ve trust dosyaları bu çalışmada değiştirilmedi.


## 2026-10-21: Karantina ve canlı etkinlik düzeltmesi

Kernel günlüğü, v1 yardımcı kopyasının sandbox içinden oluşturulduğu için
`0x86` karantina bayrağıyla çalıştırılmadığını doğruladı. v2 kurulum paket
kaynağını doğrudan çalıştırır; yalnız JSON manifest/hook dosyalarını yazar.
Doğrulanmış eski kurulum ayarlardaki Onar işlemiyle taşınır. Hook komutu
değiştiğinden Codex'in kendi güven incelemesi tekrar gerekir; güven kayıtları
uygulama tarafından değiştirilmez.

Oturum okuyucusu kota yanında başlangıç/bitiş/kesilme/hata metadata'sını da
artımlı okur. Fork geçmişi dışlanır; alt ajan kimliği/nickname/üst ilişkisi
korunur. Sonuç hook durumuyla thread/turn üzerinden birleştirilir. Logdaki
aynı tur terminal kanıtı geciken hook'u bastırır. İsimli kaydırılabilir ajan
listesi onay uyarısıyla birlikte kalır; kapalı çentik çalışma/onay/hata gösterir.
Okuma bir saniyelik aralıkla yapılır. Kaynak sessizliğinde kesin canlılık
iddia edilmez; beş dakika sonra bilinmiyor olur.

Gerçek salt okunur gözlemde 53 dosya, sıfır okuma hatası; ana oturumun working,
Goodall alt ajanının finished → working geçişi doğru görüldü. Kod tarafındaki
shell entegrasyonu geçici fixture üzerinde çalışır. Tam uygulama/macro,
WindowServer önizlemesi ve ayrı sandbox uygulamasının başlatılması mevcut
yürütme ortamınca engellendi; gerçek kullanıcı bağlantısının yeni sürümde
onarılıp güven onayı verilmesi hâlâ canlı uçtan uca doğrulama adımıdır.
