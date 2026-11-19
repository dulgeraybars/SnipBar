# SnipBar

Çok hafif, tamamen yerel bir macOS menü çubuğu ekran alıntısı uygulaması.

- Makas simgesine sol tık veya **⌃⌥S**: alan seçme ekranı açılır (macOS'un kendi seçimi, `screencapture -i -c`).
  - Alanı **sol tuşla** seçersen görüntü panoya kopyalanır, başka bir şey olmaz.
  - Alanı **sağ tuşla** seçersen görüntü belleğe alınır ve küçük bir düzenleme penceresi açılır; bu sırada panoya hiçbir şey yazılmaz.
- Düzenleme penceresi: kırmızı kare, kalem, siyah kapatma kutusu (Shift + sürükle), yazı ve geri al (⌘Z).
  **Bitti** veya Enter sonucu panoya bir kez kopyalar ve kapatır; Esc ya da sol üstteki çarpı kopyalamadan kapatır (pano değişmez).
  Ekranın üstünde başka bir uygulamanın tam genişlikte yüzen bir şeridi varsa (ör. bir pano ya da ekran görüntüsü rafı), pencere onun altında açılır.
- Simgeye sağ tık: menü (Alan Seç, Mac açılışında başlat, Çıkış).
- İnternet, hesap, dosya kaydı yok. Dock'ta görünmez.

## Derleme

macOS 13+ ve Xcode komut satırı araçları gerekir:

```
./build.sh
open SnipBar.app
```

İlk yakalamada **Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Ses Kaydı** altında SnipBar'a izin verin ve uygulamayı yeniden başlatın.
`build.sh` varsayılan olarak ad-hoc imzalar; bu durumda macOS her yeniden derlemeden sonra izni tekrar ister.
