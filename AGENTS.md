# Repository Guidelines for AI Agents

This repository contains ReaImGui integration test scripts and support modules
distributed through ReaPack as the single **Slava REAPER Test Suite**
metapackage.

## Critical Rules

### Branch and Git Workflow

Work only on `main`. If another branch is absolutely necessary, stop and ask
the owner before creating it.

### ReaPack Architecture and Platform Scoping

- Keep exactly one indexed package: `Slava-Testing/index.lua`.
- Do not split or replace the metapackage architecture.
- Entrypoint scripts are `Slava-Testing/test_*.lua`; each uses `-- @noindex`
  because the metapackage owns it.
- Shared modules are `Slava-Testing/modules/*.lua`; each uses `-- @noindex`.
- Declare every action and module separately for `[win64]` and `[darwin]`.
- Declare `curl.exe`, `7z.exe`, and `7z.dll` only for `[win64]`.
- Windows x64 uses the bundled executables under `Slava-Testing/bin/win/`.
- macOS uses `/usr/bin/curl` and system `unzip`; do not provide Windows
  executables to macOS.
- Do not add unscoped or Linux sources. Linux must receive no installable
  actions, modules, binaries, or support files.

### Normal ReaPack Release Sequence

1. Change the provided files.
2. Bump `@version` in `Slava-Testing/index.lua`.
3. Add an accurate `@changelog`.
4. Commit the source changes.
5. Run `reapack-index --check --strict --warnings`.
6. Run `reapack-index --scan --no-commit`.
7. Verify that `index.xml` contains a new version and preserves every previous
   version unchanged.
8. Commit and push `index.xml`.

Use `reapack-index --about README.md --no-scan --no-commit` when refreshing the
repository About metadata. Pandoc must be available on `PATH` for the Markdown
to RTF conversion.

`--amend` is forbidden for routine releases. It may be used only after an
explicit owner decision to alter an already indexed version.

### Binary Licensing and Provenance

- Preserve `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the files under
  `Slava-Testing/licenses/`.
- Deliver applicable notices with binaries through the metapackage.
- Whenever a binary changes, update its exact product/version, architecture,
  upstream URL, archive filename, SHA-256, acquisition date, applicable
  license, and reported bundled dependencies.
- Re-verify that the committed binary bytes match the documented upstream
  artifact. Never guess missing provenance.
- Preserve 7-Zip's LGPL/BSD/unRAR notices and source-code link, curl's COPYING
  terms, and every notice required by curl's reported bundled libraries.

## Codebase

### Entrypoint Scripts

- `test_Curl_Jobs.lua` tests `modules.Curl` and `modules.Jobs`.
- `test_Files.lua` tests filesystem and sandbox operations.
- `test_docx.lua` tests DOCX extraction, XML parsing, and dialogue extraction.
- `test_neurocast_auth.lua` tests `modules.neurocast_auth`.

### Shared Modules

Key modules include `Curl.lua`, `Jobs.lua`, `Files.lua`, `Util.lua`, `json.lua`,
`Cleanup.lua`, `Parse.lua`, `Utf8Tools.lua`, `Utf8SimpleLowerData.lua`,
`base64_encode_decode.lua`, `zip_archive.lua`, `docx_xml_extractor.lua`,
`docx_xml_parser.lua`, `docx_dialogue_parser.lua`, and `neurocast_auth.lua`.

## Maintenance Standards

1. Use current ReaImGui API conventions, including an explicit size when
   calling `reaper.ImGui_PushFont` or its shim equivalent.
2. Use `modules.Util` logging helpers for diagnostics instead of unformatted
   `print` calls.
3. Scope test file operations to REAPER's resource path, such as
   `Data/Files_Module_Test/tmp`, to avoid touching user project data.
4. Run Lua syntax checks, strict ReaPack validation, platform-source assertions,
   and the documented clean-install/uninstall smoke tests before declaring a
   release production-ready.
