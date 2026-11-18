# frozen_string_literal: true

module TestflightChangelog
  def self.read(options)
    path = options.fetch(:changelog_file)
    notes = File.binread(path).force_encoding(Encoding::UTF_8)
    raise ArgumentError, "TestFlight changelog is not valid UTF-8" unless notes.valid_encoding?

    notes
  end
end
