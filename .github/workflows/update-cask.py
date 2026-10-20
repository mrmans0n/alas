#!/usr/bin/env python3
"""Generate the alas and alas-host Homebrew casks for both arm64 and x86_64."""
import os
import pathlib
import re
import sys

VERSION = os.environ["VERSION"]
SHA_ARM = os.environ["SHA_ARM"]
SHA_INTEL = os.environ["SHA_INTEL"]
SHA_HOST_ARM = os.environ["SHA_HOST_ARM"]
SHA_HOST_INTEL = os.environ["SHA_HOST_INTEL"]

# Reject anything that isn't a 64-char lowercase hex digest. Catches the
# zero-byte-download failure mode where one of the curl steps in release.yml
# silently produced an empty file, which would otherwise ship a useless cask.
_SHA_RE = re.compile(r"[a-f0-9]{64}")
for name, value in (
    ("SHA_ARM", SHA_ARM),
    ("SHA_INTEL", SHA_INTEL),
    ("SHA_HOST_ARM", SHA_HOST_ARM),
    ("SHA_HOST_INTEL", SHA_HOST_INTEL),
):
    if not _SHA_RE.fullmatch(value):
        sys.exit(f"error: {name} is not a 64-char lowercase hex sha256 ({value!r})")

# Reject tags that would inject quotes/newlines/backslashes into the rendered
# .rb file. The regex matches strict semver plus a permissive suffix for
# pre-release/dry-run tags like "0.0.0-intel-test" or "1.2.3-rc1".
_VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[a-zA-Z0-9._-]*)")
if not _VERSION_RE.fullmatch(VERSION):
    sys.exit(f"error: VERSION does not look like a semver-ish tag ({VERSION!r})")

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

  conflicts_with cask: "alas-host"
  depends_on macos: :sonoma

  app "Alas.app"
  binary "#{{appdir}}/Alas.app/Contents/Resources/alas-host/alas-host"

  # The launchd agents `alas-host install-agent` installs, one per profile.
  # Not on uninstall, which an upgrade runs too: an agent survives upgrades,
  # and stops by itself once the app is gone (it runs while its executable
  # exists). The everyday profile's label is named as is: Homebrew's
  # wildcard matches only agents running at the time.
  zap launchctl: ["io.nlopez.alas.host", "io.nlopez.alas.host.*"],
      trash:     [
        "~/Library/Application Support/Alas",
        "~/Library/Caches/io.nlopez.alas",
        "~/Library/HTTPStorages/io.nlopez.alas",
        "~/Library/LaunchAgents/io.nlopez.alas.host*.plist",
        "~/Library/Preferences/io.nlopez.alas.plist",
        "~/Library/Saved Application State/io.nlopez.alas.savedState",
        "~/Library/WebKit/io.nlopez.alas",
      ]
end
'''

# The headless host alone, for a Mac that runs no app: the host and its web
# client, as package-alas-host.sh lays them out. It links the same command as
# the app's cask, so the two conflict.
HOST_CASK = f'''\
cask "alas-host" do
  version "{VERSION}"

  on_arm do
    sha256 "{SHA_HOST_ARM}"

    url "https://github.com/mrmans0n/alas/releases/download/v#{{version}}/alas-host-#{{version}}-arm64.zip"
  end
  on_intel do
    sha256 "{SHA_HOST_INTEL}"

    url "https://github.com/mrmans0n/alas/releases/download/v#{{version}}/alas-host-#{{version}}-x86_64.zip"
  end

  name "Alas host"
  desc "Headless Alas host serving projects, sessions and runs"
  homepage "https://github.com/mrmans0n/alas"

  conflicts_with cask: "alas"
  depends_on macos: :sonoma

  binary "alas-host/alas-host"

  zap launchctl: ["io.nlopez.alas.host", "io.nlopez.alas.host.*"],
      trash:     "~/Library/LaunchAgents/io.nlopez.alas.host*.plist"
end
'''

# Path is relative to cwd — run from the homebrew-tap repo root.
# release.yml sets `working-directory: homebrew-tap` for this step; the
# Task 3 dry-run in the plan writes a stray Casks/ alongside this repo,
# which is rm'd before commit.
path = pathlib.Path("Casks/alas.rb")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(CASK)
path.with_name("alas-host.rb").write_text(HOST_CASK)
print(f"Updated casks to {VERSION}")
