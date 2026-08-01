# Repository Guidelines for AI Agents

This repository (slava-reaper-reapack-test-curl-jobs-imgui) contains a set of ReaImGui interactive test scripts and support modules designed for testing REAPER integration features, formatted for distribution via ReaPack.

---

## Critical Rules & Guidelines

### 1. Branching & Git Workflow
> [!IMPORTANT]
> **Work only on the main branch.**
> If it is absolutely necessary to create another branch, **stop and ask the user** before doing so.

### 2. ReaPack Metadata & File Structure
- **Category Folder (/Slava-Testing/)**: Package scripts, support modules, and binary executables reside under the `Slava-Testing/` category folder.
- **Suite Metapackage (/Slava-Testing/index.lua)**: Package distribution is managed by a single `@metapackage` manifest (`Slava-Testing/index.lua`) that defines all main entry points, shared modules, and platform-restricted binaries (`[win64]`).
- **Entrypoint Test Scripts (/Slava-Testing/test_*.lua)**: Individual test scripts inside `Slava-Testing/` use `-- @noindex` since ownership is governed by the suite manifest.
- **Support Modules (/Slava-Testing/modules/*.lua)**: All shared Lua modules reside in `Slava-Testing/modules/` and include `-- @noindex` at the top of the file.

---

## Codebase Architecture

### Category Package Manifest
- index.lua — ReaPack suite metapackage defining all installed actions, modules, and binaries.

### Entrypoint Test Scripts (/Slava-Testing/test_*.lua)
- test_Curl_Jobs.lua — ReaImGui tester for asynchronous HTTP operations (modules.Curl) and background execution queues (modules.Jobs).
- test_Files.lua — ReaImGui tester for filesystem utilities (modules.Files), path manipulation, and sandbox file operations.
- test_docx.lua — ReaImGui tester for DOCX archive extraction (modules.docx_xml_extractor), XML parsing (modules.docx_xml_parser), and dialogue extraction (modules.docx_dialogue_parser).
- test_neurocast_auth.lua — ReaImGui tester for authentication flow testing against Neurocast endpoints (modules.neurocast_auth).

### Module Dependencies (/modules)
- Curl.lua — Network transport layer built on top of curl.
- Jobs.lua — Asynchronous background task scheduler and progress monitor.
- Files.lua — Safe cross-platform filesystem helper functions.
- Util.lua — Logging, extstate storage, and path utilities.
- json.lua — Standard JSON encoder and decoder.
- docx_xml_extractor.lua — Unpacks and extracts XML payloads from .docx packages.
- docx_xml_parser.lua — Parses extracted Word processing XML content into structured nodes.
- docx_dialogue_parser.lua — Extracts character roles, dialogue, and scripts from parsed DOCX structures.
- Parse.lua — General-purpose string and table parsing helpers.
- zip_archive.lua — ZIP extraction interface.
- ase64_encode_decode.lua — Base64 and URL-safe Base64 codec.
- 
eurocast_auth.lua — Token-based identity authentication and refresh client.

---

## Maintenance & Code Quality Standards

1. **ReaImGui Compatibility**: Ensure all UI elements use current ReaImGui API conventions (e.g., passing explicit font sizes to eaper.ImGui_PushFont).
2. **Error Handling & Logging**: Use modules.Util logging functions for diagnostic messages instead of unformatted print statements.
3. **Sandbox Testing**: File operations performed during test runs should be scoped to REAPER's resource path (e.g. Data/Files_Module_Test/tmp) to avoid corrupting user project environments.
