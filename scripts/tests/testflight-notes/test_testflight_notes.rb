# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../../testflight-notes.rb", __dir__)
CHANGELOG_HELPER = File.expand_path("../../../Mobile/fastlane/testflight_changelog.rb", __dir__)

class TestflightNotesTest < Minitest::Test
  def render(root, version: "0.24.2", url: "https://example.test/releases/tag/v0.24.2")
    Open3.capture3("ruby", SCRIPT, "--root", root, "--version", version, "--release-url", url)
  end

  def write(root, path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def test_prefers_explicit_release_specific_copy
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.2.md", "Try the new transcript cards.\n")
      stdout, stderr, status = render(root)

      assert status.success?, stderr
      assert_equal "Try the new transcript cards.\n\nRelease notes: https://example.test/releases/tag/v0.24.2\n", stdout
    end
  end

  def test_fastlane_reader_preserves_generated_bytes_exactly
    Dir.mktmpdir do |root|
      path = File.join(root, "notes.txt")
      expected = "Try transcript cards.\n\nRelease notes: https://example.test/releases/tag/v0.24.2\n"
      File.binwrite(path, expected)
      stdout, stderr, status = Open3.capture3(
        "ruby", "-r", CHANGELOG_HELPER, "-e",
        "print TestflightChangelog.read(changelog_file: ARGV.fetch(0))", path
      )

      assert status.success?, stderr
      assert_equal expected.b, stdout.b
    end
  end

  def test_fastlane_reader_returns_valid_utf8_without_changing_bytes
    Dir.mktmpdir do |root|
      path = File.join(root, "notes.txt")
      expected = "Try Alas’s richer transcript cards.\n\nRelease notes: https://example.test/releases/tag/v0.24.2\n"
      File.binwrite(path, expected)
      program = <<~RUBY
        notes = TestflightChangelog.read(changelog_file: ARGV.fetch(0))
        abort "wrong encoding" unless notes.encoding == Encoding::UTF_8
        abort "invalid UTF-8" unless notes.valid_encoding?
        abort "sanitizer-incompatible string" unless notes.match?(/Alas’s/)
        print notes
      RUBY
      stdout, stderr, status = Open3.capture3("ruby", "-r", CHANGELOG_HELPER, "-e", program, path)

      assert status.success?, stderr
      assert_equal expected.b, stdout.b
    end
  end

  def test_fastlane_reader_rejects_invalid_utf8
    Dir.mktmpdir do |root|
      path = File.join(root, "notes.txt")
      File.binwrite(path, "\xFF")
      _stdout, stderr, status = Open3.capture3(
        "ruby", "-r", CHANGELOG_HELPER, "-e",
        "TestflightChangelog.read(changelog_file: ARGV.fetch(0))", path
      )

      refute status.success?
      assert_includes stderr, "TestFlight changelog is not valid UTF-8"
    end
  end

  def test_rejects_override_that_embeds_its_own_release_notes_link
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.2.md", <<~TEXT)
        Try the new transcript cards.

        Release notes: https://example.test/releases/tag/v0.24.1
      TEXT
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "must not include a Release notes link"
    end
  end

  def test_rejects_override_that_embeds_any_url
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.2.md", "Try the new transcript cards. See https://example.test/releases/tag/v0.24.1\n")
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "must not contain URLs"
    end
  end

  def test_uses_mobile_whats_new_body_when_no_override_exists
    Dir.mktmpdir do |root|
      entry = { version: "0.24.2", headline: { title: "Richer transcripts", body: "The iPhone beta now renders detailed tool calls." } }
      write(root, "Alas/Resources/WhatsNew/0.24.2.json", JSON.generate(entry))
      stdout, stderr, status = render(root)

      assert status.success?, stderr
      assert_equal "The iPhone beta now renders detailed tool calls.\n\nRelease notes: https://example.test/releases/tag/v0.24.2\n", stdout
    end
  end

  def test_rejects_whats_new_entry_for_a_different_version
    Dir.mktmpdir do |root|
      entry = { version: "0.24.1", headline: { title: "Richer transcripts", body: "The iPhone beta now renders detailed tool calls." } }
      write(root, "Alas/Resources/WhatsNew/0.24.2.json", JSON.generate(entry))
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "What's New version 0.24.1 does not match 0.24.2"
    end
  end

  def test_uses_up_to_three_mobile_changelog_items_without_pr_references
    Dir.mktmpdir do |root|
      entry = { version: "0.24.2", headline: { title: "Mac feature", body: "A faster Mac workspace." } }
      write(root, "Alas/Resources/WhatsNew/0.24.2.json", JSON.generate(entry))
      write(root, "CHANGELOG.md", <<~MARKDOWN)
        ## [0.24.2] - 2026-11-18

        ### Features
        - Improve iPhone transcript cards (#1).
        - Keep the Mac toolbar visible (#2).
        - Add iPad project grouping (#3, #4).
        - Render Mermaid on iOS (#5).
        - Add another mobile-only change (#6).

        ## [0.24.1] - 2026-11-17
      MARKDOWN
      stdout, stderr, status = render(root)

      assert status.success?, stderr
      assert_equal <<~TEXT, stdout
        Please test these iPhone and iPad changes:
        - Improve iPhone transcript cards
        - Add iPad project grouping
        - Render Mermaid on iOS

        Release notes: https://example.test/releases/tag/v0.24.2
      TEXT
    end
  end

  def test_release_tag_fails_without_version_specific_mobile_copy
    Dir.mktmpdir do |root|
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "no release-specific TestFlight copy for 0.24.2"
    end
  end

  def test_release_tag_never_reuses_an_older_versions_override
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.1.md", "Old beta notes.\n")
      stdout, stderr, status = render(root)

      refute status.success?
      refute_includes stdout, "Old beta notes"
      assert_includes stderr, "no release-specific TestFlight copy for 0.24.2"
    end
  end

  def test_uses_app_focused_fallback_for_non_release_builds
    Dir.mktmpdir do |root|
      stdout, stderr, status = render(root, version: "main", url: "https://example.test/tree/main")

      assert status.success?, stderr
      assert_equal <<~TEXT, stdout
        Please test the latest Alas beta on iPhone and iPad, especially pairing, session navigation, transcripts, and remote actions.

        Release notes: https://example.test/tree/main
      TEXT
    end
  end

  def test_rejects_unsafe_version_paths
    Dir.mktmpdir do |root|
      _stdout, stderr, status = render(root, version: "../secret")

      refute status.success?
      assert_includes stderr, "invalid version"
    end
  end

  def test_rejects_notes_above_testflight_byte_limit
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.2.md", "x" * 4_000)
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "exceed 4000 bytes"
    end
  end

  def test_rejects_multibyte_notes_above_testflight_byte_limit
    Dir.mktmpdir do |root|
      write(root, "Mobile/TestFlight/WhatToTest/0.24.2.md", "é" * 2_000)
      _stdout, stderr, status = render(root)

      refute status.success?
      assert_includes stderr, "exceed 4000 bytes"
    end
  end
end
