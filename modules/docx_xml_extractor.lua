-- @noindex
-- Minimal DOCX main XML extractor for ReaScript projects.
-- Public entry point:
-- DocxXmlExtractor.extract_main_document_xml(docx_path, out_dir)
--
-- Returns:
--   success -> absolute_path_to_word_document_xml, success_message
--   failure -> nil, error_message

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Files = require("modules.Files")
local Util = require("modules.Util")

local DocxXmlExtractor = {
  settings = {
    keep_listing_on_failure = true,
    delete_listing_on_success = true,
    keep_extract_log_on_failure = true,
    delete_extract_log_on_success = true,
    exec_timeout_ms = 60000
  }
}

local TARGET_ENTRY_CANONICAL = "word/document.xml"
local TARGET_ENTRY_WINDOWS = [[word\document.xml]]
local LISTING_PREFIX = "docx_xml_extractor_list_"
local EXTRACT_LOG_PREFIX = "docx_xml_extractor_extract_"
local LOG_CAP_BYTES = 2 * 1024 * 1024
local DIAGNOSTIC_EXCERPT_BYTES = 4096
local POSIX_SHELL_PATH = "/bin/sh"
local POSIX_SCRIPT_DIR = "/tmp"
local POSIX_SCRIPT_PREFIX = "docx_xml_extractor_exec_"
local POSIX_UNZIP_PATH = "/usr/bin/unzip"
local POSIX_UNZIP_EXIT_MARKER = "unzip_exit_code"

local function dirname(path)
  return tostring(path or ""):match("^(.*)[/\\][^/\\]+$")
end

local function resolve_bundled_7z_path()
  local src = debug.getinfo(1, "S").source or ""
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local module_dir = dirname(src)
  local scr_dir = dirname(module_dir)
  if not module_dir or not scr_dir then
    return nil
  end
  return Util.path_join(Util.path_join(Util.path_join(scr_dir, "bin"), "win"), "7z.exe")
end

local function is_absolute_path(path)
  local text = tostring(path or "")
  if text == "" then return false end
  if Util.is_windows() then
    if text:match("^%a:[/\\]") then return true end
    if text:match("^\\\\[^\\]+\\[^\\]+") then return true end
    return false
  end
  return text:sub(1, 1) == "/"
end

local function has_docx_extension(path)
  local text = tostring(path or "")
  return text:lower():sub(-5) == ".docx"
end

local function make_listing_path(out_dir)
  return Util.path_join(
    out_dir,
    LISTING_PREFIX .. Util.date_time_stamp_with_time_precise() .. ".txt"
  )
end

local function make_extract_log_path(out_dir)
  return Util.path_join(
    out_dir,
    EXTRACT_LOG_PREFIX .. Util.date_time_stamp_with_time_precise() .. ".txt"
  )
end

local function make_posix_script_path()
  return Util.path_join(
    POSIX_SCRIPT_DIR,
    POSIX_SCRIPT_PREFIX .. Util.date_time_stamp_with_time_precise() .. ".sh"
  )
end

local function cleanup_temp_file(path_to_remove, label)
  if type(path_to_remove) ~= "string" or path_to_remove == "" then
    return
  end
  if not r.file_exists(path_to_remove) then
    return
  end
  local ok, err = Files.remove_best_effort(path_to_remove)
  if not ok then
    Util.msg("docx_xml_extractor: failed to remove " .. tostring(label or "temp file") .. ": " .. tostring(err), 2)
  end
end

local function collect_warning_text(parts)
  if #(parts or {}) == 0 then
    return nil
  end
  return "warning: " .. table.concat(parts, "; ")
end

local function append_warning_text(message, warning_parts)
  local warning_text = collect_warning_text(warning_parts)
  if not warning_text then
    return message
  end
  return tostring(message) .. " (" .. warning_text .. ")"
end

local function has_warnings(warning_parts)
  return #(warning_parts or {}) > 0
end

local function append_retained_diagnostics_warning(warning_parts, listing_path, extract_log_path, list_script_path, extract_script_path)
  if not has_warnings(warning_parts) then
    return
  end

  local parts = {
    "retained diagnostic files after warning-success",
    "Listing file: " .. tostring(listing_path)
  }
  if type(extract_log_path) == "string" and extract_log_path ~= "" then
    parts[#parts + 1] = "Extract log: " .. tostring(extract_log_path)
  end
  if type(list_script_path) == "string" and list_script_path ~= "" then
    parts[#parts + 1] = "POSIX list command script: " .. tostring(list_script_path)
  end
  if type(extract_script_path) == "string" and extract_script_path ~= "" then
    parts[#parts + 1] = "POSIX extract command script: " .. tostring(extract_script_path)
  end
  warning_parts[#warning_parts + 1] = table.concat(parts, "; ")
end

local function get_execprocess_first_line(exec_output)
  if exec_output == nil then
    return nil, "ExecProcess returned nil"
  end
  local first_line = tostring(exec_output):match("^([^\r\n]*)")
  return Util.trim(first_line or ""), nil
end

local function get_execprocess_body(exec_output)
  if exec_output == nil then
    return nil
  end
  return tostring(exec_output):match("^[^\r\n]*\r?\n(.*)$") or ""
end

local function wrap_shell_command(command)
  local text = tostring(command or "")
  if text == "" then
    return text
  end
  if Util.is_windows() then
    return 'cmd /D /Q /C "' .. text .. '"'
  end
  return POSIX_SHELL_PATH .. " -c " .. Util.shell_quote(text)
end

local function write_posix_command_script(command, diagnostic_path)
  local script_path = make_posix_script_path()
  local script_text =
    "#!/bin/sh\n" ..
    tostring(command or "") .. "\n" ..
    "tool_status=$?\n"
  if type(diagnostic_path) == "string" and diagnostic_path ~= "" then
    script_text = script_text ..
      "{\n" ..
      "  printf '\\n'\n" ..
      "  printf '" .. POSIX_UNZIP_EXIT_MARKER .. "=%s\\n' \"$tool_status\"\n" ..
      "} >> " .. Util.shell_quote(diagnostic_path) .. " 2>/dev/null\n"
  end
  script_text = script_text .. "exit \"$tool_status\"\n"
  local ok, err = Files.write_file(script_path, script_text)
  if not ok then
    return nil, "failed to write POSIX command script: " .. tostring(err)
  end
  return script_path, nil
end

local function build_execprocess_command(command, diagnostic_path)
  if Util.is_windows() then
    return wrap_shell_command(command), nil, nil
  end

  local script_path, script_err = write_posix_command_script(command, diagnostic_path)
  if not script_path then
    return nil, script_err, nil
  end

  return POSIX_SHELL_PATH .. " " .. script_path, nil, script_path
end

local function run_execprocess_command(command, timeout_ms, stage_name, diagnostic_path)
  local exec_command, exec_command_err, exec_script_path = build_execprocess_command(command, diagnostic_path)
  if not exec_command then
    return nil, "docx_xml_extractor: " .. tostring(stage_name) .. " command failed: " .. tostring(exec_command_err), nil, nil
  end

  local exec_output = r.ExecProcess(exec_command, timeout_ms)
  local first_line, line_err = get_execprocess_first_line(exec_output)
  if first_line == nil then
    return nil, "docx_xml_extractor: " .. tostring(stage_name) .. " command failed: " .. tostring(line_err), nil, exec_script_path
  end

  local warning = nil
  if first_line == "" then
    warning = tostring(stage_name) .. " REAPER ExecProcess first line is empty"
  else
    local exit_code = tonumber(first_line)
    if exit_code == nil then
      warning = tostring(stage_name) .. " REAPER ExecProcess first line is not numeric: " .. tostring(first_line)
    elseif exit_code ~= 0 then
      if Util.is_windows() then
        warning = tostring(stage_name) .. " REAPER ExecProcess command exit code reported as " .. tostring(exit_code)
      else
        warning = tostring(stage_name) .. " REAPER ExecProcess shell exit code reported as " .. tostring(exit_code)
      end
    end
  end

  return first_line, warning, get_execprocess_body(exec_output), exec_script_path
end

local function normalize_archive_member_path(path)
  local text = Util.trim(path)
  if text == "" then
    return ""
  end
  return text:gsub("\\", "/")
end

local function read_diagnostic_excerpt(path)
  local text = Files.read_tail(path, DIAGNOSTIC_EXCERPT_BYTES)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  text = text:gsub("%z", "")
  text = Util.trim(text)
  if text == "" then
    return nil
  end
  return text
end

local function append_diagnostic_excerpt(message, diagnostic_path)
  local excerpt = read_diagnostic_excerpt(diagnostic_path)
  if not excerpt then
    return message
  end
  return tostring(message) .. "\nDiagnostic excerpt:\n" .. excerpt
end

local function read_posix_unzip_exit_marker(log_text)
  local found = nil
  for value in tostring(log_text or ""):gmatch(POSIX_UNZIP_EXIT_MARKER .. "=(-?%d+)") do
    found = tonumber(value)
  end
  return found
end

local function append_posix_unzip_marker_warning(warning_parts, stage_name, log_text)
  if Util.is_windows() then
    return
  end
  local exit_code = read_posix_unzip_exit_marker(log_text)
  if exit_code ~= nil and exit_code ~= 0 then
    warning_parts[#warning_parts + 1] = tostring(stage_name) .. " " .. POSIX_UNZIP_EXIT_MARKER .. "=" .. tostring(exit_code)
  end
end

local function build_diagnostic_file_missing_message(stage_name, diagnostic_path, read_err, archive_tool_path, exec_script_path)
  local parts = {
    "docx_xml_extractor: " .. tostring(stage_name) ..
      " command failed because diagnostic file could not be read: " .. tostring(read_err) .. ".",
    "Listing file: " .. tostring(diagnostic_path)
  }
  if not Util.is_windows() then
    parts[#parts + 1] = "POSIX shell: " .. POSIX_SHELL_PATH
  end
  if type(archive_tool_path) == "string" and archive_tool_path ~= "" then
    parts[#parts + 1] = "Archive tool: " .. archive_tool_path
  end
  if type(exec_script_path) == "string" and exec_script_path ~= "" then
    parts[#parts + 1] = "POSIX command script: " .. exec_script_path
  end
  return table.concat(parts, "\n")
end

local function listing_contains_target_entry(listing_text)
  for line in tostring(listing_text or ""):gmatch("([^\r\n]+)") do
    local trimmed = Util.trim(line)
    if trimmed ~= "" then
      if normalize_archive_member_path(trimmed) == TARGET_ENTRY_CANONICAL then
        return true
      end
      local last_token = trimmed:match("([^%s]+)$")
      if normalize_archive_member_path(last_token) == TARGET_ENTRY_CANONICAL then
        return true
      end
    end
  end
  return false
end

local function resolve_posix_unzip_path(timeout_ms)
  if r.file_exists(POSIX_UNZIP_PATH) == true then
    return POSIX_UNZIP_PATH, nil
  end

  local first_line, _warning, body, resolve_script_path = run_execprocess_command("command -v unzip 2>/dev/null", timeout_ms, "resolve_unzip")
  cleanup_temp_file(resolve_script_path, "POSIX command script")
  if first_line == nil then
    return nil, "docx_xml_extractor: POSIX unzip not found. Checked " .. tostring(POSIX_UNZIP_PATH) .. " and command -v unzip"
  end

  for line in tostring(body or ""):gmatch("([^\r\n]+)") do
    local candidate = Util.trim(line)
    if candidate ~= "" then
      return candidate, nil
    end
  end

  if tonumber(first_line) == nil and Util.trim(first_line) ~= "" then
    return Util.trim(first_line), nil
  end

  return nil, "docx_xml_extractor: POSIX unzip not found. Checked " .. tostring(POSIX_UNZIP_PATH) .. " and command -v unzip"
end

local function remove_existing_output_file(path_to_file)
  if not r.file_exists(path_to_file) then
    return true
  end
  local ok, err = Files.remove_best_effort(path_to_file)
  if not ok then
    return false, "docx_xml_extractor: failed to remove existing extracted XML before overwrite: " .. tostring(err)
  end
  return true
end

function DocxXmlExtractor.extract_main_document_xml(docx_path, out_dir)
  local input_path = Util.trim(docx_path)
  local output_dir = Util.trim(out_dir)

  if input_path == "" then
    return nil, "docx_xml_extractor: docx_path must be a non-empty absolute path"
  end
  if output_dir == "" then
    return nil, "docx_xml_extractor: out_dir must be a non-empty absolute path"
  end
  if not is_absolute_path(input_path) then
    return nil, "docx_xml_extractor: docx_path must be an absolute path: " .. tostring(input_path)
  end
  if not is_absolute_path(output_dir) then
    return nil, "docx_xml_extractor: out_dir must be an absolute path: " .. tostring(output_dir)
  end
  if not has_docx_extension(input_path) then
    return nil, "docx_xml_extractor: only .docx input is supported: " .. tostring(input_path)
  end
  if not r.file_exists(input_path) then
    return nil, "docx_xml_extractor: input file not found: " .. tostring(input_path)
  end

  local ok_out, err_out = Files.ensure_output_dir(output_dir)
  if not ok_out then
    return nil, "docx_xml_extractor: output directory is not writable: " .. tostring(err_out)
  end

  local listing_path = make_listing_path(output_dir)
  local extract_log_path = make_extract_log_path(output_dir)
  local extracted_xml_path = Util.path_join(Util.path_join(output_dir, "word"), "document.xml")
  local timeout_ms = tonumber(DocxXmlExtractor.settings.exec_timeout_ms) or 60000
  if timeout_ms < 1 then
    timeout_ms = 60000
  end

  local archive_tool_path = nil
  local archive_tool_err = nil
  local list_command = nil
  local extract_command = nil
  if Util.is_windows() then
    archive_tool_path = resolve_bundled_7z_path()
    if type(archive_tool_path) ~= "string" or archive_tool_path == "" or (not r.file_exists(archive_tool_path)) then
      return nil, "docx_xml_extractor: bundled 7z.exe not found: " .. tostring(archive_tool_path)
    end

    local quoted_7z = Util.shell_quote(archive_tool_path)
    local quoted_docx = Util.shell_quote(input_path)
    local quoted_listing = Util.shell_quote(listing_path)
    local quoted_extract_log = Util.shell_quote(extract_log_path)
    list_command = quoted_7z .. " l " .. quoted_docx .. " > " .. quoted_listing .. " 2>&1"
    extract_command =
      quoted_7z .. " x " ..
      quoted_docx .. " " ..
      Util.shell_quote(TARGET_ENTRY_WINDOWS) .. " " ..
      "-o" .. Util.shell_quote(output_dir) .. " -y > " .. quoted_extract_log .. " 2>&1"
  else
    archive_tool_path, archive_tool_err = resolve_posix_unzip_path(timeout_ms)
    if type(archive_tool_path) ~= "string" or archive_tool_path == "" then
      return nil, tostring(archive_tool_err or "docx_xml_extractor: POSIX unzip not found")
    end

    local quoted_unzip = Util.shell_quote(archive_tool_path)
    local quoted_docx = Util.shell_quote(input_path)
    local quoted_listing = Util.shell_quote(listing_path)
    local quoted_extract_log = Util.shell_quote(extract_log_path)
    list_command = quoted_unzip .. " -Z1 " .. quoted_docx .. " > " .. quoted_listing .. " 2>&1"
    extract_command =
      quoted_unzip .. " -o " ..
      quoted_docx .. " " ..
      Util.shell_quote(TARGET_ENTRY_CANONICAL) .. " " ..
      "-d " .. Util.shell_quote(output_dir) .. " > " .. quoted_extract_log .. " 2>&1"
  end

  local warning_parts = {}

  local function keep_or_cleanup_logs_on_failure(_include_extract_log)
    -- Reliability incidents showed that retained diagnostics are required for support.
    -- Do not delete archive logs or POSIX scripts on failures.
  end

  local _list_first_line, list_warning_or_err, _list_body, list_script_path = run_execprocess_command(list_command, timeout_ms, "list", listing_path)
  if _list_first_line == nil then
    keep_or_cleanup_logs_on_failure(false)
    return nil,
      "docx_xml_extractor: list command failed: " ..
      tostring(list_warning_or_err or "unknown ExecProcess failure") ..
      ". Listing file: " .. tostring(listing_path) ..
      (list_script_path and (". POSIX command script: " .. tostring(list_script_path)) or "")
  end
  if list_warning_or_err then
    warning_parts[#warning_parts + 1] = list_warning_or_err
  end

  local listing_text, listing_size_or_err = Files.slurp_with_cap(listing_path, LOG_CAP_BYTES)
  if listing_text == nil then
    keep_or_cleanup_logs_on_failure(false)
    return nil, append_warning_text(
      build_diagnostic_file_missing_message("list", listing_path, listing_size_or_err, archive_tool_path, list_script_path),
      warning_parts
    )
  end
  append_posix_unzip_marker_warning(warning_parts, "list", listing_text)
  if tonumber(listing_size_or_err) == 0 then
    keep_or_cleanup_logs_on_failure(false)
    return nil, append_warning_text(
      "docx_xml_extractor: list command failed because listing file is empty. Listing file: " .. tostring(listing_path),
      warning_parts
    )
  end
  if not listing_contains_target_entry(listing_text) then
    keep_or_cleanup_logs_on_failure(false)
    if list_warning_or_err then
      return nil, append_warning_text(
        append_diagnostic_excerpt(
          "docx_xml_extractor: list command failed while reading DOCX archive. Listing file: " .. tostring(listing_path),
          listing_path
        ),
        warning_parts
      )
    end
    return nil, append_warning_text(
      append_diagnostic_excerpt(
        "docx_xml_extractor: archive does not contain " .. TARGET_ENTRY_CANONICAL .. ". Listing file: " .. tostring(listing_path),
        listing_path
      ),
      warning_parts
    )
  end

  local ok_remove_existing, remove_existing_err = remove_existing_output_file(extracted_xml_path)
  if not ok_remove_existing then
    keep_or_cleanup_logs_on_failure(false)
    return nil, append_warning_text(
      tostring(remove_existing_err) .. ". Listing file: " .. tostring(listing_path),
      warning_parts
    )
  end

  local _extract_first_line, extract_warning_or_err, _extract_body, extract_script_path = run_execprocess_command(extract_command, timeout_ms, "extract", extract_log_path)
  if _extract_first_line == nil then
    keep_or_cleanup_logs_on_failure(true)
    return nil, append_warning_text(
      "docx_xml_extractor: extract command failed: " ..
        tostring(extract_warning_or_err or "unknown ExecProcess failure") ..
        ". Extract log: " .. tostring(extract_log_path) ..
        (extract_script_path and (". POSIX command script: " .. tostring(extract_script_path)) or ""),
      warning_parts
    )
  end
  if extract_warning_or_err then
    warning_parts[#warning_parts + 1] = extract_warning_or_err
  end

  local extract_log_text, extract_log_size_or_err = Files.slurp_with_cap(extract_log_path, LOG_CAP_BYTES)
  if extract_log_text == nil then
    keep_or_cleanup_logs_on_failure(true)
    return nil, append_warning_text(
      append_diagnostic_excerpt(
        "docx_xml_extractor: extract command failed because extract log could not be read: " ..
          tostring(extract_log_size_or_err) ..
          ". Extract log: " .. tostring(extract_log_path) ..
          (extract_script_path and (". POSIX command script: " .. tostring(extract_script_path)) or ""),
        extract_log_path
      ),
      warning_parts
    )
  end
  append_posix_unzip_marker_warning(warning_parts, "extract", extract_log_text)
  if tonumber(extract_log_size_or_err) == 0 then
    keep_or_cleanup_logs_on_failure(true)
    return nil, append_warning_text(
      "docx_xml_extractor: extract command failed because extract log is empty. Extract log: " .. tostring(extract_log_path),
      warning_parts
    )
  end
  if not r.file_exists(extracted_xml_path) then
    keep_or_cleanup_logs_on_failure(true)
    return nil, append_warning_text(
      append_diagnostic_excerpt(
        "docx_xml_extractor: extract command failed because extracted XML file was not found after extraction: " .. tostring(extracted_xml_path) .. ". Extract log: " .. tostring(extract_log_path),
        extract_log_path
      ),
      warning_parts
    )
  end

  if has_warnings(warning_parts) then
    append_retained_diagnostics_warning(warning_parts, listing_path, extract_log_path, list_script_path, extract_script_path)
  else
    if DocxXmlExtractor.settings.delete_listing_on_success == true then
      cleanup_temp_file(listing_path, "listing file")
    end
    if DocxXmlExtractor.settings.delete_extract_log_on_success == true then
      cleanup_temp_file(extract_log_path, "extract log")
    end
    cleanup_temp_file(list_script_path, "POSIX command script")
    cleanup_temp_file(extract_script_path, "POSIX command script")
  end

  return extracted_xml_path, append_warning_text(
    "docx_xml_extractor: extracted " .. TARGET_ENTRY_CANONICAL,
    warning_parts
  )
end

return DocxXmlExtractor

