# Slava REAPER Test Suite

Interactive test scripts for REAPER, built with ReaImGui and distributed as one
ReaPack metapackage.

## Included Tests

- **test_Curl_Jobs** — async HTTP operations and background task scheduling.
- **test_Files** — filesystem utilities, path manipulation, and sandbox I/O.
- **test_docx** — DOCX archive extraction, XML parsing, and dialogue extraction.
- **test_neurocast_auth** — authentication-flow testing against Neurocast endpoints.

## Requirements

- REAPER 7.0+
- ReaImGui (install via ReaPack)

## Platform Support

- **Windows x64** — scripts and modules, plus bundled curl 8.13.0 and 7-Zip 26.00
- **macOS** — scripts and modules; uses `/usr/bin/curl` and system `unzip`
- **Linux** — intentionally unsupported; the index exposes no installable sources

## Installation

- Add this repository URL to ReaPack: <https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/raw/main/index.xml>
- Install **Slava REAPER Test Suite** from the package browser.
- Find the four test scripts in REAPER's Actions list under `Slava-Testing`.

## License and Notices

Slava Logutin's Lua code is licensed under the
[MIT License](https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/blob/main/LICENSE).
Bundled binaries, generated Unicode data, and the third-party JSON module retain
their own terms. See the complete
[third-party notices and binary provenance](https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/blob/main/THIRD_PARTY_NOTICES.md).

The applicable license and notice files are installed in the package's
`licenses` subdirectory.

## Maintainer Release Workflow

This repository intentionally has no GitHub Actions yet. Releases are checked
locally with the toolchain available on the maintainer's machine.

1. Change package files and update the metapackage `@version` and
   `@changelog`.
2. Run `reapack-index --check --strict --warnings` before committing.
3. Commit source and documentation changes, then run
   `reapack-index --scan --no-commit`.
4. When this README changes, refresh the repository About with
   `reapack-index --about README.md --no-scan --no-commit`.
5. Inspect the generated index semantically: historical version metadata,
   changelog text, provided targets, platform/Main attributes, commit-pinned
   source URLs, and package About must be retained. Whitespace-only XML
   serialization changes are not failures.
6. Commit and push the generated `index.xml` separately.

Do not manually replace package or version blocks in `index.xml`. Never use
`--amend` for an ordinary new release. An amendment to an indexed version
requires an explicit owner decision and a documented semantic verification.
Do not force-push or rewrite history after `index.xml` has referenced a commit.

Before declaring a release complete, perform the documented ReaPack client
smoke tests: update an installed prior version, clean-install the release,
uninstall it, and confirm an unrelated sentinel file is unchanged.
