# Repository Guidelines for AI Agents

This repository contains ReaImGui integration test scripts and support modules
distributed through ReaPack as the single **Slava REAPER Test Suite**
metapackage.

## Critical Rules

### Branch and Git Workflow

Work only on `main`. If another branch is absolutely necessary, stop and ask
the owner before creating it.

Once `index.xml` references a commit, treat that commit as permanent. Do not
force-push or rewrite published history in a way that removes a commit-pinned
package source.

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

1. Change the provided files, then bump `@version` in
   `Slava-Testing/index.lua` and add an accurate `@changelog`.
2. Before committing, run `reapack-index --check --strict --warnings`.
3. Commit the source and documentation changes.
4. Run `reapack-index --scan --no-commit`.
5. If `README.md` changed, refresh repository About metadata with
   `reapack-index --about README.md --no-scan --no-commit`.
6. Inspect the generated `index.xml` semantically. For every prior version,
   confirm its version name, author, timestamp, changelog text, target
   filenames, platform and Main-action attributes, commit-pinned source URLs,
   and package About content are unchanged. XML indentation and other
   serialization formatting are not release invariants.
7. Confirm the Windows and macOS Lua source sets are identical, all binaries
   remain `win64`-only, and no source is unscoped or Linux-scoped.
8. Commit and push the generated `index.xml` separately.

Do not manually assemble, replace, or restore package or version blocks in
`index.xml` during a normal release. It is generated catalogue data. For a
diagnostic rebuild experiment only, write to a separate file with
`reapack-index --rebuild --output index.rebuilt.xml --no-commit`, compare it
semantically with the public index, and do not replace `index.xml` until the
owner has reviewed the result.

Use `reapack-index --about README.md --no-scan --no-commit` when refreshing the
repository About metadata. Pandoc must be available on `PATH` for the Markdown
to RTF conversion.

Never use `--amend` during a routine new-version release. It may be used only
after an explicit owner decision to repair metadata belonging to an already
published version; document the reason and verify the amended version
semantically.

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
