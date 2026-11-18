# SnipBar

Çok hafif, tamamen yerel bir macOS menü çubuğu ekran alıntısı uygulaması.

- Makas simgesine sol tık veya **⌃⌥S**: alan seç (`screencapture -i -c`), görüntü otomatik panoya kopyalanır.
- Görüntü küçük bir düzenleme penceresinde açılır: kırmızı kare, kalem, siyah kapatma kutusu (Shift + sürükle), yazı, geri al (⌘Z).
- **Enter** / Kopyala: işaretli son hâli panoya yazar. **Esc** / çarpı: işaretleri atar, düz görüntü panoda kalır.
- Sağ tık: menü (Alan Seç, Mac açılışında başlat, Çıkış).
- İnternet, hesap, dosya kaydı yok. Dock'ta görünmez.

## Derleme

macOS 13+ ve Xcode komut satırı araçları gerekir:

```
./build.sh
open SnipBar.app
```

İlk yakalamada **Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Ses Kaydı** altında SnipBar'a izin verin ve uygulamayı yeniden başlatın.
`build.sh` varsayılan olarak ad-hoc imzalar; bu durumda macOS her yeniden derlemeden sonra izni tekrar ister.
