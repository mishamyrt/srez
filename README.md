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

Установите генератор changelog:

```sh
brew install git-cliff
```

Версия хранится в `Makefile`: `VERSION` — версия приложения, `VERSION_BUNDLE` — номер сборки.
`make build` подставляет их в `App/Info.plist.tpl`. Сгенерированный `App/Info.plist` не хранится в Git.

Закоммитьте изменения и запустите выпуск:

```sh
make publish VERSION=1.0.0
```

Команда обновляет версию в Makefile, генерирует `CHANGELOG.md` из Conventional Commits
по правилам `cliff.toml`, создаёт release-коммит и тег `vX.Y.Z`, затем отправляет их в `origin`.
Можно заранее изменить версию в Makefile и вызвать `make publish` без аргументов.
Остальные изменения в рабочей директории должны быть закоммичены.

После успешной сборки, тестов и линтера CI подписывает приложение и встроенный FFmpeg,
публикует ZIP и SHA-256 в GitHub Release, затем обновляет `Casks/srez.rb` в tap.
Описание GitHub Release берётся из соответствующего раздела changelog.
В CI версия для шаблона берётся из тега, а номер сборки — из `GITHUB_RUN_NUMBER`.
Сборка предназначена для Apple Silicon и macOS 14+.

Сертификат самоподписный, без notarization. Cask снимает `com.apple.quarantine`
с установленного приложения и его содержимого. Для этого требуется актуальный Homebrew
с поддержкой `postflight_steps`.
