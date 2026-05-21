#!/usr/bin/env python3
"""Generate the alas Homebrew cask file for both arm64 and x86_64."""
import os
import pathlib
import re
import sys

VERSION = os.environ["VERSION"]
SHA_ARM = os.environ["SHA_ARM"]
SHA_INTEL = os.environ["SHA_INTEL"]

# Reject anything that isn't a 64-char lowercase hex digest. Catches the
# zero-byte-download failure mode where one of the curl steps in release.yml
# silently produced an empty file, which would otherwise ship a useless cask.
_SHA_RE = re.compile(r"[a-f0-9]{64}")
for name, value in (("SHA_ARM", SHA_ARM), ("SHA_INTEL", SHA_INTEL)):
    if not _SHA_RE.fullmatch(value):
        sys.exit(f"error: {name} is not a 64-char lowercase hex sha256 ({value!r})")

CASK = f'''\
cask "alas" do
  version "{VERSION}"

  on_arm do
    sha256 "{SHA_ARM}"
    url "https://github.com/mrmans0n/alas/releases/download/v#{{version}}/Alas-#{{version}}-arm64.dmg"
  end
  on_intel do
    sha256 "{SHA_INTEL}"
    url "https://github.com/mrmans0n/alas/releases/download/v#{{version}}/Alas-#{{version}}-x86_64.dmg"
  end

  name "Alas"
  desc "AI parallel agent orchestrator"
  homepage "https://github.com/mrmans0n/alas"

  depends_on macos: :sonoma

  app "Alas.app"

  zap trash: [
    "~/Library/Application Support/Alas",
    "~/Library/Caches/io.nlopez.alas",
    "~/Library/HTTPStorages/io.nlopez.alas",
    "~/Library/Preferences/io.nlopez.alas.plist",
    "~/Library/Saved Application State/io.nlopez.alas.savedState",
    "~/Library/WebKit/io.nlopez.alas",
  ]
end
'''

path = pathlib.Path("Casks/alas.rb")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(CASK)
print(f"Updated cask to {VERSION}")
