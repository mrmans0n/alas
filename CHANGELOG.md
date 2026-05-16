# Changelog

All notable changes to alas are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### ✨ Features

- --target with --write promotes [Unreleased] to versioned section.
- --write splices generated notes into [Unreleased].
- render grouped release notes from conventional commits.
- add draft-release-notes.sh skeleton with flag parsing.

### 🐛 Fixes

- preserve curated changelog notes during release promotion.
- detect and run commit-AI CLIs installed outside GUI app PATH (#123).
- rename isDimmed to isHistorical and use warn color for dot (#121).

### 📚 Docs

- add RELEASING.md covering the changelog + tag flow.
- seed CHANGELOG.md with [Unreleased] and [0.1.1] section.
- rewrite README in landing-page style with brew install.

## [0.1.1] - 2026-05-15

### 🏗️ Internal
- Detect new Alas cask file in release workflow.
