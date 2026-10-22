# Hook kuyruğu ve okuyucu belleği düzenlemesi

- Tarih: 22 Ekim 2026
- Başlangıç: `9650c6a` — sürekli tarama ve doğrulama düzeltmesi.
- Kapsam: performans incelemesindeki P08, P09 ve P10.
- Durum: kod ve regresyon senaryoları hazırlandı; kullanıcının isteğiyle test, derleme ve benchmark çalıştırılmadı. Toplu doğrulama bekleniyor.
- Bu değişiklikler için ölçülmüş CPU, RSS veya pil kazancı henüz yoktur. Önceki izleme benchmark'ının sonucu bu değişikliklerin doğrulaması değildir.

## 1. Hook kuyruğu: P08

### Değişen işlem yolu

Önce her native hook çağrısı dizin kilidini alıyor, bütün UUID olay dosyalarını dolaşıyor, dosya özelliklerini kontrol ediyor ve temizliğin ardından tek bir olay yazıyordu. Dolu kuyrukta bu tarama her yeni olay için tekrarlanıyordu.

İki helper artık aynı [HookSpool.swift](../../Native/HookSpool.swift) uygulamasını derliyor. Normal çağrı küçük bir checkpoint okur, geçerli ise tam taramayı atlar, olayı atomik olarak yayınlar ve sayacı günceller. Checkpoint yalnız sürüm, son temizlik zamanı, olay sayısı ve dizin kimliği/değişim damgasını içerir; oturum veya konuşma içeriği içermez.

Tam tarama şu durumlarda yapılır:

- İlk kullanım veya eksik/bozuk checkpoint.
- Son temizlikten itibaren 60 saniyenin dolması.
- Kuyruk sayacının 4096 olay sınırına ulaşması.
- Dizin damgasının değişmesi: başka yazıcı, dışarıdan ekleme/silme, önceki sürüm helper veya yarım kalmış yayın gibi durumlar.
- Duvar saatinin son temizlik zamanının gerisine alınması.
- Checkpoint'in güvenli biçimde kullanılamaması; bu durumda checkpoint değiştirilmeden korumacı tam tarama yapılır.

Checkpoint, tüm katılımcı helper'ların kullandığı aynı dizin `flock` kilidi altında okunur ve güncellenir. Böylece eşzamanlı çağrılar aynı sayacı birbirinin üzerine yazmaz. JSON işleme, alan temizleme ve fingerprint üretimi kilit alınmadan önce tamamlanır; kilit altındaki iş kuyrukla sınırlıdır.

### Sınırlar ve açık davranış değişikliği

| Konu | Yeni davranış |
| --- | --- |
| Olay sayısı | İşbirliği yapan helper yazıcıları en fazla 4096 geçerli, sahipliği doğrulanan UUID `.json` dosyası bırakır |
| Kapasite temizliği | 4096 ve üzerindeki kuyruk en yeni 3072 olaya düşürülür; ardından yeni olay yayınlanır |
| Dolu kuyrukta tekrar tarama | Süre veya dış değişiklik daha erken gerektirmezse yaklaşık her 1024 yeni olayda bir kapasite temizliği |
| Yaş temizliği | 7 günden eski olaylar bir sonraki gerekli temizlikte kaldırılır |
| Yaş sınırı toleransı | Aktif ve sağlıklı kuyrukta temizlik aralığı nedeniyle yaklaşık 60 saniyeye kadar gecikme olabilir; hiç hook çağrısı yoksa temizlik çalışmaz |
| Büyük eski kuyruk | Geçici temizlik metadata'sı en fazla 8192 kayıtla sınırlanır; ara elemelerde en yeni kayıtlar korunur |
| Checkpoint | Özel dizinde `.spool-state-v1`; okuma sınırı 1024 bayt, normal dosya ve tek hardlink zorunlu |

**Kapasiteye gelindiğinde eski olay geçmişi önceki sürümden daha erken silinir.** Bu, dolu kuyrukta her olay başına taramayı kaldırmak için seçilen bellek/geçmiş dengesidir. Sınırsız veya eksiksiz geçmiş garantisi yoktur; önceki sürüm de 4096 olayla sınırlıydı. Sürekli çalışan reducer'ın işlediği durum korunur; uygulama kapalıyken çok yoğun trafik sonrası yeniden açılış yalnız elde kalan yakın geçmişi okuyabilir.

Yeni sıralama dosya değiştirilme zamanının saniye ve nanosaniyesini, eşitlikte dosya adını kullanır. Böylece büyük eski kuyruklarda dizin dolaşım sırasına bağlı rastgele kayıt atma yerine en yeni kayıtlar seçilir. Orijinal helper da zaman damgası değiştirilmiş dosyaları dosyanın mtime değerine göre temizliyordu; olay JSON'u bu amaçla açılmaz.

### Korunan sözleşmeler

- Olay yayını özel geçici dosya ve `renameat` ile atomiktir; dosyalar `0600` oluşturulur.
- Paylaşıma açık veya symlink olay dizinine yazılmaz; açılan dizinin inode/cihaz/sahipliği doğrulanır.
- Temizlik yalnız sahibi mevcut kullanıcı olan, normal UUID `.json` dosyalarını hedefler. Kullanıcı dosyaları ve symlink hedefleri silinmez.
- Checkpoint için symlink, hardlink, paylaşıma açık dosya, FIFO ve aşırı boyut reddedilir; güvensiz checkpoint içeriği değiştirilmez.
- Checkpoint yazılırken süreç kesilirse sonraki helper bozuk içeriği veya değişmiş dizin damgasını görüp yeniden tarar. Checkpoint atomik olay tesliminin yerine geçmez.
- Kilit bekleme sınırı 0,5 saniye ve helper'ın toplam iş bütçesi korunur. Hatalar hook stdout'una onay yanıtı yazmaz; helper başarılı çıkışla istemcinin akışını sürdürür. Bu, tüm olayların her koşulda teslim edileceği garantisi değildir; kilit/zaman/IO hatalarında önceki sürüm gibi olay atlanabilir.
- Claude'un mevcut status-line komutuna tam stdin aktarımı ve stdout koruması aynı kalır. Entegrasyon kurulumu/kaldırılması, kullanıcı onayı ve diğer hook tanımları değiştirilmez.

### Beklenen kazanç ve maliyet

Sıcak kuyruğa ekleme maliyeti, bütün kuyruktaki dosya sayısına bağlı taramadan sabit boyutlu checkpoint işlemlerine iner. Bu en çok yoğun araç kullanımında native helper CPU'sunu, dosya metadata işlemlerini ve kilit süresini azaltma potansiyeli taşır. Süreç başlatma, JSON/fingerprint ve atomik olay yazımı devam eder. Her çağrı ayrıca küçük checkpoint IO'su yapar; boş veya çok küçük kuyruklarda aynı oranda kazanç beklenmemelidir.

Tarama sıklığındaki teorik azalma, toplam uygulama CPU'sunun aynı oranda azalması anlamına gelmez. Gerçek etki helper süreçleri de ölçülerek doğrulanmalıdır.

## 2. Codex blok okuyucu ve indeksler: P09

[CodexUsageReader.swift](../../Sources/Features/Widgets/Codex/CodexUsageReader.swift) artık 64 KiB parçaların içinde `memchr` ile satır sonlarını bulur. Tek tek bayt eklemek yerine aralık ekler. Parçanın içinde tamamlanan satır doğrudan ayrıştırılır; yalnız parçalar veya yenilemeler arasında bölünen satır için büyüyen tampon gerekir.

- 1 MiB satır sınırı korunur; tam sınır kabul edilir, sınırı aşan satır sonraki newline'a kadar atlanır.
- UTF8 karakterleri parçalar arasında bölünebilir; JSON ayrıştırması yalnız satır tamamlanınca yapılır.
- 64 KiB üzerindeki tamamlanan geçici satır tamponları bırakılır.
- EOF'ta tamamlanmış satırın boş scratch tamponu bırakılır. Gerçek kısmi satır ve dosya offset'i korunur.
- Aşırı uzun satır tespit edildiğinde büyük tampon hemen bırakılır.
- Başarılı keşifte artık bulunmayan dosya durumları ve dosya anahtarları temizlenir. Hedefli silme yolu da aynı indeksleri kaldırır.
- Hesap kimliği eşlemeleri yaşayan dosyalara göre budanır. Kaynağı silinmiş olsa da özellikle tutulan son tarihli kota gözleminin tek kimliği korunur.
- Geçici erişim/keşif hatalarında önceki hesapları silip başka hesabı yanlışlıkla seçme koruması korunur.

Kısalma/değişim algılama, alt ajandan kopyalanan geçmişin ordinal sınırı, farklı hesapların belirsizliği, ileri tarihli kota/aktivite ve saat geri alınmasındaki yeniden okuma korunması gereken regresyon sözleşmeleridir. İlgili mevcut senaryolar toplu testte tekrar çalıştırılmalıdır.

Beklenti ilk okuma ve büyük eklemelerde daha az CPU/yeniden tahsis ve tamamlanan büyük satırların ardından daha az tutulan tampon kapasitesidir. Gerçek kısmi satır başına en fazla 1 MiB tutma gereksinimi sürer. Dosyalar hâlâ mevcutken bunların özet durumları tutulur; bu çalışma bütün okuyucu belleğini sabit bir sayıya indirmez.

Tanısal `pendingBytes` değeri yalnız canlı kısmi bayt sayısını gösterir. Foundation kapasitesi, allocator'ın geri tuttuğu sayfalar ve süreç RSS'i aynı şey değildir; testte sıfır bayt görülmesi RSS'in aynı miktarda düşeceğini kanıtlamaz.

## 3. Widget ve önbellek yaşam döngüsü: P10

[CodexStore.swift](../../Sources/Features/Widgets/Codex/CodexStore.swift) ve [ClaudeStore.swift](../../Sources/Features/Widgets/Claude/ClaudeStore.swift) okuyucularını artık ilk `start()` çağrısında oluşturur. Hiç kullanılmayan widget için monitor nesnesi oluşturulmaz.

| Durum | Davranış |
| --- | --- |
| Widget görünür uygulamada seçili | İzleme sürer; kapalı çekmecedeki küçük göstergeler ve izin uyarıları korunur |
| Uygulama gizlenmiş, widget hâlâ seçili | İzleme durur; okuyucu en fazla 60 saniye tutulur |
| Bu süre içinde yeniden gösterme | Önbellek bırakma iptal edilir; ilk uzlaştırma diskteki değişiklikleri bulur |
| Gizliyken tekrar eden ayar bildirimleri | 60 saniyelik süre baştan başlamaz |
| Widget kaldırma | Monitor sahipliği ve sunum önbellekleri hemen bırakılır |
| Uzun gizleme | 60 saniye sonunda okuyucu ve sunum önbellekleri bırakılır |
| Gizli önbellekte bellek baskısı | warning/critical bildirimi süreyi beklemeden bırakmayı tetikler |
| Aktif izleme sırasında bellek baskısı | Aktif reducer sıfırlanmaz; bu düzenlemede baskı temizliği yalnız durdurulmuş önbelleğe uygulanır |
| Retry, başarılı bağlantı değişimi | Eski okuyucu bırakılır; gerekiyorsa güncel home/helper ile yeniden oluşturulur |

Ortak [MonitorCacheRetention](../../Sources/Features/Widgets/Monitoring/LocalMonitorDriver.swift) hem süreyi hem bellek baskısı kaynağını yönetir. Yeniden başlatma eski süreyi ve baskı kaynağını iptal eder; generation/cancellation koruması eski callback'lerin yeni yaşam döngüsüne karışmasını engeller.

Temizlenen durum monitor içindeki dosya özetleri, kısmi satırlar, olay tekrar önleme kümeleri, runtime ve kota önbellekleriyle birlikte store'un ajan/kota/son-hook sunumudur. Aktif dosya izleyicilerinin kapanışı kendi seri kuyruğunda tamamlanır; devam eden kısa bir iş varsa son referans bu iş bittikten sonra bırakılır.

Bağlantı kurulumu ve izin bookmark'ı silinmez. Son durum `receiving` ise önbellek atılırken `waitingForEvents` durumuna döner. Yeniden eklemede disk yeniden okunur; bellek kazancının karşılığı soğuk açılışta daha fazla okuma ve verinin kısa süre sonra tekrar görünmesidir. Gözlemlenmiş durum olmadan eski bir izin veya kota güncelmiş gibi gösterilmez.

## 4. Hazırlanan regresyonlar ve toplu doğrulama

**Bu bölüm bir başarılı test raporu değildir. Aşağıdaki yeni ve mevcut kontroller henüz çalıştırılmadı.**

Yeni Swift senaryoları:

1. 64 KiB sınırında bölünen UTF8, çok parçalı satır, yenilemeler arasında kalan yarım kayıt ve boş satırlar.
2. Tam 1 MiB satırın kabulü, aşırı büyük bitmemiş satır tamponunun bırakılması ve sonraki satıra dönüş.
3. Silinen/değişen dosya ve hesap indekslerinin budanması; son tarihli kotanın korunması.
4. Codex widget kaldırma, sıcak duraklatma ve diskte değişiklik sonrası yeniden ekleme.
5. Claude widget kaldırma, kota durumunun bırakılması ve yeniden ekleme.
6. Süreli önbellek temizliği, yeniden gösterme iptali ve baskıyla aynı giriş noktasından hemen bırakma.

Her iki gerçek native helper'a uygulanacak ortak Python senaryoları:

1. Ayrı helper süreçleri arasında sıcak checkpoint sayacı ve temizlik zamanının korunması.
2. Yaş temizliğinin süre dolunca yapılması ve saat geri alınmasının yeniden taramayı tetiklemesi.
3. Dışarıdan kuyruk değişimi ve yarım/bozuk checkpoint sonrası toparlanma.
4. Symlink, hardlink, paylaşıma açık dosya, FIFO ve aşırı büyük checkpoint'e dokunmadan olay teslimi.
5. 4096 sınırında en yeni olayları tutan toplu temizlik ve sonraki olayın tekrar tam tarama yapmaması.

Mevcut paralel yazıcı senaryolarına checkpoint sayacının da teslim edilen 48 olayla eşleşmesi eklendi. Mevcut 7 günlük temizleme/kullanıcı dosyası koruma senaryolarının beklenen kayıt sayıları yeni kapasite politikasına uyarlandı. Claude status-line zinciri, mahremiyet, zaman aşımı ve onay yanıtı üretmeme senaryoları mevcut test paketinde kalır.

Sonraki toplu doğrulama sırası:

1. `AGENTNOTCH_TEST_SCOPE=codex bash Tests/run.sh` ile her iki native helper ve Swift bileşen regresyonları.
2. `AGENTNOTCH_TEST_SCOPE=desktop bash Tests/run.sh` veya uygun masaüstü ortamında tam suite; ortam kaynaklı sorunlar ayrı raporlanmalı.
3. Release Xcode derlemesi, helper mimarileri/paket içeriği ve imza denetimi. İki helper build phase'i ve build betikleri yeni ortak Swift kaynağını içerir.
4. İmzalı gerçek uygulamada dar izinli dosya izleme, kaldırma/gizleme/yeniden açma ve özel Claude status-line kontrolü.
5. Helper yoğun trafik ölçümü: boş, yaklaşık 3000 ve 4096 olaylı kuyruk; tek ve eşzamanlı yazıcı; helper CPU'su, duvar zamanı, kaçan olay ve kilit gecikmesi.
6. Codex büyük JSONL ilk okuma ve ekleme ölçümü; sonra widget kaldırma, 60 saniyelik gizleme ve yeniden açılışta heap/RSS/CPU karşılaştırması.

Bu turda yalnız kaynak/diff incelemesi ve `git diff --check` yapıldı. Test, uygulama derlemesi, benchmark ve canlı kurulum yapılmadı. Ölçüm tamamlanmadan toplam yüzde kazanç veya MB tasarrufu belirtmek doğru değildir.
