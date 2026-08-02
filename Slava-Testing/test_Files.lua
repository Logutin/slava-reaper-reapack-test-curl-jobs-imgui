-- @noindex
-- Reaper-hosted interactive tester for modules.Files.
-- Mirrors test_Util.lua structure: runtime guards, package.path handling,
-- ReaImGui loop, and restored Util settings on exit.

if not reaper then
  error("This script must run inside Reaper (missing global 'reaper').")
end

local r = reaper

if not r.ImGui_CreateContext then
  r.MB("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository.", "Error", 0)
  return false
end

local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])")
if not script_path then
  r.MB("Failed to get script path!", "Error", 0)
  return
end

-- Two-stage package.path loading:
-- 1) local project modules
-- 2) ReaImGui builtin module
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

-- Capture original Util settings so test changes are temporary per run.
local old_messaging_level = Util.messaging_level
local old_msg_to_log_file = Util.msg_to_log_file
local old_log_level_override = Util.log_level_override
local old_full_path_to_log_file = Util.full_path_to_log_file
local old_tmp_dir = Util.tmp_dir
local old_log_file_name = Util.log_file_name

local function restore_state()
  package.path = old_package_path
  Util.messaging_level = old_messaging_level
  Util.msg_to_log_file = old_msg_to_log_file
  Util.log_level_override = old_log_level_override
  Util.full_path_to_log_file = old_full_path_to_log_file
  Util.tmp_dir = old_tmp_dir
  Util.log_file_name = old_log_file_name
end

r.atexit(restore_state)

local sandbox_root = Util.path_join(r.GetResourcePath(), "Data")
sandbox_root = Util.path_join(sandbox_root, "Files_Module_Test")
sandbox_root = Util.path_join(sandbox_root, "tmp")
r.RecursiveCreateDirectory(sandbox_root, 0)

local function sync_logger_with_sandbox()
  Util.tmp_dir = sandbox_root
  -- Reset cached path because tmp_dir may have changed.
  Util.full_path_to_log_file = nil
end

sync_logger_with_sandbox()
Util.log_file_name = "test_File_log"

local test_file_name = "sample_io.txt"
local output_dir_name = "output_under_test"
local test_file_path = Util.path_join(sandbox_root, test_file_name)
local output_dir_path = Util.path_join(sandbox_root, output_dir_name)
local sample_text = "Files tester payload\nCreated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\nASCII text only.\n"
local safe_name_input = "safe_name_01"
local safe_name_expected = true
local max_bytes_input = "128"
local tail_bytes_input = "16"
local generic_path_input = r.GetResourcePath() or ""
local confirm_destructive = false

local last_status_text = "Ready to test sandboxed file operations."
local rolling_log_lines = {}
local log_max_lines = 300

local function rebuild_derived_paths()
  test_file_path = Util.path_join(sandbox_root, test_file_name)
  output_dir_path = Util.path_join(sandbox_root, output_dir_name)
  sync_logger_with_sandbox()
end

local function add_log_line(line)
  table.insert(rolling_log_lines, line)
  if #rolling_log_lines > log_max_lines then
    table.remove(rolling_log_lines, 1)
  end
end

local function log_result(test_id, passed, details)
  local status = passed and "PASS" or "FAIL"
  local detail = tostring(details or "")
  local line = os.date("%H:%M:%S") .. " [" .. status .. "] " .. tostring(test_id) .. " - " .. detail
  last_status_text = line
  add_log_line(line)
  Util.msg(line, passed and 1 or 2)
end

local function format_cleanup_report(report)
  local data = type(report) == "table" and report or {}
  return
    "status=" .. tostring(data.status or "") ..
    "; files=" .. tostring(data.removed_file_count or 0) ..
    "; dirs=" .. tostring(data.removed_dir_count or 0) ..
    "; root_exists_after=" .. tostring(data.root_exists_after) ..
    "; had_work=" .. tostring(data.had_work) ..
    "; errors=" .. tostring(#(data.errors or {})) ..
    "; summary=" .. tostring(data.summary or "")
end

local function log_step(test_id, message, importance)
  local line = os.date("%H:%M:%S") .. " [STEP] " .. tostring(test_id) .. " - " .. tostring(message or "")
  add_log_line(line)
  Util.msg(line, importance or 1)
end

local function is_inside_sandbox(path)
  return Files.is_path_inside(sandbox_root, path)
end

local function guard_mutating_path(path)
  log_step("guard_mutating_path", "Checking sandbox scope for path: " .. tostring(path))
  if type(path) ~= "string" or path == "" then
    log_step("guard_mutating_path", "Blocked: missing path", 2)
    return false, "missing path"
  end
  if not is_inside_sandbox(path) then
    log_step("guard_mutating_path", "Blocked: outside sandbox path", 2)
    return false, "path outside sandbox: " .. tostring(path)
  end
  log_step("guard_mutating_path", "Path accepted")
  return true
end

local function guard_destructive_path(path)
  log_step("guard_destructive_path", "Checking destructive guard for path: " .. tostring(path))
  local ok, err = guard_mutating_path(path)
  if not ok then return false, err end
  if not confirm_destructive then
    log_step("guard_destructive_path", "Blocked: confirmation checkbox is disabled", 2)
    return false, "confirmation checkbox is not enabled"
  end
  log_step("guard_destructive_path", "Destructive path accepted")
  return true
end

local function ensure_sample_file()
  log_step("ensure_sample_file", "Attempt to ensure temp dir: " .. tostring(sandbox_root))
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(sandbox_root)
  if not ok_tmp then
    log_step("ensure_sample_file", "Failed ensuring temp dir: " .. tostring(err_tmp), 2)
    return false, "ensure_tmp_dir failed: " .. tostring(err_tmp)
  end
  log_step("ensure_sample_file", "Success ensuring temp dir")
  log_step("ensure_sample_file", "Attempt to write sample file: " .. tostring(test_file_path))
  local ok_write, err_write = Files.write_file(test_file_path, sample_text)
  if not ok_write then
    log_step("ensure_sample_file", "Failed writing sample file: " .. tostring(err_write), 2)
    return false, "write_file failed: " .. tostring(err_write)
  end
  log_step("ensure_sample_file", "Success writing sample file")
  return true
end

local function build_nested_fixture_paths(label)
  local root = Util.path_join(sandbox_root, tostring(label or "nested_fixture"))
  local alpha = Util.path_join(root, "alpha")
  local beta = Util.path_join(root, "beta")
  local gamma = Util.path_join(alpha, "gamma")
  return {
    root = root,
    alpha = alpha,
    beta = beta,
    gamma = gamma,
    root_file = Util.path_join(root, "root.txt"),
    alpha_file = Util.path_join(alpha, "alpha.txt"),
    gamma_file = Util.path_join(gamma, "gamma.txt"),
    beta_file = Util.path_join(beta, "beta.txt")
  }
end

local function ensure_nested_fixture(label)
  local p = build_nested_fixture_paths(label)
  local ok_guard, guard_err = guard_mutating_path(p.root)
  if not ok_guard then
    return false, guard_err, p
  end

  local dirs = { p.root, p.alpha, p.beta, p.gamma }
  for i = 1, #dirs do
    local ok_dir, dir_err = Files.ensure_tmp_dir(dirs[i])
    if not ok_dir then
      return false, "ensure_tmp_dir failed for " .. tostring(dirs[i]) .. ": " .. tostring(dir_err), p
    end
  end

  local writes = {
    { p.root_file, "root" },
    { p.alpha_file, "alpha" },
    { p.gamma_file, "gamma" },
    { p.beta_file, "beta" }
  }
  for i = 1, #writes do
    local ok_write, write_err = Files.write_file(writes[i][1], writes[i][2])
    if not ok_write then
      return false, "write_file failed for " .. tostring(writes[i][1]) .. ": " .. tostring(write_err), p
    end
  end

  return true, nil, p
end

local function count_files_shallow(dir_path)
  local count = 0
  r.EnumerateFiles(dir_path, -1)
  while r.EnumerateFiles(dir_path, count) do
    count = count + 1
  end
  return count
end

local function count_subdirs_shallow(dir_path)
  if type(r.EnumerateSubdirectories) ~= "function" then
    return 0
  end
  local count = 0
  r.EnumerateSubdirectories(dir_path, -1)
  while r.EnumerateSubdirectories(dir_path, count) do
    count = count + 1
  end
  return count
end

local function run_bump_to_unique_path_test()
  log_step("bump_to_unique_path", "Starting test")
  local stamp = tostring(os.time())
  local file_probe = Util.path_join(sandbox_root, "bump_file_" .. stamp .. ".txt")
  local dir_probe = Util.path_join(sandbox_root, "bump_dir_" .. stamp)

  local ok_file_guard, file_guard_err = guard_mutating_path(file_probe)
  if not ok_file_guard then
    log_result("bump_to_unique_path", false, file_guard_err)
    return
  end
  local ok_dir_guard, dir_guard_err = guard_mutating_path(dir_probe)
  if not ok_dir_guard then
    log_result("bump_to_unique_path", false, dir_guard_err)
    return
  end

  local ok_tmp, tmp_err = Files.ensure_tmp_dir(sandbox_root)
  if not ok_tmp then
    log_result("bump_to_unique_path", false, "ensure_tmp_dir failed: " .. tostring(tmp_err))
    return
  end

  local ok_write, write_err = Files.write_file(file_probe, sample_text)
  if not ok_write then
    log_result("bump_to_unique_path", false, "write_file failed: " .. tostring(write_err))
    return
  end
  local ok_dir, dir_err = Files.ensure_tmp_dir(dir_probe)
  if not ok_dir then
    log_result("bump_to_unique_path", false, "ensure_tmp_dir for directory probe failed: " .. tostring(dir_err))
    return
  end

  log_step("bump_to_unique_path", "Attempt to compute unique file path for: " .. tostring(file_probe))
  local file_candidate = Files.bump_to_unique_path(file_probe)
  log_step("bump_to_unique_path", "Computed file candidate: " .. tostring(file_candidate))

  log_step("bump_to_unique_path", "Attempt to compute unique directory path for: " .. tostring(dir_probe))
  local dir_candidate = Files.bump_to_unique_path(dir_probe)
  log_step("bump_to_unique_path", "Computed directory candidate: " .. tostring(dir_candidate))

  local passed =
    type(file_candidate) == "string" and
    type(dir_candidate) == "string" and
    file_candidate == file_probe:gsub("%.txt$", "_1.txt") and
    dir_candidate == (dir_probe .. "_1")

  log_result(
    "bump_to_unique_path",
    passed,
    "file_input=" .. tostring(file_probe) ..
    "; file_candidate=" .. tostring(file_candidate) ..
    "; dir_input=" .. tostring(dir_probe) ..
    "; dir_candidate=" .. tostring(dir_candidate)
  )
end

local function run_read_project_path_test()
  log_step("read_project_path", "Attempt to read project path")
  local p = Files.read_project_path()
  log_step("read_project_path", "Read project path: " .. tostring(p))
  local passed = type(p) == "string"
  log_result("read_project_path", passed, "value=" .. tostring(p))
end

local function run_project_dir_safety_test()
  log_step("project_dir_safety", "Attempt to validate project path safety")
  local project_path = Files.read_project_path()
  if not project_path or project_path == "" then
    log_step("project_dir_safety", "Project path unavailable (unsaved project)", 2)
    log_result("project_dir_safety", false, "Project path is empty. Save project first.")
    return
  end

  local has_non_ascii = Util.has_non_ascii(project_path)
  local has_quoting_risk = Util.has_quoting_risk(project_path)
  local passed = (not has_non_ascii) and (not has_quoting_risk)

  log_step(
    "project_dir_safety",
    "Computed safety flags: non_ascii=" .. tostring(has_non_ascii) .. ", quoting_risk=" .. tostring(has_quoting_risk),
    passed and 1 or 2
  )
  log_result(
    "project_dir_safety",
    passed,
    "path=" .. tostring(project_path) ..
      "; has_non_ascii=" .. tostring(has_non_ascii) ..
      "; has_quoting_risk=" .. tostring(has_quoting_risk)
  )
end

local function run_is_filesystem_safe_name_test()
  log_step("is_filesystem_safe_name", "Attempt to validate name: " .. tostring(safe_name_input))
  local got = Files.is_filesystem_safe_name(safe_name_input)
  log_step("is_filesystem_safe_name", "Validation result: " .. tostring(got))
  local passed = (type(got) == "boolean") and (got == safe_name_expected)
  log_result(
    "is_filesystem_safe_name",
    passed,
    "name=" .. tostring(safe_name_input) .. "; expected=" .. tostring(safe_name_expected) .. "; got=" .. tostring(got)
  )
end

local function run_write_file_test()
  log_step("write_file", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_mutating_path(test_file_path)
  if not ok_guard then
    log_result("write_file", false, guard_err)
    return
  end
  log_step("write_file", "Attempt to ensure tmp dir: " .. tostring(sandbox_root))
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(sandbox_root)
  if not ok_tmp then
    log_result("write_file", false, "ensure_tmp_dir failed: " .. tostring(err_tmp))
    return
  end
  log_step("write_file", "Success ensuring tmp dir")
  log_step("write_file", "Attempt to write file")
  local ok, err = Files.write_file(test_file_path, sample_text)
  log_step("write_file", ok and "Success writing file" or ("Failed writing file: " .. tostring(err)), ok and 1 or 2)
  local exists = r.file_exists(test_file_path) == true
  local passed = ok and exists
  log_result("write_file", passed, "ok=" .. tostring(ok) .. "; exists=" .. tostring(exists) .. "; err=" .. tostring(err))
end

local function run_truncate_file_test()
  log_step("truncate_file", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_destructive_path(test_file_path)
  if not ok_guard then
    log_result("truncate_file", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("truncate_file", false, sample_err)
    return
  end
  log_step("truncate_file", "Attempt to truncate file")
  local ok, err = Files.truncate_file(test_file_path)
  log_step("truncate_file", ok and "Success truncating file" or ("Failed truncating file: " .. tostring(err)), ok and 1 or 2)
  local sz = Files.file_size(test_file_path)
  local passed = ok and sz == 0
  log_result("truncate_file", passed, "ok=" .. tostring(ok) .. "; size=" .. tostring(sz) .. "; err=" .. tostring(err))
end

local function run_file_size_test()
  log_step("file_size", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_mutating_path(test_file_path)
  if not ok_guard then
    log_result("file_size", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("file_size", false, sample_err)
    return
  end
  log_step("file_size", "Attempt to read file size")
  local sz = Files.file_size(test_file_path)
  log_step("file_size", "Read size result: " .. tostring(sz))
  local passed = type(sz) == "number" and sz >= 0
  log_result("file_size", passed, "size=" .. tostring(sz))
end

local function run_read_tail_test()
  log_step("read_tail", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_mutating_path(test_file_path)
  if not ok_guard then
    log_result("read_tail", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("read_tail", false, sample_err)
    return
  end
  local tail_bytes = Util.parse_int(tail_bytes_input, 16, 0)
  local tail = Files.read_tail(test_file_path, tail_bytes)
  local expected
  if tail_bytes <= 0 then
    expected = ""
  else
    local start = math.max(1, #sample_text - tail_bytes + 1)
    expected = sample_text:sub(start)
  end
  log_step("read_tail", "Attempt to read tail bytes: " .. tostring(tail_bytes))
  log_step("read_tail", "Tail read result length: " .. tostring(type(tail) == "string" and #tail or -1))
  local passed = type(tail) == "string" and tail == expected
  log_result(
    "read_tail",
    passed,
    "bytes=" .. tostring(tail_bytes) .. "; got_len=" .. tostring(type(tail) == "string" and #tail or -1)
  )
end

local function run_slurp_with_cap_test()
  log_step("slurp_with_cap", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_mutating_path(test_file_path)
  if not ok_guard then
    log_result("slurp_with_cap", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("slurp_with_cap", false, sample_err)
    return
  end

  local success_cap_input = Util.parse_int(max_bytes_input, 128, 0)
  local text_len = #sample_text
  local fail_cap = math.max(0, text_len - 1)
  local success_cap = math.max(success_cap_input, text_len)

  log_step("slurp_with_cap", "Attempt with fail cap: " .. tostring(fail_cap))
  local small_data, small_err = Files.slurp_with_cap(test_file_path, fail_cap)
  log_step("slurp_with_cap", "Attempt with success cap: " .. tostring(success_cap))
  local big_data, big_size = Files.slurp_with_cap(test_file_path, success_cap)
  local passed =
    (small_data == nil) and
    (type(small_err) == "string") and
    (type(big_data) == "string") and
    (big_data == sample_text) and
    (big_size == text_len)

  log_result(
    "slurp_with_cap",
    passed,
    "fail_cap=" .. tostring(fail_cap) .. "; success_cap=" .. tostring(success_cap) ..
      "; small_err=" .. tostring(small_err) .. "; big_size=" .. tostring(big_size)
  )
end

local function run_ensure_tmp_dir_test()
  log_step("ensure_tmp_dir", "Attempt to ensure sandbox dir: " .. tostring(sandbox_root))
  local ok_guard, guard_err = guard_mutating_path(sandbox_root)
  if not ok_guard then
    log_result("ensure_tmp_dir", false, guard_err)
    return
  end
  local ok, err = Files.ensure_tmp_dir(sandbox_root)
  log_step("ensure_tmp_dir", ok and "Success ensuring tmp dir" or ("Failed ensuring tmp dir: " .. tostring(err)), ok and 1 or 2)
  log_result("ensure_tmp_dir", ok == true, "ok=" .. tostring(ok) .. "; err=" .. tostring(err))
end

local function run_ensure_output_dir_test()
  log_step("ensure_output_dir", "Attempt to ensure output dir: " .. tostring(output_dir_path))
  local ok_guard, guard_err = guard_mutating_path(output_dir_path)
  if not ok_guard then
    log_result("ensure_output_dir", false, guard_err)
    return
  end
  local ok, out_or_err = Files.ensure_output_dir(output_dir_path)
  log_step("ensure_output_dir", ok and "Success ensuring output dir" or ("Failed ensuring output dir: " .. tostring(out_or_err)), ok and 1 or 2)
  local passed = (ok == true) and (out_or_err == output_dir_path)
  log_result(
    "ensure_output_dir",
    passed,
    "ok=" .. tostring(ok) .. "; returned=" .. tostring(out_or_err) .. "; path=" .. tostring(output_dir_path)
  )
end

local function run_remove_best_effort_test()
  log_step("remove_best_effort", "Starting test for path: " .. tostring(test_file_path))
  local ok_guard, guard_err = guard_destructive_path(test_file_path)
  if not ok_guard then
    log_result("remove_best_effort", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("remove_best_effort", false, sample_err)
    return
  end
  log_step("remove_best_effort", "Attempt to remove file")
  local ok, err = Files.remove_best_effort(test_file_path)
  log_step("remove_best_effort", ok and "Success removing file" or ("Failed removing file: " .. tostring(err)), ok and 1 or 2)
  local exists = r.file_exists(test_file_path) == true
  local passed = (ok == true) and (not exists)
  log_result("remove_best_effort", passed, "ok=" .. tostring(ok) .. "; exists_after=" .. tostring(exists) .. "; err=" .. tostring(err))
end

local function run_remove_all_files_in_dir_test()
  log_step("remove_all_files_in_dir", "Starting test for dir: " .. tostring(sandbox_root))
  local ok_guard, guard_err = guard_destructive_path(sandbox_root)
  if not ok_guard then
    log_result("remove_all_files_in_dir", false, guard_err)
    return
  end
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(sandbox_root)
  if not ok_tmp then
    log_result("remove_all_files_in_dir", false, "ensure_tmp_dir failed: " .. tostring(err_tmp))
    return
  end

  local p1 = Util.path_join(sandbox_root, "rm_all_test_1.txt")
  local p2 = Util.path_join(sandbox_root, "rm_all_test_2.txt")
  log_step("remove_all_files_in_dir", "Attempt to create setup files")
  local ok_w1 = select(1, Files.write_file(p1, "a"))
  local ok_w2 = select(1, Files.write_file(p2, "b"))
  if not (ok_w1 and ok_w2) then
    log_step("remove_all_files_in_dir", "Failed creating setup files", 2)
    log_result("remove_all_files_in_dir", false, "failed to create setup files")
    return
  end

  log_step("remove_all_files_in_dir", "Attempt to remove all files in dir")
  local ok, msg = Files.remove_all_files_in_dir(sandbox_root)
  log_step("remove_all_files_in_dir", ok and "Success removing files" or ("Failed removing files: " .. tostring(msg)), ok and 1 or 2)
  local first = r.EnumerateFiles(sandbox_root, 0)
  local passed = (ok == true) and (first == nil)
  log_result("remove_all_files_in_dir", passed, "ok=" .. tostring(ok) .. "; first_file_after=" .. tostring(first) .. "; msg=" .. tostring(msg))
end

local function run_remove_dir_contents_keep_root_test()
  log_step("remove_dir_contents_keep_root", "Starting nested keep-root cleanup test")
  local fixture_ok, fixture_err, p = ensure_nested_fixture("keep_root_fixture")
  if not fixture_ok then
    log_result("remove_dir_contents_keep_root", false, tostring(fixture_err))
    return
  end

  local ok_guard, guard_err = guard_destructive_path(p.root)
  if not ok_guard then
    log_result("remove_dir_contents_keep_root", false, guard_err)
    return
  end

  local ok, report = Files.remove_dir_contents_keep_root(p.root)
  local passed =
    ok == true and
    type(report) == "table" and
    report.mode == "contents_keep_root" and
    report.status == "ok" and
    report.root_exists_after == true and
    report.removed_file_count == 4 and
    report.removed_dir_count == 3 and
    count_files_shallow(p.root) == 0 and
    count_subdirs_shallow(p.root) == 0
  log_result("remove_dir_contents_keep_root", passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local function run_remove_whole_dir_tree_test()
  log_step("remove_whole_dir_tree", "Starting nested whole-tree cleanup test")
  local fixture_ok, fixture_err, p = ensure_nested_fixture("whole_tree_fixture")
  if not fixture_ok then
    log_result("remove_whole_dir_tree", false, tostring(fixture_err))
    return
  end

  local ok_guard, guard_err = guard_destructive_path(p.root)
  if not ok_guard then
    log_result("remove_whole_dir_tree", false, guard_err)
    return
  end

  local ok, report = Files.remove_whole_dir_tree(p.root)
  local passed =
    ok == true and
    type(report) == "table" and
    report.mode == "whole_tree" and
    report.status == "ok" and
    report.root_exists_after == false and
    report.removed_file_count == 4 and
    report.removed_dir_count == 4 and
    r.file_exists(p.root) ~= true
  log_result("remove_whole_dir_tree", passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local function run_remove_dir_contents_keep_root_empty_test()
  local test_id = "remove_dir_contents_keep_root_empty"
  local target = Util.path_join(sandbox_root, "empty_keep_root_fixture")
  log_step(test_id, "Starting empty-directory keep-root test")
  local ok_guard, guard_err = guard_destructive_path(target)
  if not ok_guard then
    log_result(test_id, false, guard_err)
    return
  end

  local ok_dir, dir_err = Files.ensure_tmp_dir(target)
  if not ok_dir then
    log_result(test_id, false, "ensure_tmp_dir failed: " .. tostring(dir_err))
    return
  end

  local ok, report = Files.remove_dir_contents_keep_root(target)
  local passed =
    ok == true and
    type(report) == "table" and
    report.status == "noop" and
    report.root_exists_after == true and
    report.removed_file_count == 0 and
    report.removed_dir_count == 0
  log_result(test_id, passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local function run_remove_whole_dir_tree_missing_test()
  local test_id = "remove_whole_dir_tree_missing"
  local target = Util.path_join(sandbox_root, "missing_whole_tree_fixture")
  log_step(test_id, "Starting missing-directory whole-tree test")
  local ok_guard, guard_err = guard_destructive_path(target)
  if not ok_guard then
    log_result(test_id, false, guard_err)
    return
  end

  local ok, report = Files.remove_whole_dir_tree(target)
  local passed =
    ok == true and
    type(report) == "table" and
    report.status == "noop" and
    report.root_exists_after == false and
    report.removed_file_count == 0 and
    report.removed_dir_count == 0
  log_result(test_id, passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local function run_manual_cleanup()
  log_step("cleanup_sandbox", "Attempt to cleanup sandbox: " .. tostring(sandbox_root))
  local ok_guard, guard_err = guard_destructive_path(sandbox_root)
  if not ok_guard then
    log_result("cleanup_sandbox", false, guard_err)
    return
  end
  local ok, report = Files.remove_dir_contents_keep_root(sandbox_root)
  log_step("cleanup_sandbox", ok and "Cleanup completed" or ("Cleanup returned: " .. tostring(report and report.summary)), ok and 1 or 2)
  local passed = ok == true and type(report) == "table" and report.root_exists_after == true
  log_result("cleanup_sandbox", passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local function run_negative_invalid_paths_test()
  log_step("NEG invalid/missing path", "Starting invalid/missing path checks")
  local checks = {}
  checks[#checks + 1] = (select(1, Files.write_file("", "x")) == false)
  checks[#checks + 1] = (select(1, Files.truncate_file("")) == false)
  checks[#checks + 1] = (Files.file_size("") == nil)
  checks[#checks + 1] = (Files.read_tail("", 16) == nil)
  checks[#checks + 1] = (select(1, Files.remove_best_effort("")) == false)
  checks[#checks + 1] = (select(1, Files.ensure_tmp_dir("")) == false)
  checks[#checks + 1] = (select(1, Files.ensure_output_dir("")) == false)
  checks[#checks + 1] = (select(1, Files.slurp_with_cap("", 10)) == nil)
  checks[#checks + 1] = (select(1, Files.remove_dir_contents_keep_root("")) == false)
  checks[#checks + 1] = (select(1, Files.remove_whole_dir_tree("")) == false)

  local passed = true
  for i = 1, #checks do
    if not checks[i] then
      passed = false
      break
    end
  end
  log_result("NEG invalid/missing path", passed, "checks=" .. tostring(#checks))
end

local function run_negative_slurp_too_small_test()
  log_step("NEG slurp too small", "Starting too-small cap check")
  local ok_guard, guard_err = guard_mutating_path(test_file_path)
  if not ok_guard then
    log_result("NEG slurp too small", false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result("NEG slurp too small", false, sample_err)
    return
  end
  local cap = math.max(0, #sample_text - 1)
  log_step("NEG slurp too small", "Attempt slurp with cap: " .. tostring(cap))
  local data, err = Files.slurp_with_cap(test_file_path, cap)
  local passed = (data == nil) and (type(err) == "string") and (err:find("file too large", 1, true) ~= nil)
  log_result("NEG slurp too small", passed, "cap=" .. tostring(cap) .. "; err=" .. tostring(err))
end

local function run_negative_outside_sandbox_guard_test()
  log_step("NEG outside sandbox guard", "Starting outside-sandbox guard check")
  local probe = generic_path_input
  if is_inside_sandbox(probe) then
    probe = Util.path_join(r.GetResourcePath(), "outside_sandbox_probe.txt")
  end

  local old_confirm = confirm_destructive
  confirm_destructive = true
  log_step("NEG outside sandbox guard", "Attempt destructive guard check for probe: " .. tostring(probe))
  local ok, err = guard_destructive_path(probe)
  confirm_destructive = old_confirm

  local passed = (ok == false) and (type(err) == "string") and (err:find("outside sandbox", 1, true) ~= nil)
  log_result("NEG outside sandbox guard", passed, "probe=" .. tostring(probe) .. "; guard_err=" .. tostring(err))
end

local function run_negative_cleanup_target_is_file_test()
  local test_id = "NEG cleanup target is file"
  log_step(test_id, "Starting target-is-file cleanup check")
  local ok_guard, guard_err = guard_destructive_path(test_file_path)
  if not ok_guard then
    log_result(test_id, false, guard_err)
    return
  end
  local ok_sample, sample_err = ensure_sample_file()
  if not ok_sample then
    log_result(test_id, false, sample_err)
    return
  end

  local ok, report = Files.remove_dir_contents_keep_root(test_file_path)
  local passed =
    ok == false and
    type(report) == "table" and
    report.status == "error" and
    #(report.errors or {}) >= 1
  log_result(test_id, passed, "ok=" .. tostring(ok) .. "; " .. format_cleanup_report(report))
end

local ctx = ImGui.CreateContext("Files Test")

local function GuiLoop()
  local visible, open = ImGui.Begin(ctx, "Files Module Tester", true)
  if visible then
    ImGui.Text(ctx, "Last status:")
    ImGui.TextWrapped(ctx, last_status_text)

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Live Util settings")

    local changed_messaging, new_messaging = ImGui.SliderInt(ctx, "messaging_level", tonumber(Util.messaging_level) or 0, 0, 4)
    if changed_messaging then
      Util.messaging_level = new_messaging
    end

    local changed_log_file_toggle, new_log_file_toggle = ImGui.Checkbox(ctx, "msg_to_log_file", Util.msg_to_log_file == true)
    if changed_log_file_toggle then
      Util.msg_to_log_file = new_log_file_toggle
    end

    local override_enabled = Util.log_level_override ~= nil
    local changed_override, new_override = ImGui.Checkbox(ctx, "Use log_level_override", override_enabled)
    if changed_override then
      if new_override then
        Util.log_level_override = tonumber(Util.messaging_level) or 0
      else
        Util.log_level_override = nil
      end
    end

    if Util.log_level_override ~= nil then
      local changed_override_level, new_override_level = ImGui.SliderInt(ctx, "log_level_override", tonumber(Util.log_level_override) or 0, 0, 4)
      if changed_override_level then
        Util.log_level_override = new_override_level
      end
    end

    local changed_tmp_dir, new_tmp_dir = ImGui.InputText(ctx, "tmp_dir", tostring(Util.tmp_dir or ""))
    if changed_tmp_dir then
      if new_tmp_dir == "" then
        Util.tmp_dir = nil
      else
        Util.tmp_dir = new_tmp_dir
      end
    end

    local changed_log_name, new_log_name = ImGui.InputText(ctx, "log_file_name", tostring(Util.log_file_name or ""))
    if changed_log_name then
      if new_log_name == "" then
        Util.log_file_name = nil
      else
        Util.log_file_name = new_log_name
      end
    end

    ImGui.Text(ctx, "full_path_to_log_file: " .. tostring(Util.full_path_to_log_file or "(nil)"))
    if ImGui.Button(ctx, "Clear cached log path") then
      Util.full_path_to_log_file = nil
    end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Shared test inputs")
    local changed_sandbox, new_sandbox = ImGui.InputText(ctx, "sandbox_root", tostring(sandbox_root or ""))
    if changed_sandbox then
      sandbox_root = new_sandbox
      sync_logger_with_sandbox()
    end
    local changed_file_name, new_file_name = ImGui.InputText(ctx, "test_file_name", tostring(test_file_name or ""))
    if changed_file_name then
      test_file_name = new_file_name
    end
    local changed_file_path, new_file_path = ImGui.InputText(ctx, "test_file_path", tostring(test_file_path or ""))
    if changed_file_path then
      test_file_path = new_file_path
    end
    local changed_output_name, new_output_name = ImGui.InputText(ctx, "output_dir_name", tostring(output_dir_name or ""))
    if changed_output_name then
      output_dir_name = new_output_name
    end
    local changed_output_path, new_output_path = ImGui.InputText(ctx, "output_dir_path", tostring(output_dir_path or ""))
    if changed_output_path then
      output_dir_path = new_output_path
    end
    local changed_sample, new_sample = ImGui.InputText(ctx, "sample_text", tostring(sample_text or ""))
    if changed_sample then
      sample_text = new_sample
    end
    local changed_safe_name, new_safe_name = ImGui.InputText(ctx, "safe_name_input", tostring(safe_name_input or ""))
    if changed_safe_name then
      safe_name_input = new_safe_name
    end
    local changed_safe_expected, new_safe_expected = ImGui.Checkbox(ctx, "safe_name_expected", safe_name_expected == true)
    if changed_safe_expected then
      safe_name_expected = new_safe_expected
    end
    local changed_max_bytes, new_max_bytes = ImGui.InputText(ctx, "max_bytes_input", tostring(max_bytes_input or ""))
    if changed_max_bytes then
      max_bytes_input = new_max_bytes
    end
    local changed_tail_bytes, new_tail_bytes = ImGui.InputText(ctx, "tail_bytes_input", tostring(tail_bytes_input or ""))
    if changed_tail_bytes then
      tail_bytes_input = new_tail_bytes
    end
    local changed_generic_path, new_generic_path = ImGui.InputText(ctx, "generic_path_input", tostring(generic_path_input or ""))
    if changed_generic_path then
      generic_path_input = new_generic_path
    end

    if ImGui.Button(ctx, "Rebuild derived paths from sandbox + names") then
      rebuild_derived_paths()
      log_result("rebuild_paths", true, "test_file_path and output_dir_path updated")
    end
    if ImGui.Button(ctx, "Ensure sandbox root exists") then
      local ok, err = Files.ensure_tmp_dir(sandbox_root)
      log_result("ensure_sandbox_root", ok == true, "ok=" .. tostring(ok) .. "; err=" .. tostring(err))
    end

    local changed_confirm, new_confirm = ImGui.Checkbox(ctx, "Confirm destructive actions", confirm_destructive == true)
    if changed_confirm then
      confirm_destructive = new_confirm
    end
    if ImGui.Button(ctx, "Manual cleanup sandbox (destructive)") then
      run_manual_cleanup()
    end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Section 1: Path/Name helpers")
    if ImGui.Button(ctx, "Test bump_to_unique_path") then run_bump_to_unique_path_test() end
    if ImGui.Button(ctx, "Test read_project_path") then run_read_project_path_test() end
    if ImGui.Button(ctx, "Test project_dir_safety") then run_project_dir_safety_test() end
    if ImGui.Button(ctx, "Test is_filesystem_safe_name") then run_is_filesystem_safe_name_test() end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Section 2: File IO helpers")
    if ImGui.Button(ctx, "Test write_file") then run_write_file_test() end
    if ImGui.Button(ctx, "Test truncate_file (destructive)") then run_truncate_file_test() end
    if ImGui.Button(ctx, "Test file_size") then run_file_size_test() end
    if ImGui.Button(ctx, "Test read_tail") then run_read_tail_test() end
    if ImGui.Button(ctx, "Test slurp_with_cap") then run_slurp_with_cap_test() end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Section 3: Directory / ensure helpers")
    if ImGui.Button(ctx, "Test ensure_tmp_dir") then run_ensure_tmp_dir_test() end
    if ImGui.Button(ctx, "Test ensure_output_dir") then run_ensure_output_dir_test() end
    if ImGui.Button(ctx, "Test remove_best_effort (destructive)") then run_remove_best_effort_test() end
    if ImGui.Button(ctx, "Test remove_all_files_in_dir (destructive)") then run_remove_all_files_in_dir_test() end
    if ImGui.Button(ctx, "Test remove_dir_contents_keep_root (destructive)") then run_remove_dir_contents_keep_root_test() end
    if ImGui.Button(ctx, "Test remove_whole_dir_tree (destructive)") then run_remove_whole_dir_tree_test() end
    if ImGui.Button(ctx, "Test keep_root on empty dir (destructive)") then run_remove_dir_contents_keep_root_empty_test() end
    if ImGui.Button(ctx, "Test whole_tree on missing dir (destructive)") then run_remove_whole_dir_tree_missing_test() end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Negative-case checks")
    if ImGui.Button(ctx, "NEG: invalid/missing path checks") then run_negative_invalid_paths_test() end
    if ImGui.Button(ctx, "NEG: slurp_with_cap too-small cap") then run_negative_slurp_too_small_test() end
    if ImGui.Button(ctx, "NEG: outside-sandbox destructive guard") then run_negative_outside_sandbox_guard_test() end
    if ImGui.Button(ctx, "NEG: cleanup target is file") then run_negative_cleanup_target_is_file_test() end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Rolling result log")
    if ImGui.Button(ctx, "Clear result log") then
      rolling_log_lines = {}
      last_status_text = "Log cleared."
    end
    local start_index = math.max(1, #rolling_log_lines - 59)
    for i = start_index, #rolling_log_lines do
      ImGui.TextWrapped(ctx, rolling_log_lines[i])
    end
  end
  ImGui.End(ctx)

  if open then
    r.defer(GuiLoop)
  end
end

r.defer(GuiLoop)

