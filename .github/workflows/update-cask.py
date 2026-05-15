#!/usr/bin/env python3
"""Generate the alas Homebrew cask file."""
import os
import pathlib

VERSION = os.environ["VERSION"]
SHA_ARM = os.environ["SHA_ARM"]

CASK = f'''\
cask "alas" do
  version "{VERSION}"
  sha256 "{SHA_ARM}"

  url "https://github.com/mrmans0n/alas/releases/download/v#{{version}}/Alas-#{{version}}-arm64.dmg"
  name "Alas"
  desc "AI parallel agent orchestrator"
  homepage "https://github.com/mrmans0n/alas"

  depends_on arch: :arm64
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
