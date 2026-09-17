require "yaml"

workflow_path = File.expand_path("../../../.github/workflows/build.yml", __dir__)
workflow = YAML.safe_load_file(workflow_path, aliases: true)
jobs = workflow.fetch("jobs")

swift_build = jobs.fetch("swift-build")
bounded_step_minutes = swift_build.fetch("steps").sum { |step| step.fetch("timeout-minutes", 0) }
# Reserve time for checkout, tools, caches, packaging, and artifact upload.
raise "swift-build timeout must cover its bounded steps plus 30 minutes of preparation" unless
  swift_build.fetch("timeout-minutes") >= bounded_step_minutes + 30

swift_tests = jobs.fetch("swift-tests")
raise "Swift shards must wait for the single build" unless swift_tests.fetch("needs") == "swift-build"
raise "Swift shard failures must not cancel diagnostic collection" unless
  swift_tests.dig("strategy", "fail-fast") == false
raise "Swift CI must use exactly two measured shards" unless
  swift_tests.dig("strategy", "matrix", "shard") == [0, 1]

test_steps = swift_tests.fetch("steps")
raise "Swift shards must download the compiled test products" unless
  test_steps.any? { |step| step["uses"]&.start_with?("actions/download-artifact@") && step.dig("with", "name") == "swift-test-products" }
raise "Swift shards must execute their assigned plan" unless
  test_steps.any? { |step| step.fetch("run", "").include?("ci_swift_tests.py run-shard --shard ${{ matrix.shard }}") }
results_upload = test_steps.find { |step| step["uses"]&.start_with?("actions/upload-artifact@") }
raise "Each Swift shard must preserve diagnostics after failure" unless results_upload&.fetch("if", "") == "always()"

swift_coverage = jobs.fetch("swift-coverage")
raise "Coverage reconciliation must wait for build and every shard" unless
  swift_coverage.fetch("needs") == ["swift-build", "swift-tests"]
raise "Coverage reconciliation must run after shard failures" unless swift_coverage.fetch("if") == "always()"
coverage_steps = swift_coverage.fetch("steps")
raise "Coverage reconciliation must merge every shard artifact" unless
  coverage_steps.any? { |step| step["uses"]&.start_with?("actions/download-artifact@") && step.dig("with", "pattern") == "swift-test-results-*" && step.dig("with", "merge-multiple") == true }
raise "Coverage reconciliation must audit the complete plan" unless
  coverage_steps.any? { |step| step.fetch("run", "").include?("ci_swift_tests.py summary") }

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
