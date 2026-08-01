-- @noindex
-- Reaper-hosted interactive tester for DOCX extractor/parser modules.
-- Mirrors the existing tester scripts: runtime guards, package.path handling,
-- ReaImGui loop, persisted UI state, rolling logs, and on-exit state restore.

local r = assert(reaper, "Reaper API not found. This script must be run within Reaper.")

if not r.ImGui_CreateContext then
  r.MB("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository.", "Error", 0)
  return false
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB("Failed to get script path!", "Error", 0)
  return
end

local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

local ok_util, Util = pcall(require, "modules.Util")
if not ok_util then
  package.path = old_package_path
  r.MB("Failed to load modules.Util: " .. tostring(Util), "Error", 0)
  return
end

local ok_files, Files = pcall(require, "modules.Files")
if not ok_files then
  package.path = old_package_path
  r.MB("Failed to load modules.Files: " .. tostring(Files), "Error", 0)
  return
end

local ok_extractor, DocxXmlExtractor = pcall(require, "modules.docx_xml_extractor")
if not ok_extractor then
  package.path = old_package_path
  r.MB("Failed to load modules.docx_xml_extractor: " .. tostring(DocxXmlExtractor), "Error", 0)
  return
end

local ok_parser, DocxXmlParser = pcall(require, "modules.docx_xml_parser")
if not ok_parser then
  package.path = old_package_path
  r.MB("Failed to load modules.docx_xml_parser: " .. tostring(DocxXmlParser), "Error", 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGuiOrErr = pcall(function()
  return require("imgui")("0.10")
end)
package.path = old_package_path
if not ok_imgui then
  r.MB("Failed to load ReaImGui Lua module: " .. tostring(ImGuiOrErr), "Error", 0)
  return
end
local ImGui = ImGuiOrErr

local old_util_state = {
  messaging_level = Util.messaging_level,
  msg_to_log_file = Util.msg_to_log_file,
  log_level_override = Util.log_level_override,
  full_path_to_log_file = Util.full_path_to_log_file,
  tmp_dir = Util.tmp_dir,
  log_file_name = Util.log_file_name
}

local old_extractor_settings = {
  keep_listing_on_failure = DocxXmlExtractor.settings.keep_listing_on_failure,
  delete_listing_on_success = DocxXmlExtractor.settings.delete_listing_on_success,
  keep_extract_log_on_failure = DocxXmlExtractor.settings.keep_extract_log_on_failure,
  delete_extract_log_on_success = DocxXmlExtractor.settings.delete_extract_log_on_success,
  exec_timeout_ms = DocxXmlExtractor.settings.exec_timeout_ms
}

local Helpers, TestCases, UI = {}, {}, {}
local ctx = ImGui.CreateContext("DOCX Test")
local font_size = 16
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)

local runtime = {
  base_root = Util.path_join(r.GetResourcePath(), "Data"),
  last_manual_cleanup = nil
}
runtime.base_root = Util.path_join(runtime.base_root, "Docx_Module_Test")
runtime.log_root = Util.path_join(runtime.base_root, "logs")
runtime.internal_root = Util.path_join(runtime.base_root, "tmp")
runtime.default_output_root = Util.path_join(runtime.base_root, "output")
r.RecursiveCreateDirectory(runtime.log_root, 0)
r.RecursiveCreateDirectory(runtime.internal_root, 0)
r.RecursiveCreateDirectory(runtime.default_output_root, 0)

local EXTSTATE = {
  section = "test_docx_ui",
  docx_path = "docx_path",
  xml_path = "xml_path",
  output_root = "output_root",
  header_enabled = "header_enabled"
}

local state = {
  docx_path = "",
  xml_path = "",
  output_root = runtime.default_output_root,
  header_enabled = false,
  confirm_destructive = false,
  last_status_text = "Ready.",
  status_text = "Ready.",
  rolling_log_lines = {},
  log_max_lines = 350,
  counters = { pass = 0, fail = 0, skip = 0 },
  last_extract = {
    ok = nil,
    input_docx = "",
    output_dir = "",
    xml_path = "",
    message = "",
    elapsed_sec = nil
  },
  last_parse = {
    ok = nil,
    input_xml = "",
    header_enabled = false,
    message = "",
    number_of_columns = 0,
    number_of_rows = 0,
    header = nil,
    rows = {},
    elapsed_sec = nil
  },
  last_run_output_dir = "",
  last_artifact_xml_path = ""
}

local function restore_state()
  package.path = old_package_path
  Util.messaging_level = old_util_state.messaging_level
  Util.msg_to_log_file = old_util_state.msg_to_log_file
  Util.log_level_override = old_util_state.log_level_override
  Util.full_path_to_log_file = old_util_state.full_path_to_log_file
  Util.tmp_dir = old_util_state.tmp_dir
  Util.log_file_name = old_util_state.log_file_name

  DocxXmlExtractor.settings.keep_listing_on_failure = old_extractor_settings.keep_listing_on_failure
  DocxXmlExtractor.settings.delete_listing_on_success = old_extractor_settings.delete_listing_on_success
  DocxXmlExtractor.settings.keep_extract_log_on_failure = old_extractor_settings.keep_extract_log_on_failure
  DocxXmlExtractor.settings.delete_extract_log_on_success = old_extractor_settings.delete_extract_log_on_success
  DocxXmlExtractor.settings.exec_timeout_ms = old_extractor_settings.exec_timeout_ms
end

r.atexit(restore_state)

Util.messaging_level = 0
Util.msg_to_log_file = true
Util.log_level_override = nil
Util.full_path_to_log_file = nil
Util.tmp_dir = runtime.log_root
Util.log_file_name = "test_docx_log"

DocxXmlExtractor.settings.keep_listing_on_failure = true
DocxXmlExtractor.settings.delete_listing_on_success = false
DocxXmlExtractor.settings.keep_extract_log_on_failure = true
DocxXmlExtractor.settings.delete_extract_log_on_success = false

function Helpers.add_log_line(line)
  table.insert(state.rolling_log_lines, line)
  if #state.rolling_log_lines > state.log_max_lines then
    table.remove(state.rolling_log_lines, 1)
  end
end

function Helpers.log_step(test_id, message, importance)
  local line = os.date("%H:%M:%S") .. " [STEP] " .. tostring(test_id) .. " - " .. tostring(message or "")
  Helpers.add_log_line(line)
  Util.msg(line, importance or 1)
end

function Helpers.log_outcome(test_id, status, details)
  local st = tostring(status or "FAIL")
  local line = os.date("%H:%M:%S") .. " [" .. st .. "] " .. tostring(test_id) .. " - " .. tostring(details or "")
  state.last_status_text = line
  state.status_text = line
  Helpers.add_log_line(line)
  if st == "PASS" then
    state.counters.pass = state.counters.pass + 1
    Util.msg(line, 1)
  elseif st == "SKIP" then
    state.counters.skip = state.counters.skip + 1
    Util.msg(line, 1)
  else
    state.counters.fail = state.counters.fail + 1
    Util.msg(line, 2)
  end
end

function Helpers.log_result(test_id, passed, details)
  Helpers.log_outcome(test_id, passed and "PASS" or "FAIL", details)
end

function Helpers.persist_string(key, value)
  local ok, err = Util.extstate_set(EXTSTATE.section, key, tostring(value or ""), true)
  if not ok then
    Helpers.log_step("persist_" .. tostring(key), "Failed: " .. tostring(err), 2)
  end
end

function Helpers.persist_boolean(key, value)
  Helpers.persist_string(key, value and "1" or "0")
end

function Helpers.load_persisted_string(key)
  local value, err = Util.extstate_get(EXTSTATE.section, key)
  if err then
    Helpers.log_step("load_" .. tostring(key), "Failed: " .. tostring(err), 2)
    return nil
  end
  return value
end

function Helpers.is_windows_absolute_path(path)
  local text = tostring(path or "")
  if text == "" then return false end
  if Util.mac then
    return text:sub(1, 1) == "/"
  end
  if text:match("^%a:[/\\]") then return true end
  if text:match("^\\\\[^\\]+\\[^\\]+") then return true end
  return false
end

function Helpers.has_extension(path, ext)
  local text = tostring(path or ""):lower()
  return text:sub(-#ext) == ext
end

function Helpers.format_elapsed_seconds(elapsed_sec)
  if type(elapsed_sec) ~= "number" then
    return "(n/a)"
  end
  return string.format("%.6f sec (%.3f ms)", elapsed_sec, elapsed_sec * 1000.0)
end

function Helpers.safe_header_label(idx, value)
  local text = tostring(value or "")
  if text == "" then
    return string.format("Col %d (blank)", idx)
  end
  return text
end

function Helpers.load_persisted_state()
  local docx_path = Helpers.load_persisted_string(EXTSTATE.docx_path)
  if type(docx_path) == "string" then
    state.docx_path = docx_path
  end

  local xml_path = Helpers.load_persisted_string(EXTSTATE.xml_path)
  if type(xml_path) == "string" then
    state.xml_path = xml_path
  end

  local output_root = Helpers.load_persisted_string(EXTSTATE.output_root)
  if type(output_root) == "string" and output_root ~= "" then
    state.output_root = output_root
  end

  local header_enabled = Helpers.load_persisted_string(EXTSTATE.header_enabled)
  if header_enabled == "1" or header_enabled == "true" then
    state.header_enabled = true
  end
end

function Helpers.prompt_for_file(window_title, initial_dir, file_types)
  local title = window_title or "Select a File"
  local initial = initial_dir or ""
  if initial ~= "" then
    local last_char = initial:sub(-1)
    if last_char ~= Util.separator and last_char ~= "/" and last_char ~= "\\" then
      initial = initial .. Util.separator
    end
  end

  local ok_pick, selected_path = r.GetUserFileNameForRead(initial, title, file_types or "")
  if not ok_pick then
    return false, "File selection was cancelled by the user or an error occurred."
  end
  if selected_path == nil or selected_path == "" then
    return false, "File selection reported success, but no valid file path was returned."
  end
  return true, selected_path
end

function Helpers.make_run_output_dir(prefix)
  local base_root = Util.trim(state.output_root)
  if base_root == "" then
    return nil, "output_root must be a non-empty string"
  end
  local dir_name = tostring(prefix or "run") .. "_" .. Util.date_time_stamp_with_time_precise()
  return Util.path_join(base_root, dir_name)
end

function Helpers.path_inside_created_output_dir(path, out_dir)
  return Files.is_path_inside(out_dir, path)
end

function Helpers.readable_bool(value)
  if value == true then return "true" end
  if value == false then return "false" end
  return "(nil)"
end

function Helpers.format_cleanup_report(report)
  local data = type(report) == "table" and report or {}
  return
    "status=" .. tostring(data.status or "") ..
    "; files_deleted=" .. tostring(data.removed_file_count or 0) ..
    "; dirs_deleted=" .. tostring(data.removed_dir_count or 0) ..
    "; root_exists_after=" .. Helpers.readable_bool(data.root_exists_after) ..
    "; errors=" .. tostring(#(data.errors or {})) ..
    "; root=" .. tostring(data.target_path or "") ..
    "; summary=" .. tostring(data.summary or "")
end

function Helpers.guard_manual_cleanup(path)
  local root_path = Util.trim(path)
  if root_path == "" then
    return false, "configured output root is empty"
  end
  if not state.confirm_destructive then
    return false, "confirmation checkbox is not enabled"
  end
  if not Helpers.is_windows_absolute_path(root_path) then
    return false, "configured output root must be an absolute path"
  end
  return true
end

function Helpers.store_extract_result(payload)
  state.last_extract.ok = payload.ok
  state.last_extract.input_docx = payload.input_docx or ""
  state.last_extract.output_dir = payload.output_dir or ""
  state.last_extract.xml_path = payload.xml_path or ""
  state.last_extract.message = payload.message or ""
  state.last_extract.elapsed_sec = payload.elapsed_sec
  state.last_run_output_dir = payload.output_dir or ""
  state.last_artifact_xml_path = payload.xml_path or ""
end

function Helpers.store_parse_result(payload)
  state.last_parse.ok = payload.ok
  state.last_parse.input_xml = payload.input_xml or ""
  state.last_parse.header_enabled = payload.header_enabled == true
  state.last_parse.message = payload.result and payload.result.message or payload.message or ""
  state.last_parse.number_of_columns = tonumber(payload.result and payload.result.number_of_columns) or 0
  state.last_parse.number_of_rows = tonumber(payload.result and payload.result.number_of_rows) or 0
  state.last_parse.header = payload.result and payload.result.header or nil
  state.last_parse.rows = payload.result and payload.result.rows or {}
  state.last_parse.elapsed_sec = payload.elapsed_sec
end

function Helpers.run_extract_once(docx_path, out_dir)
  local started_at = r.time_precise()
  local xml_path, message = DocxXmlExtractor.extract_main_document_xml(docx_path, out_dir)
  local elapsed_sec = r.time_precise() - started_at
  local ok =
    type(xml_path) == "string" and xml_path ~= "" and
    r.file_exists(xml_path) == true and
    type(message) == "string" and message ~= "" and
    Helpers.path_inside_created_output_dir(xml_path, out_dir)

  local payload = {
    ok = ok,
    input_docx = docx_path,
    output_dir = out_dir,
    xml_path = xml_path or "",
    message = tostring(message or ""),
    elapsed_sec = elapsed_sec
  }
  Helpers.store_extract_result(payload)
  return payload
end

function Helpers.run_parse_once(xml_path, header_enabled)
  local started_at = r.time_precise()
  local result = DocxXmlParser.parse_docx_xml(xml_path, header_enabled)
  local elapsed_sec = r.time_precise() - started_at
  local ok =
    type(result) == "table" and
    result.message == "_Success_" and
    type(result.rows) == "table" and
    (tonumber(result.number_of_columns) or 0) > 0 and
    (tonumber(result.number_of_rows) or -1) >= 0

  if ok and header_enabled then
    ok = type(result.header) == "table" and (tonumber(result.number_of_rows) or -1) == #result.rows
  end

  local payload = {
    ok = ok,
    input_xml = xml_path,
    header_enabled = header_enabled == true,
    result = result,
    elapsed_sec = elapsed_sec,
    message = type(result) == "table" and tostring(result.message or "") or ""
  }
  Helpers.store_parse_result(payload)
  return payload
end

function Helpers.ensure_parse_input(xml_path)
  local text = Util.trim(xml_path)
  if text == "" then
    return false, "xml_path must be a non-empty string"
  end
  if not Helpers.is_windows_absolute_path(text) then
    return false, "xml_path must be an absolute path"
  end
  if not Helpers.has_extension(text, ".xml") then
    return false, "xml_path must point to a .xml file"
  end
  if r.file_exists(text) ~= true then
    return false, "xml_path not found: " .. tostring(text)
  end
  return true
end

function Helpers.ensure_extract_inputs(docx_path, output_root)
  local docx = Util.trim(docx_path)
  local out_root = Util.trim(output_root)
  if docx == "" then
    return false, "docx_path must be a non-empty string"
  end
  if out_root == "" then
    return false, "output_root must be a non-empty string"
  end
  if not Helpers.is_windows_absolute_path(docx) then
    return false, "docx_path must be an absolute path"
  end
  if not Helpers.is_windows_absolute_path(out_root) then
    return false, "output_root must be an absolute path"
  end
  if not Helpers.has_extension(docx, ".docx") then
    return false, "docx_path must point to a .docx file"
  end
  if r.file_exists(docx) ~= true then
    return false, "docx_path not found: " .. tostring(docx)
  end
  return true
end

function TestCases.run_extract_docx_test()
  local test_id = "extract_docx"
  Helpers.log_step(test_id, "Starting")
  local ok_inputs, input_err = Helpers.ensure_extract_inputs(state.docx_path, state.output_root)
  if not ok_inputs then
    Helpers.log_result(test_id, false, input_err)
    return
  end

  local out_dir, out_err = Helpers.make_run_output_dir("extract")
  if not out_dir then
    Helpers.log_result(test_id, false, out_err)
    return
  end

  local payload = Helpers.run_extract_once(state.docx_path, out_dir)
  local detail =
    "ok=" .. Helpers.readable_bool(payload.ok) ..
    "; elapsed=" .. Helpers.format_elapsed_seconds(payload.elapsed_sec) ..
    "; out_dir=" .. tostring(payload.output_dir) ..
    "; xml_path=" .. tostring(payload.xml_path) ..
    "; msg=" .. tostring(payload.message)
  Helpers.log_result(test_id, payload.ok, detail)
  if payload.ok then
    state.xml_path = payload.xml_path
    Helpers.persist_string(EXTSTATE.xml_path, state.xml_path)
  end
end

function TestCases.run_parse_xml_test()
  local test_id = "parse_xml"
  Helpers.log_step(test_id, "Starting")
  local ok_input, input_err = Helpers.ensure_parse_input(state.xml_path)
  if not ok_input then
    Helpers.log_result(test_id, false, input_err)
    return
  end

  local payload = Helpers.run_parse_once(state.xml_path, state.header_enabled)
  local detail =
    "ok=" .. Helpers.readable_bool(payload.ok) ..
    "; elapsed=" .. Helpers.format_elapsed_seconds(payload.elapsed_sec) ..
    "; cols=" .. tostring(payload.result and payload.result.number_of_columns) ..
    "; rows=" .. tostring(payload.result and payload.result.number_of_rows) ..
    "; msg=" .. tostring(payload.result and payload.result.message)
  Helpers.log_result(test_id, payload.ok, detail)
end

function TestCases.run_extract_and_parse_docx_test()
  local test_id = "extract_and_parse_docx"
  Helpers.log_step(test_id, "Starting")
  local ok_inputs, input_err = Helpers.ensure_extract_inputs(state.docx_path, state.output_root)
  if not ok_inputs then
    Helpers.log_result(test_id, false, input_err)
    return
  end

  local out_dir, out_err = Helpers.make_run_output_dir("extract_parse")
  if not out_dir then
    Helpers.log_result(test_id, false, out_err)
    return
  end

  local extract_payload = Helpers.run_extract_once(state.docx_path, out_dir)
  if not extract_payload.ok then
    Helpers.log_result(
      test_id,
      false,
      "extract failed; elapsed=" .. Helpers.format_elapsed_seconds(extract_payload.elapsed_sec) ..
      "; out_dir=" .. tostring(extract_payload.output_dir) ..
      "; msg=" .. tostring(extract_payload.message)
    )
    return
  end

  state.xml_path = extract_payload.xml_path
  Helpers.persist_string(EXTSTATE.xml_path, state.xml_path)

  local parse_payload = Helpers.run_parse_once(extract_payload.xml_path, state.header_enabled)
  local passed = extract_payload.ok and parse_payload.ok
  local detail =
    "extract_elapsed=" .. Helpers.format_elapsed_seconds(extract_payload.elapsed_sec) ..
    "; parse_elapsed=" .. Helpers.format_elapsed_seconds(parse_payload.elapsed_sec) ..
    "; out_dir=" .. tostring(extract_payload.output_dir) ..
    "; xml_path=" .. tostring(extract_payload.xml_path) ..
    "; cols=" .. tostring(parse_payload.result and parse_payload.result.number_of_columns) ..
    "; rows=" .. tostring(parse_payload.result and parse_payload.result.number_of_rows) ..
    "; parse_msg=" .. tostring(parse_payload.result and parse_payload.result.message)
  Helpers.log_result(test_id, passed, detail)
end

function TestCases.run_validation_smoke_test()
  local test_id = "validation_smoke"
  Helpers.log_step(test_id, "Starting")

  local smoke_root = Util.path_join(runtime.internal_root, "validation_smoke")
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(smoke_root)
  if not ok_tmp then
    Helpers.log_result(test_id, false, "failed to prepare smoke_root: " .. tostring(err_tmp))
    return
  end

  local placeholder_docx = Util.path_join(smoke_root, "placeholder.docx")
  local placeholder_txt = Util.path_join(smoke_root, "placeholder.txt")
  local ok_docx, err_docx = Files.write_file(placeholder_docx, "not a real docx")
  if not ok_docx then
    Helpers.log_result(test_id, false, "failed to create placeholder.docx: " .. tostring(err_docx))
    return
  end
  local ok_txt, err_txt = Files.write_file(placeholder_txt, "not xml")
  if not ok_txt then
    Helpers.log_result(test_id, false, "failed to create placeholder.txt: " .. tostring(err_txt))
    return
  end

  local checks = {}

  local xml_path_empty, msg_docx_empty = DocxXmlExtractor.extract_main_document_xml("", runtime.default_output_root)
  checks[#checks + 1] =
    (xml_path_empty == nil) and
    (tostring(msg_docx_empty):find("docx_path must be a non%-empty absolute path") ~= nil)

  local xml_path_missing, msg_docx_missing = DocxXmlExtractor.extract_main_document_xml(
    Util.path_join(smoke_root, "missing.docx"),
    runtime.default_output_root
  )
  checks[#checks + 1] =
    (xml_path_missing == nil) and
    (tostring(msg_docx_missing):find("input file not found", 1, true) ~= nil)

  local xml_path_wrong_ext, msg_docx_wrong_ext = DocxXmlExtractor.extract_main_document_xml(
    placeholder_txt,
    runtime.default_output_root
  )
  checks[#checks + 1] =
    (xml_path_wrong_ext == nil) and
    (tostring(msg_docx_wrong_ext):find("only .docx input is supported", 1, true) ~= nil)

  local xml_path_empty_out, msg_docx_empty_out = DocxXmlExtractor.extract_main_document_xml(placeholder_docx, "")
  checks[#checks + 1] =
    (xml_path_empty_out == nil) and
    (tostring(msg_docx_empty_out):find("out_dir must be a non%-empty absolute path") ~= nil)

  local parse_empty = DocxXmlParser.parse_docx_xml("", state.header_enabled)
  checks[#checks + 1] =
    (type(parse_empty) == "table") and
    (tostring(parse_empty.message):find("path_to_valid_docx_xml must be a non%-empty string") ~= nil)

  local parse_missing = DocxXmlParser.parse_docx_xml(Util.path_join(smoke_root, "missing.xml"), state.header_enabled)
  checks[#checks + 1] =
    (type(parse_missing) == "table") and
    (tostring(parse_missing.message):find("failed to read XML file", 1, true) ~= nil)

  local parse_wrong_ext_ok, parse_wrong_ext_err = Helpers.ensure_parse_input(placeholder_txt)
  checks[#checks + 1] =
    (parse_wrong_ext_ok == false) and
    (tostring(parse_wrong_ext_err):find(".xml", 1, true) ~= nil)

  local passed = true
  for i = 1, #checks do
    if checks[i] ~= true then
      passed = false
      break
    end
  end

  Helpers.log_result(test_id, passed, "checks_passed=" .. tostring(#checks) .. "; smoke_root=" .. tostring(smoke_root))
end

function TestCases.run_manual_cleanup_output_root()
  local test_id = "cleanup_output_root"
  Helpers.log_step(test_id, "Starting cleanup")
  local ok_guard, guard_err = Helpers.guard_manual_cleanup(state.output_root)
  if not ok_guard then
    Helpers.log_result(test_id, false, guard_err)
    return
  end

  local root_path = Util.trim(state.output_root)
  local ok_dir, ensure_err = Files.ensure_tmp_dir(root_path)
  if not ok_dir then
    Helpers.log_result(test_id, false, "cannot access output_root: " .. tostring(ensure_err))
    return
  end

  local started_at = r.time_precise()
  local ok_cleanup, cleanup_report = Files.remove_dir_contents_keep_root(root_path)
  local elapsed_sec = r.time_precise() - started_at
  local detail =
    "ok=" .. Helpers.readable_bool(ok_cleanup) ..
    "; elapsed=" .. Helpers.format_elapsed_seconds(elapsed_sec) ..
    "; " .. Helpers.format_cleanup_report(cleanup_report)
  Helpers.log_result(test_id, ok_cleanup, detail)
end

function UI.set_separator_text(label)
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, label)
  else
    ImGui.Separator(ctx)
    ImGui.Text(ctx, label)
  end
end

function UI.render_status_panel()
  local has_fail = state.counters.fail > 0
  if has_fail then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF3030FF)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF)
  end
  ImGui.Text(
    ctx,
    "Totals: PASS=" .. tostring(state.counters.pass) ..
      " FAIL=" .. tostring(state.counters.fail) ..
      " SKIP=" .. tostring(state.counters.skip)
  )
  ImGui.PopStyleColor(ctx)
  ImGui.TextWrapped(ctx, "Last status: " .. tostring(state.status_text or state.last_status_text or "(none)"))
end

function UI.render_extract_summary()
  UI.set_separator_text("Last Extract Result")
  local last = state.last_extract
  ImGui.Text(ctx, "ok: " .. Helpers.readable_bool(last.ok))
  ImGui.TextWrapped(ctx, "input_docx: " .. tostring(last.input_docx or "(none)"))
  ImGui.TextWrapped(ctx, "output_dir: " .. tostring(last.output_dir or "(none)"))
  ImGui.TextWrapped(ctx, "xml_path: " .. tostring(last.xml_path or "(none)"))
  ImGui.TextWrapped(ctx, "elapsed: " .. Helpers.format_elapsed_seconds(last.elapsed_sec))
  ImGui.TextWrapped(ctx, "message: " .. tostring(last.message or ""))
end

function UI.render_artifact_summary()
  UI.set_separator_text("Artifact Paths")
  ImGui.TextWrapped(ctx, "last_run_output_dir: " .. tostring(state.last_run_output_dir or "(none)"))
  ImGui.TextWrapped(ctx, "last_artifact_xml_path: " .. tostring(state.last_artifact_xml_path or "(none)"))
end

function UI.render_parse_summary()
  UI.set_separator_text("Last Parse Result")
  local last = state.last_parse
  ImGui.Text(ctx, "ok: " .. Helpers.readable_bool(last.ok))
  ImGui.TextWrapped(ctx, "input_xml: " .. tostring(last.input_xml or "(none)"))
  ImGui.Text(ctx, "header_enabled: " .. tostring(last.header_enabled == true))
  ImGui.Text(ctx, "columns: " .. tostring(last.number_of_columns or 0))
  ImGui.Text(ctx, "rows: " .. tostring(last.number_of_rows or 0))
  ImGui.TextWrapped(ctx, "elapsed: " .. Helpers.format_elapsed_seconds(last.elapsed_sec))
  ImGui.TextWrapped(ctx, "message: " .. tostring(last.message or ""))
end

function UI.render_parsed_results_table()
  UI.set_separator_text("Parsed Results")

  local rows = state.last_parse.rows or {}
  local parsed_cols = tonumber(state.last_parse.number_of_columns) or 0
  local display_cols = math.min(parsed_cols, 3)
  if display_cols < 1 then
    ImGui.TextWrapped(ctx, "No parsed table preview available yet.")
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, "Table rendering is not available in this ReaImGui build.")
    return
  end

  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
  local fallback_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 16) or 260
  local log_line_h = ImGui.GetTextLineHeightWithSpacing and ImGui.GetTextLineHeightWithSpacing(ctx) or 20
  local reserved_log_h = log_line_h * 8
  local reserved_log_header_h = log_line_h * 2
  local table_h = math.max(fallback_h, (avail_h or 0) - reserved_log_h - reserved_log_header_h)
  local total_columns = display_cols + 1
  if ImGui.BeginTable(ctx, "##docx_parsed_results_table", total_columns, table_flags, avail_w, table_h) then
    local data_column_weights = {
      [1] = 5.0,
      [2] = 7.0,
      [3] = 10.0,
      [4] = 78.0
    }
    ImGui.TableSetupColumn(ctx, "Row", ImGui.TableColumnFlags_WidthFixed, 56)
    for i = 1, display_cols do
      local title = "Col " .. tostring(i)
      if state.last_parse.header_enabled and type(state.last_parse.header) == "table" then
        title = Helpers.safe_header_label(i, state.last_parse.header[i])
      end
      ImGui.TableSetupColumn(ctx, title, ImGui.TableColumnFlags_WidthStretch, data_column_weights[i] or 1.0)
    end
    if ImGui.TableSetupScrollFreeze then
      ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    end
    ImGui.TableHeadersRow(ctx)

    for row_idx = 1, #rows do
      local row = rows[row_idx]
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, tostring(row_idx))
      for col_idx = 1, display_cols do
        ImGui.TableSetColumnIndex(ctx, col_idx)
        local cell_text = tostring(row and row[col_idx] or "")
        if col_idx == 3 then
          ImGui.PushTextWrapPos(ctx, 0.0)
          ImGui.Text(ctx, cell_text)
          ImGui.PopTextWrapPos(ctx)
        else
          ImGui.Text(ctx, cell_text)
        end
      end
    end
    ImGui.EndTable(ctx)
  end
end

function UI.render_result_log()
  UI.set_separator_text("Rolling Result Log")
  local log_line_h = ImGui.GetTextLineHeightWithSpacing and ImGui.GetTextLineHeightWithSpacing(ctx) or 20
  local log_h = log_line_h * 7
  local start_index = math.max(1, #state.rolling_log_lines - 89)
  local visible_lines = {}
  for i = start_index, #state.rolling_log_lines do
    visible_lines[#visible_lines + 1] = state.rolling_log_lines[i]
  end
  local log_text = table.concat(visible_lines, "\n")
  local flags = ImGui.InputTextFlags_ReadOnly or 0
  ImGui.InputTextMultiline(ctx, "##docx_result_log_view", log_text, -1, log_h, flags)
end

function UI.gui_loop()
  local visible, open = ImGui.Begin(ctx, "DOCX Module Tester", true)
  if visible then
    ImGui.PushFont(ctx, FONT, font_size)
    UI.render_status_panel()

    UI.set_separator_text("Configuration")
    local ch_docx, nv_docx = ImGui.InputText(ctx, "docx_path", tostring(state.docx_path or ""))
    if ch_docx then
      state.docx_path = nv_docx
      Helpers.persist_string(EXTSTATE.docx_path, state.docx_path)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Browse DOCX") then
      local initial_dir = Files.get_dir_from_file_path(state.docx_path)
      local ok_pick, selected_or_err = Helpers.prompt_for_file("Select DOCX file", initial_dir or Files.read_project_path(), "*.docx")
      if ok_pick then
        state.docx_path = selected_or_err
        Helpers.persist_string(EXTSTATE.docx_path, state.docx_path)
        Helpers.log_step("browse_docx", "Selected: " .. tostring(state.docx_path))
      else
        Helpers.log_step("browse_docx", tostring(selected_or_err), 2)
      end
    end

    local ch_xml, nv_xml = ImGui.InputText(ctx, "xml_path", tostring(state.xml_path or ""))
    if ch_xml then
      state.xml_path = nv_xml
      Helpers.persist_string(EXTSTATE.xml_path, state.xml_path)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Browse XML") then
      local initial_dir = Files.get_dir_from_file_path(state.xml_path)
      local ok_pick, selected_or_err = Helpers.prompt_for_file("Select XML file", initial_dir or Files.read_project_path(), "*.xml")
      if ok_pick then
        state.xml_path = selected_or_err
        Helpers.persist_string(EXTSTATE.xml_path, state.xml_path)
        Helpers.log_step("browse_xml", "Selected: " .. tostring(state.xml_path))
      else
        Helpers.log_step("browse_xml", tostring(selected_or_err), 2)
      end
    end

    local ch_output, nv_output = ImGui.InputText(ctx, "output_root", tostring(state.output_root or ""))
    if ch_output then
      state.output_root = nv_output
      Helpers.persist_string(EXTSTATE.output_root, state.output_root)
    end

    local ch_header, nv_header = ImGui.Checkbox(ctx, "header_enabled", state.header_enabled == true)
    if ch_header then
      state.header_enabled = nv_header
      Helpers.persist_boolean(EXTSTATE.header_enabled, state.header_enabled)
    end

    local ch_confirm, nv_confirm = ImGui.Checkbox(ctx, "Confirm destructive actions", state.confirm_destructive == true)
    if ch_confirm then
      state.confirm_destructive = nv_confirm
    end

    if ImGui.Button(ctx, "Ensure output root exists") then
      local ok_dir, err_dir = Files.ensure_tmp_dir(Util.trim(state.output_root))
      Helpers.log_result("ensure_output_root", ok_dir == true, "ok=" .. tostring(ok_dir) .. "; err=" .. tostring(err_dir))
    end

    UI.set_separator_text("DOCX Actions")
    if ImGui.Button(ctx, "Test extract_docx") then TestCases.run_extract_docx_test() end
    if ImGui.Button(ctx, "Test parse_xml") then TestCases.run_parse_xml_test() end
    if ImGui.Button(ctx, "Test extract_and_parse_docx") then TestCases.run_extract_and_parse_docx_test() end
    if ImGui.Button(ctx, "Test validation_smoke") then TestCases.run_validation_smoke_test() end
    if ImGui.Button(ctx, "Manual cleanup output root (destructive)") then TestCases.run_manual_cleanup_output_root() end
    if ImGui.Button(ctx, "Clear result log") then
      state.rolling_log_lines = {}
      state.last_status_text = "Log cleared."
      state.status_text = "Log cleared."
      state.counters = { pass = 0, fail = 0, skip = 0 }
    end

    UI.render_extract_summary()
    UI.render_artifact_summary()
    UI.render_parse_summary()
    UI.render_parsed_results_table()
    UI.render_result_log()

    ImGui.PopFont(ctx)
  end
  ImGui.End(ctx)

  if open then
    r.defer(UI.gui_loop)
  end
end

Helpers.load_persisted_state()
state.status_text = "DOCX tester initialized. output_root=" .. tostring(state.output_root)
state.last_status_text = state.status_text
Helpers.add_log_line(os.date("%H:%M:%S") .. " [INFO] startup_init - " .. state.status_text)
Util.msg(state.status_text, 1)
r.defer(UI.gui_loop)

