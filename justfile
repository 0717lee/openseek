default:
    just --list

# Check the two production targets together and verify repository formatting.
check:
    bash scripts/check_workspace_warnings.sh native
    bash scripts/check_workspace_warnings.sh js
    moon fmt --check

# Build every root workspace member for the production targets.
build:
    moon build --target native
    moon build --target js

# Run workspace MoonBit tests plus the offline OpenSeek CLI documentation tests.
test: test-moon
    moon cram test tests/cram

test-moon:
    moon test --target native
    moon test --target js

# Build the editor's web distribution and reference server in its scoped workspace.
editor-build:
    just --justfile editor/justfile build

# Run the editor's MoonBit tests on every target supported by its scoped workspace.
editor-test:
    just --justfile editor/justfile test

# Run the editor's required Playwright smoke and component suites.
editor-test-browser:
    just --justfile editor/justfile test-browser-smoke
