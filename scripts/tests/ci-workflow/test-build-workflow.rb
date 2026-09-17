require "yaml"

workflow_path = File.expand_path("../../../.github/workflows/build.yml", __dir__)
workflow = YAML.safe_load_file(workflow_path, aliases: true)
jobs = workflow.fetch("jobs")

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
  "bash scripts/tests/xcode-state/run.sh"
].each do |command|
  raise "shell-harness-tests must run #{command}" unless shell_steps.include?(command)
end

puts "ci workflow contract: ok"
