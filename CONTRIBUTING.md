# Contributing

## Scope

This repository contains a C99-based 6502 SBC emulator, helper ROM generators, and documentation.

## Development Workflow

1. Fork the repository or create a feature branch.
2. Keep changes focused and small.
3. Rebuild locally with `make clean && make`.
4. Test the changed behavior manually.
5. Update documentation if user-facing behavior changes.

## Coding Guidelines

- Use C99.
- Prefer small, local changes over broad refactors.
- Preserve cycle-accuracy and existing device behavior unless the change explicitly targets them.
- Keep public behavior and CLI options backward compatible when possible.
- Avoid introducing external dependencies unless necessary.

## Pull Requests

Please include:

- A short problem statement
- The change made
- How it was tested
- Any emulator behavior or compatibility impact

## Documentation Policy

When behavior, memory maps, or workflows change, keep documentation in the same PR in sync.

Checklist:

- Update [README.md](README.md) for user-visible changes.
- Update affected docs in [docs](docs) (for example architecture, device, or workflow pages).
- Remove or rewrite obsolete sections instead of leaving conflicting guidance.
- Keep addresses, register maps, and command examples aligned with current code/config.
- Add a short note in [CHANGELOG.md](CHANGELOG.md) under Unreleased for notable user-facing updates.

## Reporting Bugs

When reporting an issue, include:

- Host OS
- Build command
- ROM used
- `sbc.ini` or relevant config changes
- Steps to reproduce
- Expected behavior
- Actual behavior
