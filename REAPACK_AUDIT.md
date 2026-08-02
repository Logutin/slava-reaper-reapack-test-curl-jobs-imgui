# ReaPack v1.0.2 Workflow Audit

## Tooling and Authorization

- Ruby: `4.0.6`; `reapack-index`: `1.2.6`; Pandoc: `3.10`.
- Do not install, update, or remove Ruby or `reapack-index` without the
  owner's explicit approval. Check availability and version first; a missing
  tool blocks the corresponding indexing step.

## Source Release

- `3d1168743456d2be2a12ca27f5e5bf8907bb5f15` prepares v1.0.2 with a harmless
  `test_Files.lua` status-message update and README improvements.
- `13c3daf5cc8a072ce7b7a519f259d380d2e3b285` corrects package About metadata.
- `29b631b9bea72b8db4fb11af628ef4638ebe67cd` adds the complete multiline
  package About using the indexer's required header syntax.
- `a6805914b9ce1aa8331518601df111de6d3fca09` adds the package About's
  requirements, repository link, and license/notices link.
- No commit was amended.

## Exact Commands and Results

```powershell
reapack-index --check --strict --warnings
```

Result after the final source commit: `Finished checks for 20 packages with 0
failures`.

```powershell
reapack-index --scan --no-commit
```

Result: `1 modified package, 1 new version`.

```powershell
reapack-index --about README.md --no-scan --no-commit
```

Result: `1 modified metadata`.

The v1.0.2 index initially changed historical changelog text because a
PowerShell text pipeline transformed generated XML. That process is not a
release repair procedure and must not be repeated. The final check restored
the intended historical content. Future releases compare historical versions
semantically rather than requiring byte-identical XML serialization.

## Generated Index Inspection

- Exactly one `<reapack>` package: `Slava-Testing/index.lua`.
- Versions present: `1.0.0`, `1.0.1`, and `1.0.2`.
- v1.0.0 and v1.0.1 retain their version metadata, changelog text, provided
  targets, platform/Main-action attributes, package documentation, and
  commit-pinned historical source URLs. XML formatting itself is not an
  invariant.
- v1.0.2 has 50 sources: 8 Main action sources and 42 non-action sources.
  All sources are explicitly scoped to `win64` or `darwin`; there are no Linux
  or unscoped sources.
- The four and only Main action files are `test_Curl_Jobs.lua`,
  `test_Files.lua`, `test_docx.lua`, and `test_neurocast_auth.lua`.
  Modules, binaries, and notices have no `main` attribute.
- Package About and repository About are both populated as RTF generated from
  readable Markdown. The package About includes the suite title, platform
  notes, REAPER 7.0+ and ReaImGui requirements, repository link, and
  license/notices link; repository About is generated from `README.md`.

## ReaPack Client Smoke Tests

The command runner has no GUI automation channel for REAPER's ReaPack client.
The following live Windows checks require execution in a clean or portable
REAPER instance and remain explicitly unverified here:

- install v1.0.1, synchronize, and update to v1.0.2 through ReaPack;
- clean-install v1.0.2, then uninstall it and confirm an unrelated sentinel
  file remains unchanged.

Static source and index checks above confirm the required update source set and
package-owned installation paths, but do not substitute for those client-side
operations.

## Maintenance Policy

- Do not manually replace package or version XML blocks during normal releases.
- Never use `--amend` for a normal new-version release. An amendment to an
  indexed version requires explicit owner approval, a documented reason, and
  semantic verification of the corrected metadata.
- Do not force-push or rewrite a commit once `index.xml` references it.
- A rebuild is diagnostic only: run
  `reapack-index --rebuild --output index.rebuilt.xml --no-commit`, compare it
  semantically with the public index, and obtain owner review before replacing
  the public index.
- GitHub Actions are intentionally not configured yet; run the local strict
  check and semantic inspection for every release.
