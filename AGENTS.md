# Repository Guidelines for AI Agents

This repository (slava-reaper-reapack-test-curl-jobs-imgui) contains a set of ReaImGui interactive test scripts and support modules designed for testing REAPER integration features, formatted for distribution via ReaPack.

---

## Critical Rules & Guidelines

### 1. Branching & Git Workflow
> [!IMPORTANT]
> **Work only on the main branch.**
> If it is absolutely necessary to create another branch, **stop and ask the user** before doing so.

### 2. ReaPack Metadata & File Structure
- **Main Entrypoint Scripts (/test_*.lua)**: Entrypoint test scripts must reside in the root folder and contain complete ReaPack metadata headers (@description, @version, @author, @about, @provides).
- **Support Modules (/modules/*.lua)**: All shared Lua modules must reside in the modules/ folder and include -- @noindex at the top of the file to prevent eapack-index from indexing them as standalone actions.

### 3. Credentials & Security
> [!CAUTION]
> Never hardcode or commit API keys, tokens, passwords, or personal credentials into test scripts or modules. Interactive tests requiring authentication must prompt the user at runtime via UI input fields with appropriate password masking.

---

## Codebase Architecture

### Entrypoint Test Scripts
- 	est_Curl_Jobs.lua — ReaImGui tester for asynchronous HTTP operations (modules.Curl) and background execution queues (modules.Jobs).
- 	est_Files.lua — ReaImGui tester for filesystem utilities (modules.Files), path manipulation, and sandbox file operations.
- 	est_docx.lua — ReaImGui tester for DOCX archive extraction (modules.docx_xml_extractor), XML parsing (modules.docx_xml_parser), and dialogue extraction (modules.docx_dialogue_parser).
- 	est_neurocast_auth.lua — ReaImGui tester for authentication flow testing against Neurocast endpoints (modules.neurocast_auth).

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
