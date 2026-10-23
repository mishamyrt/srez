#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
build="$repo/.build/ffmpeg"
version="9.0.2"
source_sha="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
archive="$build/source.tar.xz"
source="$build/source"
log="$repo/.build/ffmpeg-build.log"
mkdir -p "$build"

if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | awk '{ print $1 }')" != "$source_sha" ]]; then
    echo "Скачивание исходников FFmpeg $version…"
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 180 \
        "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive.part"
    printf '%s  %s\n' "$source_sha" "$archive.part" | shasum -a 256 --check --status
    mv "$archive.part" "$archive"
fi

fingerprint=$(shasum -a 256 "$repo/scripts/build-ffmpeg.sh" | awk '{ print $1 }')
if [[ -x "$build/ffmpeg" && -f "$build/build.sha256" ]] && [[ "$(cat "$build/build.sha256")" == "$fingerprint" ]]; then
    exit 0
fi

echo "Сборка встроенного FFmpeg $version…"
rm -rf "$source"
mkdir -p "$source"
tar -xJf "$archive" --strip-components=1 -C "$source"
# Keep native audio support without enabling third-party codec libraries.
audio_decoders=$(sed -n '/^\/\* audio codecs \*\//,/^\/\* subtitles \*\//p' "$source/libavcodec/allcodecs.c" \
    | sed -n 's/^extern const FFCodec ff_\(.*\)_decoder;$/\1/p' | paste -sd, -)
[[ -n "$audio_decoders" ]]
arguments=(
    --cc=/usr/bin/clang --arch=aarch64 --target-os=darwin
    --extra-cflags="-arch arm64 -mmacosx-version-min=14.0"
    --extra-ldflags="-arch arm64 -mmacosx-version-min=14.0"
    --pkg-config=/usr/bin/false
    --disable-autodetect --disable-gpl --disable-nonfree --disable-shared --enable-static
    --disable-everything --disable-programs --enable-ffmpeg
    --disable-avdevice --disable-swscale --disable-network --disable-doc --disable-debug --enable-small
    --enable-protocol=file --enable-demuxer=mov,matroska,mp3,wav
    "--enable-decoder=$audio_decoders,speex,s302m" --enable-parsers
    --enable-encoder=pcm_s16le --enable-muxer=wav --enable-filter=aresample --enable-zlib
)
printf '#!/bin/bash\nexec ./configure' > "$build/configure.sh"
printf ' %q' "${arguments[@]}" >> "$build/configure.sh"
printf '\n' >> "$build/configure.sh"
if ! (
    cd "$source"
    ./configure "${arguments[@]}"
    make -j "$(sysctl -n hw.ncpu)" ffmpeg
) > "$log" 2>&1; then
    tail -100 "$log"
    exit 1
fi

cp "$source/ffmpeg" "$build/ffmpeg"
xcrun strip -x "$build/ffmpeg"
lipo -verify_arch arm64 "$build/ffmpeg"
if otool -L "$build/ffmpeg" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { print; bad = 1 } END { exit !bad }'; then
    echo "Встроенный FFmpeg зависит от внешних библиотек." >&2
    exit 1
fi
printf '%s\n' "$fingerprint" > "$build/build.sha256"
