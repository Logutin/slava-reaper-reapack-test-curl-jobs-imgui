-- @noindex
-- Generic ZIP audio extractor for ReaScript projects.
-- Public entry points:
--   ZipArchive.extract_audio_files(zip_path, out_dir)
--   ZipArchive.derive_mix_name_from_archive_filename(file_name, fallback)
--   ZipArchive.order_audio_files_for_production(audio_files, production_details)

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Files = require("modules.Files")
local Util = require("modules.Util")

local ZipArchive = {
  settings = {
    keep_listing_on_failure = true,
    delete_listing_on_success = true,
    keep_extract_log_on_failure = true,
    delete_extract_log_on_success = true,
    delete_posix_scripts_on_success = true,
    exec_timeout_ms = 300000
  }
}

local LISTING_PREFIX = "zip_archive_list_"
local EXTRACT_LOG_PREFIX = "zip_archive_extract_"
local LOG_CAP_BYTES = 2 * 1024 * 1024
local DIAGNOSTIC_EXCERPT_BYTES = 4096
local POSIX_SHELL_PATH = "/bin/sh"
local POSIX_SCRIPT_DIR = "/tmp"
local POSIX_SCRIPT_PREFIX = "zip_archive_exec_"
local POSIX_UNZIP_PATH = "/usr/bin/unzip"
local POSIX_UNZIP_EXIT_MARKER = "unzip_exit_code"

local AUDIO_FILE_EXTENSIONS = {
  wav = true,
  flac = true,
  mp3 = true,
  m4a = true,
  aac = true,
  ogg = true,
  opus = true,
  aiff = true,
  aif = true,
  w64 = true
}

ZipArchive.supported_audio_extensions = AUDIO_FILE_EXTENSIONS

local function dirname(path)
  return tostring(path or ""):match("^(.*)[/\\][^/\\]+$")
end

local function basename(path)
  local text = tostring(path or ""):gsub("\\", "/")
  return text:match("([^/]+)$") or text
end

local function strip_last_extension(file_name)
  local text = tostring(file_name or "")
  return text:match("^(.*)%.[^%.]+$") or text
end

local function normalize_member_path(path)
  local text = Util.trim(path)
  if text == "" then return "" end
  return text:gsub("\\", "/")
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
    Util.msg("zip_archive: failed to remove " .. tostring(label or "temp file") .. ": " .. tostring(err), 2)
  end
end

local function collect_warning_text(parts)
  if #(parts or {}) == 0 then
    return nil
  end
  return "warning: " .. table.concat(parts, "; ")
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

local function run_execprocess_command(command, timeout_ms, stage_name, diagnostic_path)
  local exec_command, exec_command_err, exec_script_path = build_execprocess_command(command, diagnostic_path)
  if not exec_command then
    return {
      ok = false,
      stage = tostring(stage_name or "exec"),
      error = tostring(exec_command_err or "failed to build ExecProcess command"),
      script_path = exec_script_path
    }
  end

  local exec_output = r.ExecProcess(exec_command, timeout_ms)
  local first_line, line_err = get_execprocess_first_line(exec_output)
  if first_line == nil then
    return {
      ok = false,
      stage = tostring(stage_name or "exec"),
      error = tostring(line_err or "ExecProcess failed"),
      body = get_execprocess_body(exec_output),
      script_path = exec_script_path
    }
  end

  local exit_code = nil
  local warning = nil
  local exit_code_label = Util.is_windows() and "REAPER ExecProcess command exit code" or "REAPER ExecProcess shell exit code"
  if first_line == "" then
    warning = tostring(stage_name or "exec") .. " REAPER ExecProcess first line is empty"
  else
    exit_code = tonumber(first_line)
    if exit_code == nil then
      warning = tostring(stage_name or "exec") .. " REAPER ExecProcess first line is not numeric: " .. tostring(first_line)
    elseif exit_code ~= 0 then
      warning = tostring(stage_name or "exec") .. " " .. exit_code_label .. " reported as " .. tostring(exit_code)
    end
  end

  return {
    ok = true,
    stage = tostring(stage_name or "exec"),
    first_line = first_line,
    exit_code = exit_code,
    exit_code_label = exit_code_label,
    warning = warning,
    body = get_execprocess_body(exec_output),
    script_path = exec_script_path
  }
end

local function read_log_excerpt(path)
  local text = Files.read_tail(path, DIAGNOSTIC_EXCERPT_BYTES)
  if type(text) == "string" and text ~= "" then
    text = text:gsub("%s+$", "")
    if text ~= "" then
      return text
    end
  end
  return nil
end

local function read_posix_unzip_exit_marker(log_text)
  local found = nil
  for value in tostring(log_text or ""):gmatch(POSIX_UNZIP_EXIT_MARKER .. "=(-?%d+)") do
    found = tonumber(value)
  end
  return found
end

local function append_exec_warning(warning_parts, exec_result)
  if type(exec_result) == "table" and type(exec_result.warning) == "string" and exec_result.warning ~= "" then
    warning_parts[#warning_parts + 1] = exec_result.warning
  end
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

local function archive_list_stage_label()
  if Util.is_windows() then
    return "7-Zip listing"
  end
  return "unzip listing"
end

local function archive_extract_stage_label()
  if Util.is_windows() then
    return "7-Zip extraction"
  end
  return "unzip extraction"
end

local function audio_entry_filter_stage_label()
  return archive_list_stage_label() .. " audio entry filtering"
end

local function audio_extraction_verification_stage_label()
  return archive_extract_stage_label() .. " verification"
end

local function build_stage_failure(stage_label, archive_tool_path, zip_path, diagnostic_path, exec_result, extra_message)
  local parts = {
    "zip_archive: " .. tostring(stage_label or "archive operation") .. " failed.",
    "Tool: " .. tostring(archive_tool_path or ""),
    "Input: " .. tostring(zip_path or "")
  }

  local input_size = Files.file_size(zip_path)
  if input_size ~= nil then
    parts[#parts + 1] = "Input size: " .. tostring(input_size) .. " bytes"
  end

  if not Util.is_windows() then
    parts[#parts + 1] = "POSIX shell: " .. POSIX_SHELL_PATH
  end
  if type(exec_result) == "table" and exec_result.exit_code ~= nil then
    parts[#parts + 1] = tostring(exec_result.exit_code_label or "Exit code") .. ": " .. tostring(exec_result.exit_code)
  end
  if type(exec_result) == "table" and type(exec_result.warning) == "string" and exec_result.warning ~= "" then
    parts[#parts + 1] = "Warning: " .. tostring(exec_result.warning)
  end
  if type(exec_result) == "table" and type(exec_result.error) == "string" and exec_result.error ~= "" then
    parts[#parts + 1] = "ExecProcess error: " .. tostring(exec_result.error)
  end
  if type(diagnostic_path) == "string" and diagnostic_path ~= "" then
    parts[#parts + 1] = "Diagnostic file: " .. tostring(diagnostic_path)
  end
  if type(exec_result) == "table" and type(exec_result.script_path) == "string" and exec_result.script_path ~= "" then
    parts[#parts + 1] = "POSIX command script: " .. tostring(exec_result.script_path)
  end
  if type(extra_message) == "string" and extra_message ~= "" then
    parts[#parts + 1] = tostring(extra_message)
  end

  local excerpt = read_log_excerpt(diagnostic_path)
  if excerpt then
    parts[#parts + 1] = "Diagnostic excerpt:\n" .. excerpt
  end

  return table.concat(parts, "\n")
end

local function resolve_posix_unzip_path(timeout_ms)
  if r.file_exists(POSIX_UNZIP_PATH) then
    return POSIX_UNZIP_PATH, nil
  end

  local result = run_execprocess_command("command -v unzip 2>/dev/null", timeout_ms, "resolve_unzip")
  if result and result.script_path then
    cleanup_temp_file(result.script_path, "POSIX command script")
  end
  local body = result and result.body or ""
  local candidate = tostring(body or ""):match("([^\r\n]+)")
  candidate = Util.trim(candidate or "")
  if candidate ~= "" and r.file_exists(candidate) then
    return candidate, nil
  end
  return nil, "zip_archive: POSIX unzip not found. Checked " .. tostring(POSIX_UNZIP_PATH) .. " and command -v unzip"
end

local function is_safe_archive_member_path(path)
  local normalized = normalize_member_path(path)
  if normalized == "" then return false end
  if normalized:find("%z") then return false end
  if normalized:sub(-1) == "/" then return false end
  if normalized:sub(1, 1) == "/" then return false end
  if normalized:match("^%a:[/\\]") then return false end
  if normalized:match("^//") then return false end

  for part in normalized:gmatch("[^/]+") do
    if part == "" or part == "." or part == ".." then
      return false
    end
  end

  local file_name = basename(normalized)
  return Files.is_filesystem_safe_name(file_name) == true
end

function ZipArchive.is_supported_audio_filename(file_name)
  local name = tostring(file_name or "")
  local ext = name:match("%.([^.]+)$")
  if not ext then return false end
  return AUDIO_FILE_EXTENSIONS[string.lower(ext)] == true
end

function ZipArchive.audio_file_info_from_entry(entry_path)
  local normalized = normalize_member_path(entry_path)
  if not is_safe_archive_member_path(normalized) then
    return nil
  end

  local file_name = basename(normalized)
  if not ZipArchive.is_supported_audio_filename(file_name) then
    return nil
  end

  return {
    entry = normalized,
    filename = file_name,
    stem_id = strip_last_extension(file_name),
    extension = string.lower(file_name:match("%.([^.]+)$") or "")
  }
end

function ZipArchive.derive_mix_name_from_archive_filename(file_name, fallback)
  local name = basename(file_name)
  name = Util.trim(name)
  if name == "" then
    name = tostring(fallback or "stems")
  end

  local lower = string.lower(name)
  if lower:sub(-9) == ".flac.zip" then
    name = name:sub(1, #name - 9)
  elseif lower:sub(-8) == ".wav.zip" then
    name = name:sub(1, #name - 8)
  elseif lower:sub(-4) == ".zip" then
    name = name:sub(1, #name - 4)
  end

  return Util.sanitize_filename(name, tostring(fallback or "stems"), 128)
end

function ZipArchive.parse_7z_slt_listing(listing_text)
  local entries = {}
  local current = {}

  local function flush()
    if type(current.Path) == "string" and current.Path ~= "" then
      entries[#entries + 1] = {
        path = current.Path,
        folder = current.Folder
      }
    end
    current = {}
  end

  for raw_line in (tostring(listing_text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local line = tostring(raw_line or "")
    if line == "" then
      flush()
    else
      local key, value = line:match("^([^=]+)%s=%s(.*)$")
      if key then
        current[Util.trim(key)] = value
      end
    end
  end
  flush()

  return entries
end

function ZipArchive.parse_unzip_name_listing(listing_text)
  local entries = {}
  for line in tostring(listing_text or ""):gmatch("([^\r\n]+)") do
    local path = Util.trim(line)
    if path ~= "" then
      entries[#entries + 1] = {
        path = path,
        folder = path:sub(-1) == "/" and "+" or "-"
      }
    end
  end
  return entries
end

function ZipArchive.filter_audio_entries(listing_entries)
  local audio_files = {}
  local seen_target_names = {}

  for _, entry in ipairs(listing_entries or {}) do
    if type(entry) == "table" and tostring(entry.folder or "-") ~= "+" then
      local info = ZipArchive.audio_file_info_from_entry(entry.path)
      if info then
        local key = string.lower(info.filename)
        if seen_target_names[key] then
          return nil, "zip_archive: duplicate audio filename after flattening: " .. tostring(info.filename)
        end
        seen_target_names[key] = true
        audio_files[#audio_files + 1] = info
      end
    end
  end

  return audio_files, nil
end

function ZipArchive.order_audio_files_for_production(audio_files, production_details)
  local source = {}
  for i = 1, #(audio_files or {}) do
    source[i] = audio_files[i]
  end

  local by_stem_id = {}
  for _, item in ipairs(source) do
    if type(item) == "table" then
      local stem_id = tostring(item.stem_id or "")
      if stem_id ~= "" and by_stem_id[stem_id] == nil then
        by_stem_id[stem_id] = item
      end
    end
  end

  local ordered = {}
  local used = {}
  if type(production_details) == "table" and type(production_details.multi_input_files) == "table" then
    for _, input_file in ipairs(production_details.multi_input_files) do
      local input_id = tostring(input_file and input_file.id or "")
      local item = by_stem_id[input_id]
      if item and not used[item] then
        ordered[#ordered + 1] = item
        used[item] = true
      end
    end
  end

  local rest = {}
  for _, item in ipairs(source) do
    if type(item) == "table" and not used[item] then
      rest[#rest + 1] = item
    end
  end
  table.sort(rest, function(a, b)
    local aa = string.lower(tostring(a.filename or a.entry or ""))
    local bb = string.lower(tostring(b.filename or b.entry or ""))
    if aa == bb then
      return tostring(a.filename or a.entry or "") < tostring(b.filename or b.entry or "")
    end
    return aa < bb
  end)

  for _, item in ipairs(rest) do
    ordered[#ordered + 1] = item
  end

  return ordered
end

local function build_windows_commands(archive_tool_path, zip_path, listing_path, extract_log_path, out_dir, audio_files)
  local quoted_7z = Util.shell_quote(archive_tool_path)
  local quoted_zip = Util.shell_quote(zip_path)
  local quoted_listing = Util.shell_quote(listing_path)
  local quoted_extract_log = Util.shell_quote(extract_log_path)

  local list_command = quoted_7z .. " l -slt " .. quoted_zip .. " > " .. quoted_listing .. " 2>&1"

  local entry_args = {}
  for _, item in ipairs(audio_files or {}) do
    entry_args[#entry_args + 1] = Util.shell_quote(item.entry)
  end
  local extract_command =
    quoted_7z .. " e " ..
    quoted_zip .. " " ..
    table.concat(entry_args, " ") .. " " ..
    "-o" .. Util.shell_quote(out_dir) .. " -y > " .. quoted_extract_log .. " 2>&1"

  return list_command, extract_command
end

local function build_posix_commands(archive_tool_path, zip_path, listing_path, extract_log_path, out_dir, audio_files)
  local quoted_unzip = Util.shell_quote(archive_tool_path)
  local quoted_zip = Util.shell_quote(zip_path)
  local quoted_listing = Util.shell_quote(listing_path)
  local quoted_extract_log = Util.shell_quote(extract_log_path)

  local list_command = quoted_unzip .. " -Z1 " .. quoted_zip .. " > " .. quoted_listing .. " 2>&1"

  local entry_args = {}
  for _, item in ipairs(audio_files or {}) do
    entry_args[#entry_args + 1] = Util.shell_quote(item.entry)
  end
  local extract_command =
    quoted_unzip .. " -j -o " ..
    quoted_zip .. " " ..
    table.concat(entry_args, " ") .. " " ..
    "-d " .. Util.shell_quote(out_dir) .. " > " .. quoted_extract_log .. " 2>&1"

  return list_command, extract_command
end

function ZipArchive.extract_audio_files(zip_path, out_dir)
  local input_path = Util.trim(zip_path)
  local output_dir = Util.trim(out_dir)
  local timeout_ms = tonumber(ZipArchive.settings.exec_timeout_ms) or 300000

  if input_path == "" then
    return nil, "zip_archive: zip_path must be a non-empty absolute path"
  end
  if output_dir == "" then
    return nil, "zip_archive: out_dir must be a non-empty absolute path"
  end
  if not is_absolute_path(input_path) then
    return nil, "zip_archive: zip_path must be an absolute path: " .. tostring(input_path)
  end
  if not is_absolute_path(output_dir) then
    return nil, "zip_archive: out_dir must be an absolute path: " .. tostring(output_dir)
  end
  if not r.file_exists(input_path) then
    return nil, "zip_archive: input ZIP file not found: " .. tostring(input_path)
  end

  local ok_out, out_err = Files.ensure_tmp_dir(output_dir)
  if not ok_out then
    return nil, "zip_archive: output directory is not writable: " .. tostring(out_err)
  end

  local archive_tool_path, archive_tool_err = nil, nil
  if Util.is_windows() then
    archive_tool_path = resolve_bundled_7z_path()
    if type(archive_tool_path) ~= "string" or archive_tool_path == "" or (not r.file_exists(archive_tool_path)) then
      return nil, "zip_archive: bundled 7z.exe not found: " .. tostring(archive_tool_path)
    end
  else
    archive_tool_path, archive_tool_err = resolve_posix_unzip_path(timeout_ms)
    if type(archive_tool_path) ~= "string" or archive_tool_path == "" then
      return nil, tostring(archive_tool_err or "zip_archive: POSIX unzip not found")
    end
  end

  local listing_path = make_listing_path(output_dir)
  local extract_log_path = make_extract_log_path(output_dir)
  local list_command = nil
  local extract_command = nil

  if Util.is_windows() then
    list_command = (select(1, build_windows_commands(archive_tool_path, input_path, listing_path, extract_log_path, output_dir, {})))
  else
    list_command = (select(1, build_posix_commands(archive_tool_path, input_path, listing_path, extract_log_path, output_dir, {})))
  end

  local function keep_or_cleanup_logs_on_failure(_include_extract_log)
    -- Reliability incidents showed that retained diagnostics are required for support.
    -- Do not delete archive logs or POSIX scripts on failures.
  end

  local warning_parts = {}
  local list_result = run_execprocess_command(list_command, timeout_ms, "list", listing_path)
  if not (list_result and list_result.ok) then
    keep_or_cleanup_logs_on_failure(false)
    return nil, build_stage_failure(archive_list_stage_label(), archive_tool_path, input_path, listing_path, list_result)
  end
  append_exec_warning(warning_parts, list_result)

  local listing_text, listing_size_or_err = Files.slurp_with_cap(listing_path, LOG_CAP_BYTES)
  if listing_text == nil then
    keep_or_cleanup_logs_on_failure(false)
    return nil, build_stage_failure(
      archive_list_stage_label(),
      archive_tool_path,
      input_path,
      listing_path,
      list_result,
      "Could not read listing file: " .. tostring(listing_size_or_err)
    )
  end
  append_posix_unzip_marker_warning(warning_parts, "list", listing_text)
  if tonumber(listing_size_or_err) == 0 then
    keep_or_cleanup_logs_on_failure(false)
    return nil, build_stage_failure(archive_list_stage_label(), archive_tool_path, input_path, listing_path, list_result, "Listing file is empty.")
  end

  local listing_entries = Util.is_windows()
    and ZipArchive.parse_7z_slt_listing(listing_text)
    or ZipArchive.parse_unzip_name_listing(listing_text)
  local audio_files, filter_err = ZipArchive.filter_audio_entries(listing_entries)
  if not audio_files then
    keep_or_cleanup_logs_on_failure(false)
    return nil, build_stage_failure(audio_entry_filter_stage_label(), archive_tool_path, input_path, listing_path, list_result, filter_err)
  end
  if #audio_files == 0 then
    keep_or_cleanup_logs_on_failure(false)
    return nil, build_stage_failure(audio_entry_filter_stage_label(), archive_tool_path, input_path, listing_path, list_result, "Archive contains no supported audio files.")
  end

  if Util.is_windows() then
    _, extract_command = build_windows_commands(archive_tool_path, input_path, listing_path, extract_log_path, output_dir, audio_files)
  else
    _, extract_command = build_posix_commands(archive_tool_path, input_path, listing_path, extract_log_path, output_dir, audio_files)
  end

  local extract_result = run_execprocess_command(extract_command, timeout_ms, "extract", extract_log_path)
  if not (extract_result and extract_result.ok) then
    keep_or_cleanup_logs_on_failure(true)
    return nil, build_stage_failure(archive_extract_stage_label(), archive_tool_path, input_path, extract_log_path, extract_result)
  end
  append_exec_warning(warning_parts, extract_result)

  local extract_log_text, extract_log_size_or_err = Files.slurp_with_cap(extract_log_path, LOG_CAP_BYTES)
  if extract_log_text == nil then
    keep_or_cleanup_logs_on_failure(true)
    return nil, build_stage_failure(
      archive_extract_stage_label(),
      archive_tool_path,
      input_path,
      extract_log_path,
      extract_result,
      "Could not read extract log: " .. tostring(extract_log_size_or_err)
    )
  end
  append_posix_unzip_marker_warning(warning_parts, "extract", extract_log_text)

  for _, item in ipairs(audio_files) do
    local local_path = Util.path_join(output_dir, item.filename)
    if not r.file_exists(local_path) then
      keep_or_cleanup_logs_on_failure(true)
      return nil, build_stage_failure(
        audio_extraction_verification_stage_label(),
        archive_tool_path,
        input_path,
        extract_log_path,
        extract_result,
        "Extracted audio file was not found: " .. tostring(local_path)
      )
    end
    item.path = local_path
    item.output_dir = output_dir
  end

  if has_warnings(warning_parts) then
    append_retained_diagnostics_warning(warning_parts, listing_path, extract_log_path, list_result.script_path, extract_result.script_path)
  else
    if ZipArchive.settings.delete_listing_on_success == true then
      cleanup_temp_file(listing_path, "listing file")
    end
    if ZipArchive.settings.delete_extract_log_on_success == true then
      cleanup_temp_file(extract_log_path, "extract log")
    end
    if ZipArchive.settings.delete_posix_scripts_on_success ~= false then
      cleanup_temp_file(list_result.script_path, "POSIX command script")
      cleanup_temp_file(extract_result.script_path, "POSIX command script")
    end
  end

  local warning_text = collect_warning_text(warning_parts)

  return {
    archive_path = input_path,
    output_dir = output_dir,
    archive_tool_path = archive_tool_path,
    listing_path = listing_path,
    extract_log_path = extract_log_path,
    list_script_path = list_result.script_path,
    extract_script_path = extract_result.script_path,
    list_result = list_result,
    extract_result = extract_result,
    warning_text = warning_text or "",
    warnings = warning_parts,
    audio_files = audio_files
  }, "zip_archive: extracted " .. tostring(#audio_files) .. " audio files" .. (warning_text and (" (" .. warning_text .. ")") or "")
end

return ZipArchive

