# RTK artifact verification

Firstmate v1 does not run RTK or expose compact project commands. The tracked integration is limited to an operator-invoked, non-executing inspection of one reviewed private artifact.
[`bin/fm-rtk.sh`](../bin/fm-rtk.sh) and its `--help` output own the executable verification contract.

## Operator procedure

On Darwin arm64, place an independently obtained artifact at `$FM_HOME/data/tools/rtk/v0.45.0/aarch64-apple-darwin/rtk` only after separate operator authorization. Firstmate does not download, install, copy, stage, activate, discover, or update it.
Run `FM_HOME=/absolute/home /absolute/firstmate/bin/fm-rtk.sh verify` to inspect it.
Success means the opened artifact identity is a regular non-symlink executable with SHA-256 `17d00d61a533a442c61f1be49d8a9321225557f64021d5b70fd8eb75ed8fb0be`.
That checksum binds the reviewed `rtk 0.45.0` macOS arm64 artifact without executing `--version` or any other artifact entrypoint.

The verifier walks the absolute home from an opened filesystem root and opens every home and artifact component relative to its already-opened parent with no-follow semantics. It hashes that opened file identity. It does not reopen the artifact by pathname, honor caller temporary directories, create temporary files, inspect a project, or execute any project command.

## Runtime boundary

There is no `config/rtk` activation, `fm-brief.sh --rtk-compact` option, task instruction, semantic project-command verb, raw fallback, temporary RTK environment, runtime adapter, shell startup edit, `PATH` change, prompt, hook, plugin, filter, bootstrap action, session-start action, or secondmate inheritance.
Arguments other than the exact `verify` operation are refused. Ambient shell startup, Perl startup, `PATH`, platform-test, hash-test, and temporary-directory overrides cannot weaken the public launcher.

Verification never makes RTK available to a worker and is not authorization to execute it. Operators must use ordinary raw tools for all orientation, safety, mutation, validation, review, cleanliness, landing, and approval evidence.

## Updates and rollback

A new pin requires a tracked review of the stable upstream tag and commit, release workflow, dependencies, license, provenance, telemetry and persistence behavior, rewrite behavior, and relevant correctness or privacy issues. The reviewed platform artifact's checksum must be changed in tracked code with behavioral coverage. Development branches, mutable latest selectors, installers, unpinned builds, and the unrelated crates.io `rtk` package are ineligible.

Rollback is deletion of the private artifact or removal of this tracked verifier. No runtime repair, hook uninstall, prompt repair, shell edit, or project cleanup is needed because v1 activates nothing and writes nothing.

## Ownership and evaluation

This document is the maintainer architecture record. `docs/scripts.md` inventories the operator entrypoint, and `tests/fm-rtk.test.sh` owns executable boundary coverage. The pilot can graduate only after a separately approved architecture can bind verified artifact identity through execution while preserving project, privacy, and evidence boundaries. Until then there is no runtime pilot to evaluate and no compact output to treat as evidence.
