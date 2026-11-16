#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?Usage: generate-cask.sh vX.Y.Z}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release tag must have the form vX.Y.Z." >&2
    exit 1
fi
version="${tag#v}"
archive=".build/release/Srez-${tag}-macos-arm64.zip"
sha256=$(shasum -a 256 "$archive" | awk '{ print $1 }')

cat <<EOF
cask "srez" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/mishamyrt/srez/releases/download/v#{version}/Srez-v#{version}-macos-arm64.zip"
  name "Srez"
  desc "Meeting transcription and summarization"
  homepage "https://github.com/mishamyrt/srez"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Srez.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Srez.app"]
  end
end
EOF
