# Contributing Guidelines

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Contributing Guidelines](#contributing-guidelines)
  - [Finding Things That Need Help](#finding-things-that-need-help)
  - [Contributing a Patch](#contributing-a-patch)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

Read the following guide if you're interested in contributing to cluster stack framework.


## Contributing a Patch

1. If working on an issue, signal other contributors that you are actively working on it using `/lifecycle active`.
2. Fork the desired repo, develop and test your code changes.
   1. See the [Development Guide](docs/developers/development.md) for more instructions on setting up your environment and testing changes locally.
3. Submit a pull request.
   1. All PRs should be labeled with one of the following kinds
      - `/kind feature` for PRs releated to adding new features/tests
      - `/kind bug` for PRs releated to bug fixes and patches
      - `/kind api-change` for PRs releated to adding, removing, or otherwise changing an API
      - `/kind cleanup` for PRs releated to code refactoring and cleanup
      - `/kind deprecation` for PRs related to a feature/enhancement marked for deprecation.
      - `/kind design` for PRs releated to design proposals
      - `/kind documentation` for PRs releated to documentation
      - `/kind failing-test` for PRs releated to to a consistently or frequently failing test.
      - `/kind flake` for PRs related to a flaky test.
      - `/kind other` for PRs releated to updating dependencies, minor changes or other
   2. All code PR must be have a title starting with one of
      - ⚠️ (`:warning:`, major or breaking changes)
      - ✨ (`:sparkles:`, feature additions)
      - 🐛 (`:bug:`, patch and bugfixes)
      - 📖 (`:book:`, documentation or proposals)
      - 🌱 (`:seedling:`, minor or other)
   3. If the PR requires additional action from users switching to a new release, include the string "action required" in the PR release-notes.
   4. All code changes must be covered by unit tests and E2E tests.
   5. All new features should come with user documentation.
4. Once the PR has been reviewed and is ready to be merged, commits should be [squashed](https://github.com/kubernetes/community/blob/master/contributors/guide/github-workflow.md#squash-commits).
   1. Ensure that commit message(s) are be meaningful and commit history is readable.

All changes must be code reviewed. Coding conventions and standards are explained in the official [developer docs](https://github.com/kubernetes/community/tree/master/contributors/devel). Expect reviewers to request that you avoid common [go style mistakes](https://github.com/golang/go/wiki/CodeReviewComments) in your PRs.

In case you want to run our E2E tests locally, please refer to [Testing](docs/developers/development.md#submitting-prs-and-testing) guide.
