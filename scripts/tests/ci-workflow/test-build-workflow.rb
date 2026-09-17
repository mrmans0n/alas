require "yaml"

workflow_path = File.expand_path("../../../.github/workflows/build.yml", __dir__)
workflow = YAML.safe_load_file(workflow_path, aliases: true)
jobs = workflow.fetch("jobs")

swift_job = jobs.fetch("build-test")
bounded_step_minutes = swift_job.fetch("steps").sum { |step| step.fetch("timeout-minutes", 0) }
# Reserve time for checkout, tools, caches, and other preparation steps.
raise "build-test timeout must cover its sequential steps plus 30 minutes of preparation" unless
  swift_job.fetch("timeout-minutes") >= bounded_step_minutes + 30

workers = jobs.fetch("swift-tests")
raise "workers must queue alongside the builder" if workers.key?("needs")
raise "shard failures must not cancel sibling diagnostics" unless workers.dig("strategy", "fail-fast") == false
raise "two subprocess workers are required" unless workers.dig("strategy", "matrix", "shard") == [1, 2]
raise "artifact wait requires read-only Actions access" unless workers.dig("permissions", "actions") == "read"
builder_steps = swift_job.fetch("steps")
publish = builder_steps.index { |step| step["name"] == "Upload compiled Swift test products" }
ordinary = builder_steps.index { |step| step.fetch("run", "").include?("--lane ordinary") }
raise "publish products before running ordinary tests" unless publish && ordinary && publish < ordinary
raise "builder must not execute subprocess work" if builder_steps.any? { |step| step.fetch("run", "").include?("--lane subprocess") }
build_commands = jobs.values.flat_map { |job| job.fetch("steps", []) }.count do |step|
  step.fetch("run", "").lines.any? { |line| line.strip == "build-for-testing" }
end
raise "compile the application only once" unless build_commands == 1
audit = jobs.fetch("swift-coverage")
raise "audit must run even if any Swift lane fails" unless audit["if"] == "always()" && audit["needs"].sort == ["build-test", "swift-tests"]
raise "audit must propagate infrastructure failures too" unless audit.fetch("steps").any? do |step|
  step["if"] == "always()" && step.dig("env", "SHARD_RESULT") == "${{ needs.swift-tests.result }}"
end

expected_runners = {
  "ci-workflow-contract" => "ubuntu-24.04",
  "rust-tests" => "ubuntu-24.04",
  "remote-web-tests" => "ubuntu-24.04",
  "shell-harness-tests" => "macos-26"
}

expected_runners.each do |name, runner|
  job = jobs.fetch(name) { raise "missing #{name} job" }
  raise "#{name} must run on #{runner}" unless job["runs-on"] == runner
end

rust_job = jobs.fetch("rust-tests")
matrix = rust_job.dig("strategy", "matrix")
projects = matrix.fetch("include").map { |entry| [entry.fetch("project"), entry.fetch("toolchain")] }
raise "rust-tests must cover every first-party Rust project with its declared toolchain" unless projects == [
  ["AlasCLI", "1.98.1"],
  ["AlasHelper", "1.98.1"],
  ["ThirdParty/treesitter-pack", "1.97.1"]
]

rust_command = rust_job.fetch("steps").find { |step| step["name"] == "Run locked Rust tests" }
raise "rust-tests must run cargo test --locked" unless rust_command&.fetch("run", "")&.include?("rustup run ${{ matrix.toolchain }} cargo test --locked")

remote_steps = jobs.fetch("remote-web-tests").fetch("steps").map { |step| step["run"] }
[
  "bash scripts/tests/remote-web-changes/run.sh",
  "bash scripts/tests/remote-web-file-browser/run.sh",
  "bash scripts/tests/remote-web-session-ordering/run.sh",
  "bash scripts/tests/remote-web-worktree-creation/run.sh"
].each do |command|
  raise "remote-web-tests must run #{command}" unless remote_steps.include?(command)
end

shell_steps = jobs.fetch("shell-harness-tests").fetch("steps").map { |step| step["run"] }
[
  "bash scripts/tests/build-zmx/run.sh",
  "bash scripts/tests/build-fff/run.sh",
  "bash scripts/tests/build-treesitter-pack/run.sh",
  "bash scripts/tests/embed-ghostty-resources/run.sh",
  "bash scripts/tests/xcode-state/run.sh",
  "bash scripts/tests/alas-build/run.sh"
].each do |command|
  raise "shell-harness-tests must run #{command}" unless shell_steps.include?(command)
end

puts "ci workflow contract: ok"
