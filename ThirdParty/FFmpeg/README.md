# FFmpeg in Srez

Srez includes FFmpeg 9.0.2, Copyright (c) 2000–2026 the FFmpeg developers,
licensed under the GNU Lesser General Public License version 2.1 or later.
Srez runs the `ffmpeg` command as a separate process; it does not link FFmpeg libraries.

The bundled build is for Apple Silicon and macOS 14 or later. It converts local
MP3, WAV, WebM, MP4 and M4A audio to mono 16 kHz PCM WAV. FFmpeg libraries are linked
statically into the command; only macOS system libraries remain dynamic.
GPL and nonfree components, external codec libraries and network protocols are disabled.
The upstream source files are unmodified.

Upstream: https://ffmpeg.org/
Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`
License information: https://ffmpeg.org/legal.html

The application includes these files in `Contents/Resources/FFmpeg`:

- `source.tar.xz`: the exact upstream source archive used for the bundled command.
- `configure.sh`: the configuration used to build that command.
- `COPYING.LGPLv2.1` and `LICENSE.md`: upstream license texts and notices.

To rebuild, copy this folder out of the application, install Xcode Command Line Tools,
and run on an Apple Silicon Mac:

```bash
tar -xf source.tar.xz
cd ffmpeg-9.0.2
bash ../configure.sh
make -j "$(sysctl -n hw.ncpu)" ffmpeg
```

The resulting `ffmpeg` executable can replace `Contents/MacOS/ffmpeg` in a local
copy of Srez. Re-sign that copy after replacement with
`codesign --force --deep --sign - /path/to/Srez.app`.

For a repository checkout, `bash scripts/build-ffmpeg.sh` downloads, verifies and
builds the same version into `.build/ffmpeg`. `make build` packages the command,
sources and license notices into the application automatically.
