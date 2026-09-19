require "yaml"

workflow_path = File.expand_path("../../../.github/workflows/build.yml", __dir__)
workflow = YAML.safe_load(File.read(workflow_path), aliases: true)
jobs = workflow.fetch("jobs")

# Path filters: pushes and PRs that only touch documentation or agent config
# skip the workflow. Both events must agree, and everything CI actually
# builds, tests, or reads must still trigger a run.
triggers = workflow.fetch(true) # YAML parses the bare `on` key as a boolean.
push_paths = triggers.fetch("push").fetch("paths")
pr_paths = triggers.fetch("pull_request").fetch("paths")
raise "push and pull_request must use the same path filter" unless push_paths == pr_paths
raise "path filter must start by including everything" unless push_paths.first == "**"
raise "path filter must not combine paths with paths-ignore" if
  triggers.fetch("push").key?("paths-ignore") || triggers.fetch("pull_request").key?("paths-ignore")

# GitHub evaluates patterns in order; the last match decides.
triggers_run = lambda do |file|
  push_paths.reduce(false) do |matched, pattern|
    negated = pattern.start_with?("!")
    glob = negated ? pattern[1..] : pattern
    File.fnmatch(glob, file, File::FNM_DOTMATCH) ? !negated : matched
  end
end

[
  ".github/workflows/build.yml",
  "project.yml",
  "Alas/Resources/Info.plist",
  "AlasTests/GitServiceTests.swift",
  "AlasCLI/Cargo.lock",
  "ThirdParty/treesitter-pack/src/lib.rs",
  "scripts/ci_swift_tests.py",
  "scripts/tests/alas-build/run.sh",
  ".alas/scripts/build.sh",
  ".swiftformat",
  ".gitmodules"
].each do |file|
  raise "#{file} must trigger CI" unless triggers_run.call(file)
end

[
  "README.md",
  "CHANGELOG.md",
  "AGENTS.md",
  "docs/swift-ci.md",
  "docs/plans/2026-09-17-repo-local-config-design.md",
  "LICENSE",
  "art/alas-acp.png",
  "assets/scout-icon.svg",
  "renovate.json",
  ".agents/skills/lassie/SKILL.md",
  ".claude/skills/lassie/SKILL.md",
  ".alas/icon.png",
  ".github/workflows/release.yml",
  ".github/workflows/nightly.yml",
  ".github/workflows/update-cask.py"
].each do |file|
  raise "#{file} must not trigger CI" if triggers_run.call(file)
end

swift_job = jobs.fetch("build-test")
bounded_step_minutes = swift_job.fetch("steps").sum { |step| step.fetch("timeout-minutes", 0) }
# Reserve time for checkout, tools, caches, and other preparation steps.
raise "build-test timeout must cover its sequential steps plus 30 minutes of preparation" unless
  swift_job.fetch("timeout-minutes") >= bounded_step_minutes + 30

workers = jobs.fetch("swift-tests")
raise "workers must queue only after the builder finishes" unless workers["needs"] == "build-test"
raise "shard failures must not cancel sibling diagnostics" unless workers.dig("strategy", "fail-fast") == false
raise "two balanced test workers are required" unless workers.dig("strategy", "matrix", "shard") == [1, 2]
builder_steps = swift_job.fetch("steps")
publish = builder_steps.index { |step| step["name"] == "Upload compiled Swift test products" }
raise "builder must publish compiled products" unless publish
raise "builder must not execute test batches" if builder_steps.any? { |step| step.fetch("run", "").match?(/--lane|run-shard/) }
worker_steps = workers.fetch("steps")
raise "workers must not reserve runners waiting for products" if worker_steps.any? { |step| step.fetch("run", "").include?("wait-products") }
raise "workers must download this attempt's products" unless worker_steps.any? do |step|
  step.fetch("uses", "").start_with?("actions/download-artifact@") &&
    step.dig("with", "name") == "swift-test-products-${{ github.run_attempt }}"
end
raise "workers must execute both lanes assigned to their shard" unless worker_steps.any? do |step|
  step["run"] == "python3 scripts/ci_swift_tests.py run-shard --shard ${{ matrix.shard }}"
end
build_commands = jobs.values.flat_map { |job| job.fetch("steps", []) }.count do |step|
  step.fetch("run", "").lines.any? { |line| line.strip == "build-for-testing" }
end
raise "compile the application only once" unless build_commands == 1
restore = builder_steps.find { |step| step["id"] == "compilation-cache" }
save = builder_steps.find { |step| step["name"] == "Save compilation cache" }
build = builder_steps.find { |step| step["name"] == "Build for testing" }
raise "compilation cache must not restore DerivedData or test products" unless
  restore&.dig("with", "path") == ".build/xcode/CompilationCache.noindex"
raise "save and restore must use the same compilation cache" unless
  save&.dig("with", "path") == restore.dig("with", "path") &&
  save.dig("with", "key") == "${{ steps.compilation-cache.outputs.cache-primary-key }}"
key = restore.fetch("with").fetch("key")
prefixes = restore.fetch("with").fetch("restore-keys").lines.map(&:strip)
raise "cache fallback must retain all compatibility inputs" unless
  prefixes == [key.delete_suffix("${{ github.sha }}")] &&
  ["runner.os", "runner.arch", ".xcode-compilation-cache-toolchain", "project.yml",
   ".github/workflows/build.yml", "Package.resolved"].all? { |input| key.include?(input) }
raise "restore before building and save only a successful build" unless
  builder_steps.index(restore) < builder_steps.index(build) &&
  builder_steps.index(save) > builder_steps.index(build) &&
  save["if"] == "success() && steps.compilation-cache.outputs.cache-hit != 'true'"
raise "compiler must use the restored CAS and emit reuse evidence" unless
  build.fetch("run").include?('COMPILATION_CACHE_CAS_PATH="$GITHUB_WORKSPACE/.build/xcode/CompilationCache.noindex"') &&
  build.fetch("run").include?("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES")
raise "retain build evidence even after compiler failure" unless builder_steps.any? do |step|
  step["if"] == "always()" && step.dig("with", "path") == ".build/xcode/build-metrics"
end
audit = jobs.fetch("swift-coverage")
audit_download = audit.fetch("steps").find { |step| step.dig("with", "pattern") }
raise "coverage audit must download compact reports, not diagnostic bundles" unless
  audit_download&.dig("with", "pattern") == "swift-test-reports-${{ github.run_attempt }}-*"
[workers].each do |job|
  reports = job.fetch("steps").find { |step| step.dig("with", "name")&.start_with?("swift-test-reports-") }
  raise "each lane must publish reports even after failure" unless
    reports && reports["if"] == "always()" && reports.dig("with", "path") == ".build/xcode/results/*.report.json"
  raise "keep full result bundles for diagnosis" unless job.fetch("steps").any? do |step|
    step["if"] == "always()" && step.dig("with", "name")&.start_with?("swift-test-results-")
  end
end
raise "run timing inspection requires read-only Actions access" unless audit.dig("permissions", "actions") == "read"
raise "audit must run even if any Swift lane fails" unless audit["if"] == "always()" && audit["needs"].sort == ["build-test", "swift-tests"]
raise "audit must propagate infrastructure failures too" unless audit.fetch("steps").any? do |step|
  step["if"] == "always()" && step.dig("env", "SHARD_RESULT") == "${{ needs.swift-tests.result }}"
end

expected_runners = {
  "ci-workflow-contract" => "ubuntu-26.04",
  "rust-tests" => "ubuntu-26.04",
  "remote-web-tests" => "ubuntu-26.04"
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

raise "shell harnesses must share the build runner" if jobs.key?("shell-harness-tests")
shell_steps = builder_steps.map { |step| step["run"] }
[
  "bash scripts/tests/build-zmx/run.sh",
  "bash scripts/tests/build-fff/run.sh",
  "bash scripts/tests/build-treesitter-pack/run.sh",
  "bash scripts/tests/embed-ghostty-resources/run.sh",
  "bash scripts/tests/xcode-state/run.sh",
  "bash scripts/tests/alas-build/run.sh"
].each do |command|
  raise "builder must run #{command}" unless shell_steps.include?(command)
end

puts "ci workflow contract: ok"
