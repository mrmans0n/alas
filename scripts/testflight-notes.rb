#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

options = { root: File.expand_path("..", __dir__) }
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--version VERSION") { |value| options[:version] = value }
  parser.on("--release-url URL") { |value| options[:release_url] = value }
end.parse!

version = options.fetch(:version)
release_url = options.fetch(:release_url)
abort "invalid version: #{version}" unless version.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)

root = Pathname(options.fetch(:root))
override = root / "Mobile/TestFlight/WhatToTest/#{version}.md"
whats_new = root / "Alas/Resources/WhatsNew/#{version}.json"
changelog = root / "CHANGELOG.md"
mobile_pattern = /\b(?:iPhone|iPad|iOS|mobile)\b/i

copy = if override.file?
         text = override.read.strip
         abort "TestFlight override must not include a Release notes link" if text.match?(/^Release notes:/i)
         abort "TestFlight override must not contain URLs" if text.match?(%r{\bhttps?://}i)
         text
       elsif whats_new.file?
         entry = JSON.parse(whats_new.read)
         entry_version = entry["version"]
         unless entry_version == version
           abort "What's New version #{entry_version || "(missing)"} does not match #{version}"
         end
         body = entry.dig("headline", "body").to_s.strip
         body if body.match?(mobile_pattern)
       end

if copy.to_s.empty? && changelog.file?
  lines = changelog.readlines
  marker = "## [#{version}]"
  start = lines.index { |line| line.start_with?(marker) }
  if start
    finish = ((start + 1)...lines.length).find { |index| lines[index].start_with?("## [") } || lines.length
    items = lines[(start + 1)...finish]
      .map { |line| line.start_with?("- ") ? line.delete_prefix("- ").strip : nil }
      .compact
      .select { |line| line.match?(mobile_pattern) }
      .first(3)
      .map { |line| line.sub(/\s*\((?:#\d+(?:,\s*#\d+)*)\)\.?\z/, "") }
    copy = "Please test these iPhone and iPad changes:\n#{items.map { |item| "- #{item}" }.join("\n")}" if items.any?
  end
end

if copy.to_s.empty?
  canonical_tag_suffix = "/releases/tag/v#{version}"
  abort "no release-specific TestFlight copy for #{version}" if release_url.end_with?(canonical_tag_suffix)
  copy = "Please test the latest Alas beta on iPhone and iPad, especially pairing, session navigation, transcripts, and remote actions."
end
notes = "#{copy}\n\nRelease notes: #{release_url}\n"
abort "TestFlight notes exceed 4000 bytes" if notes.bytesize > 4_000

print notes
