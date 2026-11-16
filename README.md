# Srez

Приложение для транскрибирования и суммаризации записей встреч.

## Установка

```
brew install --cask mishamyrt/tap/srez
```

## Выпуск версии

В GitHub Secrets репозитория нужно добавить:

- `BUILD_CERTIFICATE_BASE64` — сертификат подписи вместе с приватным ключом в формате P12, закодированный в Base64.
- `P12_PASSWORD` — пароль P12.
- `HOMEBREW_TAP_TOKEN` — токен с правом Contents: read and write для `mishamyrt/homebrew-tap`.

Публикация запускается по тегу `vX.Y.Z`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

После успешной сборки, тестов и линтера CI подписывает приложение и встроенный FFmpeg,
публикует ZIP и SHA-256 в GitHub Release, затем обновляет `Casks/srez.rb` в tap.
Версия в приложении берётся из тега. Сборка предназначена для Apple Silicon и macOS 14+.

Сертификат самоподписный, без notarization. Cask снимает `com.apple.quarantine`
с установленного приложения и его содержимого. Для этого требуется актуальный Homebrew
с поддержкой `postflight_steps`.
