-- @noindex
-- Filesystem helper module for ReaScript projects.
-- Exported functions:
-- Files.path_normalize(path): normalize slash style and case for path comparisons.
-- Files.is_path_inside(root_path, target_path): check if target path is inside root path.
-- Files.get_dir_from_file_path(full_path_to_file): return parent directory from full file path.
-- Files.bump_to_unique_path(path): add numeric suffix while file already exists.
-- Files.build_safe_download_path(base_dir, file_name, prefix): build sanitized unique download path.
-- Files.write_file(path, text): write text (binary-safe mode) to a file.
-- Files.truncate_file(path): truncate file content to zero bytes.
-- Files.read_project_path(): return current Reaper project path or empty string.
-- Files.is_filesystem_safe_name(name): validate filename safety for common filesystem rules.
-- Files.remove_best_effort(path): legacy file-focused delete helper.
-- Files.remove_all_files_in_dir(dir): legacy non-recursive file delete helper.
-- Files.remove_dir_contents_keep_root(dir_path): recursively remove all contents but preserve root dir.
-- Files.remove_whole_dir_tree(dir_path): recursively remove a whole directory tree, including root dir.
-- Files.ensure_tmp_dir(dir): ensure temp directory exists and is writable.
-- Files.ensure_output_dir(full_output_path): ensure output directory exists and is writable.
-- Files.slurp_with_cap(path, max_bytes): read full file only when under byte cap.
-- Files.file_size(path): return file size in bytes or nil.
-- Files.read_tail(path, max_bytes): read last N bytes from file or nil on error.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules.Util")

local Files = {}

local function shell_command_ok(ok, why, code)
  if type(ok) == "number" then
    return ok == 0
  end
  if type(ok) == "boolean" then
    if ok == true then return true end
    if type(code) == "number" then
      return code == 0
    end
    return false
  end
  if type(code) == "number" then
    return code == 0
  end
  return false
end

local function run_shell_command(command)
  local cmd = tostring(command or "")
  if cmd == "" then
    return false, "empty shell command"
  end
  local ok, why, code = os.execute(cmd)
  if shell_command_ok(ok, why, code) then
    return true, nil
  end
  return false, "command failed: " .. cmd .. " | ok=" .. tostring(ok) .. " why=" .. tostring(why) .. " code=" .. tostring(code)
end

local function build_windows_cmd(command)
  local inner = tostring(command or "")
  return 'cmd /D /Q /C "' .. inner:gsub('"', '""') .. '"'
end

local function build_posix_cmd(command)
  return "/bin/sh -c " .. Util.shell_quote(tostring(command or ""))
end

local function quote_windows_cmd_arg(text)
  local s = tostring(text or "")
  s = s:gsub('"', '""')
  return '"' .. s .. '"'
end

local function run_platform_shell(command)
  if Util.is_windows() then
    return run_shell_command(build_windows_cmd(command))
  end
  return run_shell_command(build_posix_cmd(command))
end

local function directory_exists(path)
  local text = Util.trim(path)
  if text == "" then return false end
  if Util.is_windows() then
    local probe = text
    if probe:sub(-1) ~= "\\" and probe:sub(-1) ~= "/" then
      probe = probe .. "\\"
    end
    local ok = run_platform_shell("if exist " .. quote_windows_cmd_arg(probe) .. " (exit /b 0) else (exit /b 1)")
    return ok == true
  end
  local ok = run_platform_shell("test -d " .. Util.shell_quote(text))
  return ok == true
end

local function enumerate_files_shallow(dir_path)
  local items = {}
  r.EnumerateFiles(dir_path, -1)
  local idx = 0
  while true do
    local fname = r.EnumerateFiles(dir_path, idx)
    if not fname then break end
    items[#items + 1] = Util.path_join(dir_path, fname)
    idx = idx + 1
  end
  return items
end

local function enumerate_subdirs_shallow(dir_path)
  if type(r.EnumerateSubdirectories) ~= "function" then
    return nil, "EnumerateSubdirectories API is not available"
  end
  local items = {}
  r.EnumerateSubdirectories(dir_path, -1)
  local idx = 0
  while true do
    local name = r.EnumerateSubdirectories(dir_path, idx)
    if not name then break end
    items[#items + 1] = Util.path_join(dir_path, name)
    idx = idx + 1
  end
  return items, nil
end

local function make_cleanup_report(target_path, mode)
  return {
    target_path = tostring(target_path or ""),
    mode = tostring(mode or ""),
    status = "error",
    root_exists_after = false,
    removed_file_count = 0,
    removed_dir_count = 0,
    had_work = false,
    errors = {},
    summary = ""
  }
end

local function add_cleanup_error(report, path, kind, stage, message)
  local errors = report.errors or {}
  errors[#errors + 1] = {
    path = tostring(path or ""),
    kind = tostring(kind or "unknown"),
    stage = tostring(stage or "unknown"),
    message = tostring(message or "")
  }
  report.errors = errors
end

local function scan_dir_tree(dir_path, report)
  local stats = {
    file_count = 0,
    dir_count = 0,
    child_count = 0
  }

  local function walk(current_path)
    local files = enumerate_files_shallow(current_path)
    local subdirs, subdir_err = enumerate_subdirs_shallow(current_path)
    if not subdirs then
      add_cleanup_error(report, current_path, "directory", "scan", subdir_err)
      return false
    end

    stats.file_count = stats.file_count + #files
    stats.dir_count = stats.dir_count + #subdirs
    stats.child_count = stats.child_count + #files + #subdirs

    for i = 1, #subdirs do
      if not walk(subdirs[i]) then
        return false
      end
    end
    return true
  end

  local ok = walk(dir_path)
  return ok, stats
end

local function summarize_cleanup_report(report)
  local err_count = #(report.errors or {})
  if report.status == "noop" then
    report.summary =
      tostring(report.mode) .. " noop" ..
      " | files=" .. tostring(report.removed_file_count) ..
      " dirs=" .. tostring(report.removed_dir_count) ..
      " | root_exists_after=" .. tostring(report.root_exists_after)
    return
  end
  if report.status == "ok" then
    report.summary =
      tostring(report.mode) .. " ok" ..
      " | files=" .. tostring(report.removed_file_count) ..
      " dirs=" .. tostring(report.removed_dir_count) ..
      " | root_exists_after=" .. tostring(report.root_exists_after)
    return
  end
  local first_err = report.errors and report.errors[1]
  local first_msg = first_err and first_err.message or "unknown error"
  report.summary =
    tostring(report.mode) .. " error" ..
    " | files=" .. tostring(report.removed_file_count) ..
    " dirs=" .. tostring(report.removed_dir_count) ..
    " | errors=" .. tostring(err_count) ..
    " | first=" .. tostring(first_msg)
end

local function build_remove_whole_tree_command(path)
  if Util.is_windows() then
    local quoted = quote_windows_cmd_arg(path)
    return "rmdir /S /Q " .. quoted .. " >nul 2>nul"
  end
  local quoted = Util.shell_quote(path)
  return "rm -rf -- " .. quoted .. " >/dev/null 2>&1"
end

local function build_remove_contents_keep_root_command(path)
  if Util.is_windows() then
    local quoted = quote_windows_cmd_arg(path)
    return "rmdir /S /Q " .. quoted .. " >nul 2>nul && mkdir " .. quoted .. " >nul 2>nul"
  end
  local quoted = Util.shell_quote(path)
  return "rm -rf -- " .. quoted .. " >/dev/null 2>&1 && mkdir -p -- " .. quoted .. " >/dev/null 2>&1"
end

local function run_recursive_dir_cleanup(dir_path, mode)
  local target = Util.trim(dir_path)
  local report = make_cleanup_report(target, mode)

  if target == "" then
    add_cleanup_error(report, target, "path", "validate", "dir_path must be a non-empty string")
    summarize_cleanup_report(report)
    return false, report
  end

  if directory_exists(target) ~= true then
    if r.file_exists(target) == true then
      add_cleanup_error(report, target, "path", "validate", "target exists but is not a directory")
      summarize_cleanup_report(report)
      return false, report
    end
    report.status = "noop"
    report.root_exists_after = false
    summarize_cleanup_report(report)
    return true, report
  end

  local ok_scan, stats = scan_dir_tree(target, report)
  report.removed_file_count = tonumber(stats and stats.file_count) or 0
  report.removed_dir_count = tonumber(stats and stats.dir_count) or 0
  report.had_work = ((tonumber(stats and stats.child_count) or 0) > 0)
  if not ok_scan then
    report.root_exists_after = directory_exists(target) == true
    summarize_cleanup_report(report)
    return false, report
  end

  if mode == "contents_keep_root" and report.had_work ~= true then
    report.status = "noop"
    report.root_exists_after = true
    summarize_cleanup_report(report)
    return true, report
  end

  local command = (mode == "whole_tree")
    and build_remove_whole_tree_command(target)
    or build_remove_contents_keep_root_command(target)
  local ok_shell, shell_err = run_platform_shell(command)
  if not ok_shell then
    add_cleanup_error(report, target, "directory", "shell", shell_err)
  end

  local root_exists_after = directory_exists(target) == true
  report.root_exists_after = root_exists_after

  if mode == "contents_keep_root" then
    local ok_post_scan, post_stats = scan_dir_tree(target, report)
    if not ok_post_scan then
      summarize_cleanup_report(report)
      return false, report
    end
    local post_child_count = tonumber(post_stats and post_stats.child_count) or 0
    if ok_shell and root_exists_after and post_child_count == 0 then
      report.status = "ok"
      summarize_cleanup_report(report)
      return true, report
    end
    if not root_exists_after then
      add_cleanup_error(report, target, "directory", "verify", "root directory was not preserved")
    elseif post_child_count > 0 then
      add_cleanup_error(report, target, "directory", "verify", "directory still contains entries after cleanup")
    end
    summarize_cleanup_report(report)
    return false, report
  end

  if ok_shell and (root_exists_after ~= true) and r.file_exists(target) ~= true then
    if report.had_work ~= true then
      report.removed_dir_count = report.removed_dir_count + 1
    else
      report.removed_dir_count = report.removed_dir_count + 1
    end
    report.had_work = true
    report.status = "ok"
    summarize_cleanup_report(report)
    return true, report
  end

  if root_exists_after then
    add_cleanup_error(report, target, "directory", "verify", "root directory still exists after whole-tree cleanup")
  elseif r.file_exists(target) == true then
    add_cleanup_error(report, target, "path", "verify", "target path still exists after whole-tree cleanup")
  end
  summarize_cleanup_report(report)
  return false, report
end

-- Normalize path text to make prefix checks deterministic across OS path formats.
function Files.path_normalize(path)
  if type(path) ~= "string" or path == "" then return nil end
  local p = path:gsub("\\", "/")
  p = p:gsub("/+", "/")
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  if Util.mac ~= true then
    p = p:lower()
  end
  return p
end

-- Check whether target path is equal to or nested under root path.
function Files.is_path_inside(root_path, target_path)
  local root = Files.path_normalize(root_path)
  local target = Files.path_normalize(target_path)
  if not root or not target then return false end
  if target == root then return true end
  return target:sub(1, #root + 1) == (root .. "/")
end

-- Return parent directory for a full path to file.
function Files.get_dir_from_file_path(full_path_to_file)
  if type(full_path_to_file) ~= "string" then
    return nil, "full_path_to_file must be a string"
  end
  local text = Util.trim(full_path_to_file)
  if text == "" then
    return nil, "full_path_to_file must be a non-empty string"
  end
  local dir = text:match("^(.*)[/\\][^/\\]+$")
  if dir == nil then
    return nil, "path must include directory and file name"
  end
  if dir == "" then
    local first_ch = text:sub(1, 1)
    if first_ch == "/" then return "/", nil end
    if first_ch == "\\" then return "\\", nil end
    return nil, "cannot derive parent directory"
  end
  if dir:match("^[A-Za-z]:$") then
    dir = dir .. "\\"
  end
  return dir, nil
end

local function split_parent_and_file_name(path)
  local text = tostring(path or "")
  if text == "" then return nil, nil end

  local file_name = text:match("([^/\\]+)$")
  if not file_name or file_name == "" then
    return nil, nil
  end

  local parent_dir = text:match("^(.*)[/\\][^/\\]+$")
  if parent_dir == nil then
    return "", file_name
  end
  if parent_dir == "" then
    local first_ch = text:sub(1, 1)
    if first_ch == "/" or first_ch == "\\" then
      return first_ch, file_name
    end
    return "", file_name
  end
  if parent_dir:match("^[A-Za-z]:$") then
    parent_dir = parent_dir .. "\\"
  end
  return parent_dir, file_name
end

local function split_file_stem_and_extension(file_name)
  local stem, ext = tostring(file_name or ""):match("^(.*)(%.[^%.\\/]+)$")
  if stem and stem ~= "" then
    return stem, ext
  end
  return tostring(file_name or ""), ""
end

local function normalize_alloc_name(name)
  local text = tostring(name or "")
  if Util.is_windows() then
    return text:lower()
  end
  return text
end

local function collect_sibling_name_set(dir_path)
  local name_set = {}
  local scan_dir = tostring(dir_path or "")
  if scan_dir == "" then
    return name_set
  end

  if type(r.EnumerateFiles) == "function" then
    pcall(r.EnumerateFiles, scan_dir, -1)
    local idx = 0
    while true do
      local ok_enum, file_name = pcall(r.EnumerateFiles, scan_dir, idx)
      if not ok_enum or not file_name then break end
      name_set[normalize_alloc_name(file_name)] = true
      idx = idx + 1
    end
  end

  if type(r.EnumerateSubdirectories) == "function" then
    pcall(r.EnumerateSubdirectories, scan_dir, -1)
    local idx = 0
    while true do
      local ok_enum, dir_name = pcall(r.EnumerateSubdirectories, scan_dir, idx)
      if not ok_enum or not dir_name then break end
      name_set[normalize_alloc_name(dir_name)] = true
      idx = idx + 1
    end
  end

  return name_set
end

-- Build a non-colliding path by appending _N suffix before extension.
function Files.bump_to_unique_path(path)
  if type(path) ~= "string" or path == "" then return path end

  local parent_dir, file_name = split_parent_and_file_name(path)
  if not file_name or file_name == "" then
    return path
  end

  local alloc_scan_dir = parent_dir == "" and "." or parent_dir
  local sibling_name_set = collect_sibling_name_set(alloc_scan_dir)
  local file_key = normalize_alloc_name(file_name)
  if sibling_name_set[file_key] ~= true then
    return path
  end

  local stem, ext = split_file_stem_and_extension(file_name)
  local suffix = 1
  local candidate_name = stem .. "_" .. tostring(suffix) .. ext
  while sibling_name_set[normalize_alloc_name(candidate_name)] == true do
    suffix = suffix + 1
    candidate_name = stem .. "_" .. tostring(suffix) .. ext
  end

  if parent_dir == "" then
    return candidate_name
  end
  return Util.path_join(parent_dir, candidate_name)
end

-- Build a sanitized download path and auto-bump suffix when target already exists.
function Files.build_safe_download_path(base_dir, file_name, prefix)
  if type(base_dir) ~= "string" then
    return nil, "base_dir must be a non-empty string"
  end
  base_dir = Util.trim(base_dir)
  if base_dir == "" then
    return nil, "base_dir must be a non-empty string"
  end

  local safe_name = Util.sanitize_filename(file_name, "result.json", 255)
  if type(safe_name) ~= "string" or safe_name == "" then
    safe_name = "result.json"
  end

  local raw_prefix = prefix
  if raw_prefix == nil then raw_prefix = "downloaded_" end
  if type(raw_prefix) ~= "string" then raw_prefix = tostring(raw_prefix) end
  raw_prefix = Util.trim(raw_prefix)
  local safe_prefix
  if raw_prefix == "" then
    safe_prefix = "downloaded_"
  else
    safe_prefix = Util.sanitize_filename(raw_prefix, "downloaded_", 64)
    if safe_prefix == "" then safe_prefix = "downloaded_" end
  end

  local candidate = Util.path_join(base_dir, safe_prefix .. safe_name)
  local unique_path = Files.bump_to_unique_path(candidate)
  return unique_path, nil
end

-- Write text to file in binary mode to preserve exact bytes.
function Files.write_file(path, text)
  if type(path) ~= "string" or path == "" then
    return false, "missing path"
  end
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(tostring(text or ""))
  f:close()
  return true
end

-- Truncate an existing file (or create empty file) at a path.
function Files.truncate_file(path)
  if type(path) ~= "string" or path == "" then return false, "missing path" end
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write("")
  f:close()
  return true
end

-- Read the current project's effective recording path from REAPER.
function Files.read_project_path()
  local proj_path = r.GetProjectPathEx(0)
  return proj_path or ""
end

-- Validate that filename does not include disallowed characters or trailing space/dot.
function Files.is_filesystem_safe_name(name)
  if type(name) ~= "string" then return false end
  if name:match("^%s*$") then return false end
  if name:find("[%c%:%*%?%\"%<%>%|\\/]", 1) then return false end
  if name:match("[%s%.]+$") then return false end
  return true
end

-- Try to remove file; if direct delete fails, truncate and retry once.
function Files.remove_best_effort(path)
  if type(path) ~= "string" or path == "" then
    return false, "missing path"
  end

  local remove_success, remove_err = os.remove(path)
  if not remove_success then
    local f, open_err = io.open(path, "wb")
    if f then
      f:write([===[AB0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=0-=BA]===])
      f:close()
      local ok2, why2 = os.remove(path)
      if ok2 then
        return true, "removed successfully after truncating file!"
      end
      return false, "failed to remove even after truncating! Initial remove err: "
        .. tostring(remove_err or "none")
        .. "; 2nd remove err: "
        .. tostring(why2 or "none")
    end
    return false, "likely no access to path at all! Initial remove err: "
      .. tostring(remove_err or "none")
      .. "; open err: "
      .. tostring(open_err or "none")
  end
  return true, "removed successfully!"
end

-- Remove all files in a directory (ignores subdirectories).
function Files.remove_all_files_in_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return false, "no dir provided!"
  end

  local dir_path = dir
  r.EnumerateFiles(dir_path, -1) -- reread to avoid stale cache issues
  if r.EnumerateFiles(dir_path, 0) == nil then
    return false, "Folder empty, or invalid path: " .. dir_path
  end

  local i = 0
  local table_of_files = {}
  local at_least_one_file = false
  while true do
    local fname = r.EnumerateFiles(dir_path, i)
    if not fname then
      break
    end
    local full_fname_with_path = Util.path_join(dir_path, fname)
    table.insert(table_of_files, full_fname_with_path)
    at_least_one_file = true
    i = i + 1
  end

  if not at_least_one_file then
    return false, "No files to delete in dir: " .. dir_path
  end

  local table_of_errors = {}
  local at_least_one_file_removed = false
  for j = 1, #table_of_files do
    local fpath_to_remove_file = table_of_files[j]
    local ok, err = Files.remove_best_effort(fpath_to_remove_file)
    if not ok then
      table.insert(table_of_errors, "Failed to remove file: " .. fpath_to_remove_file .. " Error: " .. (err or "unknown"))
    else
      at_least_one_file_removed = true
    end
  end

  local big_err_msg
  for k = 1, #table_of_errors do
    if big_err_msg == nil then big_err_msg = "" end
    big_err_msg = big_err_msg .. table_of_errors[k] .. "; "
  end

  if at_least_one_file_removed then
    if #table_of_errors > 0 then
      return false, "Some files failed to be removed: " .. (big_err_msg or "no info on errors!")
    end
    return true, "All files removed successfully!"
  end

  return false, "No files were removed! Errors: " .. (big_err_msg or "no info on errors!")
end

-- Recursively remove all directory contents while keeping the root directory.
-- Returns: ok_boolean, report_table
function Files.remove_dir_contents_keep_root(dir_path)
  return run_recursive_dir_cleanup(dir_path, "contents_keep_root")
end

-- Recursively remove a whole directory tree, including the root directory.
-- Returns: ok_boolean, report_table
function Files.remove_whole_dir_tree(dir_path)
  return run_recursive_dir_cleanup(dir_path, "whole_tree")
end

-- Internal helper: ensure directory exists and passes write/delete probe.
local function ensure_writable_dir(dir, label)
  if type(dir) ~= "string" or dir == "" then
    return false, "missing " .. label
  end

  r.RecursiveCreateDirectory(dir, 0)
  local test_path = Util.path_join(dir, "._write_test.tmp")
  local ok, err = Files.write_file(test_path, "test")
  if not ok then
    return false, "Cannot write to " .. label .. ": " .. tostring(err or "unknown IO error")
  end

  local remove_ok, remove_err = os.remove(test_path)
  if not remove_ok then
    Util.msg("Cannot delete test file from " .. label .. "! Not secure!", 3, "box")
    return false, "SECURITY risk!! Cannot delete from " .. label .. ": " .. tostring(remove_err or "unknown IO error")
  end

  return true
end

-- Ensure temp directory exists and is writable.
function Files.ensure_tmp_dir(dir)
  return ensure_writable_dir(dir, "temp dir")
end

-- Ensure output directory exists and is writable; return normalized success tuple.
function Files.ensure_output_dir(full_output_path)
  local ok, err = ensure_writable_dir(full_output_path, "output folder")
  if not ok then return false, err end
  return true, full_output_path
end

-- Read entire file with optional size cap to prevent large memory usage.
function Files.slurp_with_cap(path, max_bytes)
  if type(path) ~= "string" or path == "" then
    return nil, "path must be a non-empty string"
  end
  if max_bytes ~= nil and type(max_bytes) ~= "number" then
    return nil, "max_bytes must be a number or nil"
  end
  if type(max_bytes) == "number" and max_bytes < 0 then
    return nil, "max_bytes must be >= 0"
  end

  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "open failed: " .. tostring(open_err)
  end

  local size, seek_err = f:seek("end")
  if not size then
    f:close()
    return nil, "cannot determine size: " .. tostring(seek_err or "unknown")
  end

  f:seek("set", 0)
  if max_bytes and size > max_bytes then
    f:close()
    return nil, string.format("file too large: %d bytes (limit %d)", size, max_bytes)
  end

  local data, read_err = f:read("*a")
  if not data then
    f:close()
    return nil, "read failed: " .. tostring(read_err or "unknown")
  end
  f:close()
  return data, size
end

-- Return file size in bytes, or nil when unavailable.
function Files.file_size(path)
  if type(path) ~= "string" or path == "" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- Read the last max_bytes bytes from a file.
function Files.read_tail(path, max_bytes)
  if type(path) ~= "string" or path == "" then return nil end
  local limit = tonumber(max_bytes) or 0
  if limit < 0 then return nil end

  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  if not size then
    f:close()
    return nil
  end

  local start = math.max(0, size - limit)
  f:seek("set", start)
  local data = f:read("*a")
  f:close()
  return data
end

return Files

