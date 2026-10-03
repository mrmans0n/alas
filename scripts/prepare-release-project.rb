#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

path = ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} <project.yml>" }
text = File.read(path)
lines = text.lines

targets_indexes = lines.each_index.select { |index| lines[index] == "targets:\n" }
abort "expected exactly one targets block, found #{targets_indexes.length}" unless targets_indexes.length == 1

targets_start = targets_indexes.fetch(0)
targets_end = ((targets_start + 1)...lines.length).find { |index| lines[index].match?(/^\S/) } || lines.length
target_starts = ((targets_start + 1)...targets_end).select { |index| lines[index] == "  Alas:\n" }
abort "expected exactly one Alas target, found #{target_starts.length}" unless target_starts.length == 1

target_start = target_starts.fetch(0)
target_end = ((target_start + 1)...targets_end).find { |index| lines[index].match?(/^  \S/) } || targets_end
settings_indexes = ((target_start + 1)...target_end).select { |index| lines[index] == "    settings:\n" }
abort "expected exactly one settings block in the Alas target, found #{settings_indexes.length}" unless settings_indexes.length == 1

settings_index = settings_indexes.fetch(0)
base_indexes = ((settings_index + 1)...target_end).select { |index| lines[index] == "      base:\n" }
abort "expected exactly one base settings block in the Alas target, found #{base_indexes.length}" unless base_indexes.length == 1

base_index = base_indexes.fetch(0)
base_end = ((base_index + 1)...target_end).find do |index|
  line = lines[index]
  !line.strip.empty? && line[/\A */].length < 8
end || target_end

architecture_keys = /\A        (?:ARCHS|ALAS_APP_ARCHS):/
base_lines = lines[(base_index + 1)...base_end].reject { |line| line.match?(architecture_keys) }
base_lines.unshift(
  "        ARCHS: $(ALAS_APP_ARCHS)\n",
  "        ALAS_APP_ARCHS: $(ARCHS_STANDARD)\n"
)
updated_lines = lines[0..base_index] + base_lines + lines[base_end..]
updated = updated_lines.join

project = YAML.safe_load(updated, aliases: true)
alas_settings = project.fetch("targets").fetch("Alas").fetch("settings").fetch("base")
abort "failed to set ARCHS to $(ALAS_APP_ARCHS)" unless alas_settings["ARCHS"] == "$(ALAS_APP_ARCHS)"
abort "failed to default ALAS_APP_ARCHS to $(ARCHS_STANDARD)" unless
  alas_settings["ALAS_APP_ARCHS"] == "$(ARCHS_STANDARD)"

unless updated == text
  mode = File.stat(path).mode
  temporary = "#{path}.tmp.#{Process.pid}"
  begin
    File.write(temporary, updated)
    File.chmod(mode, temporary)
    File.rename(temporary, path)
  ensure
    File.delete(temporary) if File.exist?(temporary)
  end
end
