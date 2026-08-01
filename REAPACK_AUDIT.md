# ReaPack Production-Readiness Audit

## Package Structure

- Exactly one indexed package: `Slava-Testing/index.lua`.
- The package remains a single metapackage; the architecture was not split or
  replaced.
- Published version `1.0.0` contains exactly 41 sources: 8 action sources,
  30 module sources, and 3 Windows binary sources.
- Version `1.0.1` contains 50 sources: the same 8 action, 30 module, and 3
  Windows binary sources, plus 9 platform-scoped license/notice sources.
  This is reported separately from the historical `1.0.0` count.
- Windows x64 receives actions, modules, binaries, and notices. macOS receives
  actions, modules, and applicable notices. Linux receives no sources.

## Automated Checks

The release is accepted only when all of these checks pass:

- Every Lua source parses with Lua 5.4.
- `reapack-index --check --strict --warnings` reports zero failures.
- `reapack-index --scan --no-commit` creates `1.0.1` while the serialized
  `1.0.0` version remains byte-for-byte unchanged.
- `index.xml` contains repository About text generated from `README.md` using
  Pandoc through `reapack-index --about README.md --no-scan --no-commit`.
- All indexed URLs resolve, binary hashes match `THIRD_PARTY_NOTICES.md`, and
  every installed target remains inside the package-owned `Slava-Testing`
  directory.

## Live Smoke-Test Status

Automated and static checks do not replace REAPER installation testing.

- **Windows x64:** pending owner test against the public `1.0.1` index. Install
  the package in a clean or portable REAPER, run all four actions, confirm the
  installed `bin/win/curl.exe`, `bin/win/7z.exe`, and `bin/win/7z.dll` paths,
  then uninstall and verify unrelated files remain.
- **macOS:** not executed for this release cycle. The static index/platform and
  path-selection checks are required, but production readiness remains explicit
  about the missing live macOS run.
- **Linux:** verify from `index.xml` that the package has no Linux/all-platform
  sources and is therefore not installable.

The repository must not be described as fully live-smoke-tested until the
pending platform results are recorded here.

## Open Binary-Maintenance Findings

- curl upstream currently lists 36 published security problems affecting curl
  8.13.0: <https://curl.se/docs/vuln-8.13.0.html>. Several entries require
  features disabled in Microsoft's Windows build, but HTTP authentication,
  cookie, redirect, proxy, and connection-reuse findings require a use-case
  review. Updating the pinned executable needs live regression testing because
  the test suite intentionally verifies this build's behavior.
- 7-Zip 26.02 is newer than the bundled 26.00, and upstream states that 26.02
  fixes bugs and vulnerabilities: <https://www.7-zip.org/sdk.html>. Before a
  production-ready declaration, assess and preferably update the bundled pair,
  then repeat DOCX extraction and clean install/uninstall tests.

Version `1.0.1` resolves the identified ReaPack licensing, provenance,
platform-scoping, About, and release-history defects. Production readiness is
still withheld pending the live smoke tests and the binary-maintenance decision
above.
