-- @description Test Curl and Jobs (ReaImGui)
-- @version 1.0.0
-- @author Slava Logutin
-- @about Interactive test suite for Curl HTTP requests and background Jobs in REAPER using ReaImGui.
-- @provides
--   [main] .
--   modules/Curl.lua > modules/Curl.lua
--   modules/Jobs.lua > modules/Jobs.lua
--   modules/Files.lua > modules/Files.lua
--   modules/Util.lua > modules/Util.lua
--   modules/json.lua > modules/json.lua
-- Reaper-hosted interactive tester for modules.Curl and modules.Jobs.
-- Mirrors test_Files.lua structure: runtime guards, package.path handling,
-- ReaImGui loop, rolling logs, and an optional exit cleanup hook.

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

-- Two-stage package.path loading:
-- 1) local project modules
-- 2) ReaImGui builtin module
local old_package_path = package.path

package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. old_package_path

local ok_json, json_mod = pcall(require, "modules.json")
if not ok_json then
  package.path = old_package_path
  r.MB("Failed to load json module: " .. tostring(json_mod), "Error", 0)
  return
end
local json = json_mod

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

local ok_curl, Curl = pcall(require, "modules.Curl")
if not ok_curl then
  package.path = old_package_path
  r.MB("Failed to load modules.Curl: " .. tostring(Curl), "Error", 0)
  return
end

local ok_jobs, Jobs = pcall(require, "modules.Jobs")
if not ok_jobs then
  package.path = old_package_path
  r.MB("Failed to load modules.Jobs: " .. tostring(Jobs), "Error", 0)
  return
end

local ok_cleanup, Cleanup = pcall(require, "modules.Cleanup")
if not ok_cleanup then
  package.path = old_package_path
  r.MB("Failed to load modules.Cleanup: " .. tostring(Cleanup), "Error", 0)
  return
end

-- 2nd stage:
-- load ReaImGui
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

local Helpers, AsyncRows, TestCases, UI = {}, {}, {}, {}
local ctx = ImGui.CreateContext("Curl+Jobs Test")
local font_size = 16
local FONT = ImGui.CreateFont("monospace")
ImGui.Attach(ctx, FONT)

-- Reserved for future shutdown cleanup tasks (if/when needed).
-- r.atexit(function() end)

-- Provider settings and endpoints.
local PROVIDERS = {
  modes = { "Hybrid", "httpbin-only", "postman-only", "httpbun" },
  mode_idx = 1,
  base_httpbin = "https://httpbin.org",
  base_postman = "https://postman-echo.com",
  base_httpbun = "https://httpbun.com"
}

local PATHS = {
  get = "/get",
  post = "/post",
  headers = "/headers",
  status_fmt = "/status/%d",
  delay_fmt = "/delay/%d",
  download_fmt = "/bytes/%d",
  tls_url_expired = "https://expired.badssl.com/",
  tls_url_self_signed = "https://self-signed.badssl.com/"
}

-- Runtime input values used by tests and runtime config build.
local INPUTS = {
  concurrency = "8",
  download_bytes = "52428800",
  upload_bytes = "52428800",
  request_timeout_sec = "45",
  max_retry = "2",
  poll_timeout_sec = "90",
  delay_seconds = "4",
  short_timeout_sec = "1",
  max_concurrent_jobs = "12",
  max_concurrent_ivc_jobs = "1",
  retry_base_backoff_sec = "1.0",
  retry_jitter_ratio = "0.0",
  max_wait_time_for_retry = "25.0"
}

-- Mutable UI and test runtime state.
local flags = {
  keep_artifacts = false,
  enable_tls_negative = false,
  confirm_destructive = false
}

local ui_state = {
  last_status_text = "Ready.",
  status_text = "Ready.",
  rolling_log_lines = {},
  warnings = {},
  request_rows = {},
  rows_by_id = {},
  test_runs = {},
  next_row_seq = 1,
  next_run_seq = 1,
  auto_retry = true,
  log_max_lines = 350,
  cleanup_last_tick = {
    attempted = 0,
    deleted = 0,
    retry_scheduled = 0,
    skipped_not_due = 0,
    gave_up = 0,
    remaining = 0
  },
  cleanup_totals = {
    attempted = 0,
    deleted = 0,
    retry_scheduled = 0,
    skipped_not_due = 0,
    gave_up = 0
  },
  cleanup_warned_paths = {},
  cleanup_selected_failure_path = nil
}

local stats = {
  counters = { pass = 0, fail = 0, skip = 0 },
  events = {
    job_scheduled = 0,
    job_started = 0,
    retry_scheduled = 0,
    retry_fired = 0,
    retry_submit_error = 0,
    record_canceled = 0,
    runtime_reset = 0
  }
}

local ASYNC_METER_COLUMNS = {
  { header = "Tot%", key = "total_pct", width = 62 },
  { header = "TotSz", key = "total_size", width = 72 },
  { header = "Recv%", key = "received_pct", width = 62 },
  { header = "RecvSz", key = "received_size", width = 72 },
  { header = "Xfer%", key = "xferd_pct", width = 62 },
  { header = "XferSz", key = "xferd_size", width = 72 },
  { header = "AvgDl", key = "avg_dload_speed", width = 72 },
  { header = "AvgUp", key = "avg_upload_speed", width = 72 },
  { header = "TTot", key = "time_total", width = 76 },
  { header = "TSpent", key = "time_spent", width = 76 },
  { header = "TLeft", key = "time_left", width = 76 },
  { header = "CurSpd", key = "current_speed", width = 76 }
}

local runtime = {
  external_busy = false,
  state = nil,
  cfg = nil,
  ready = false,
  upload_source_path = nil,
  sandbox_root = Util.path_join(r.GetResourcePath(), "Data")
}
runtime.sandbox_root = Util.path_join(runtime.sandbox_root, "Curl_Jobs_Module_Test")
runtime.sandbox_root = Util.path_join(runtime.sandbox_root, "tmp")
r.RecursiveCreateDirectory(runtime.sandbox_root, 0)

-- What this function does: Points Util logging temp output to the sandbox folder and clears cached log path.
-- How it is used: Called at startup and whenever sandbox_root is edited in the UI.
function Helpers.sync_logger_with_sandbox()
  Util.tmp_dir = runtime.sandbox_root
  Util.full_path_to_log_file = nil
end

Helpers.sync_logger_with_sandbox()
Util.messaging_level = 0
Util.msg_to_log_file = true
Util.log_file_name = "test_Curl_Jobs_log"

-- What this function does: Adds one line to the in-memory rolling log and trims old entries.
-- How it is used: Used by logging helpers before lines are shown in the GUI.
function Helpers.add_log_line(line)
  table.insert(ui_state.rolling_log_lines, line)
  if #ui_state.rolling_log_lines > ui_state.log_max_lines then
    table.remove(ui_state.rolling_log_lines, 1)
  end
end

local function fresh_cleanup_last_tick()
  return {
    attempted = 0,
    deleted = 0,
    retry_scheduled = 0,
    skipped_not_due = 0,
    gave_up = 0,
    remaining = 0
  }
end

local function fresh_cleanup_totals()
  return {
    attempted = 0,
    deleted = 0,
    retry_scheduled = 0,
    skipped_not_due = 0,
    gave_up = 0
  }
end

-- What this function does: Clears cleanup telemetry widgets/caches used by tester UI.
-- How it is used: Called on runtime init/reset paths to keep test runs isolated.
function Helpers.reset_cleanup_ui_telemetry()
  ui_state.cleanup_last_tick = fresh_cleanup_last_tick()
  ui_state.cleanup_totals = fresh_cleanup_totals()
  ui_state.cleanup_warned_paths = {}
  ui_state.cleanup_selected_failure_path = nil
end

-- What this function does: Builds a sorted list of cleanup failure rows for UI display.
-- How it is used: Called by the cleanup telemetry panel each frame.
function Helpers.collect_cleanup_failure_rows()
  local rows = {}
  local failures = runtime.state and runtime.state.cleanup_failures
  if type(failures) ~= "table" then
    return rows
  end
  for path, rec in pairs(failures) do
    if type(rec) == "table" then
      rows[#rows + 1] = {
        path = tostring(path),
        why = tostring(rec.why or ""),
        attempts = tonumber(rec.attempts) or 0,
        max_attempts = tonumber(rec.max_attempts) or 0,
        fail_count = tonumber(rec.fail_count) or 0,
        last_failed_at = tonumber(rec.last_failed_at) or 0,
        last_failed_at_str = tostring(rec.last_failed_at_str or ""),
        last_error = tostring(rec.last_error or "")
      }
    end
  end
  table.sort(rows, function(a, b)
    local ta = tonumber(a.last_failed_at) or 0
    local tb = tonumber(b.last_failed_at) or 0
    if ta ~= tb then
      return ta > tb
    end
    return tostring(a.path or "") < tostring(b.path or "")
  end)
  return rows
end

-- What this function does: Updates per-tick and cumulative cleanup counters and raises deduped warnings.
-- How it is used: Called from async polling after Jobs.tick_all().
function Helpers.update_cleanup_telemetry_from_tick(tick_stats)
  local st = tick_stats or {}
  local last = ui_state.cleanup_last_tick or fresh_cleanup_last_tick()
  local totals = ui_state.cleanup_totals or fresh_cleanup_totals()

  last.attempted = tonumber(st.cleanup_attempted) or 0
  last.deleted = tonumber(st.cleanup_deleted) or 0
  last.retry_scheduled = tonumber(st.cleanup_retry_scheduled) or 0
  last.skipped_not_due = tonumber(st.cleanup_skipped_not_due) or 0
  last.gave_up = tonumber(st.cleanup_gave_up) or 0
  last.remaining = tonumber(st.cleanup_remaining) or 0
  ui_state.cleanup_last_tick = last

  totals.attempted = (tonumber(totals.attempted) or 0) + last.attempted
  totals.deleted = (tonumber(totals.deleted) or 0) + last.deleted
  totals.retry_scheduled = (tonumber(totals.retry_scheduled) or 0) + last.retry_scheduled
  totals.skipped_not_due = (tonumber(totals.skipped_not_due) or 0) + last.skipped_not_due
  totals.gave_up = (tonumber(totals.gave_up) or 0) + last.gave_up
  ui_state.cleanup_totals = totals

  if last.gave_up <= 0 then
    return
  end

  if type(ui_state.cleanup_warned_paths) ~= "table" then
    ui_state.cleanup_warned_paths = {}
  end
  local warned = ui_state.cleanup_warned_paths
  local failure_rows = Helpers.collect_cleanup_failure_rows()
  for i = 1, #failure_rows do
    local row = failure_rows[i]
    local token = tostring(row.fail_count) .. ":" .. tostring(row.attempts) .. ":" .. tostring(row.last_failed_at_str)
    if warned[row.path] ~= token then
      warned[row.path] = token
      AsyncRows.add_warning(
        "Cleanup give-up: " .. tostring(row.path) ..
        " (" .. tostring(row.attempts) .. "/" .. tostring(row.max_attempts) .. ")" ..
        " why=" .. tostring(row.why) ..
        " err=" .. tostring(row.last_error)
      )
    end
  end
end

-- What this function does: Writes a STEP-style log message with timestamp.
-- How it is used: Used at the beginning of test functions to show progress.
function Helpers.log_step(test_id, message, importance)
  local line = os.date("%H:%M:%S") .. " [STEP] " .. tostring(test_id) .. " - " .. tostring(message or "")
  Helpers.add_log_line(line)
  Util.msg(line, importance or 1)
end

-- What this function does: Writes PASS/FAIL/SKIP result lines and updates counters.
-- How it is used: Used by result helpers and all tests to track outcomes.
function Helpers.log_outcome(test_id, status, details)
  local st = tostring(status or "FAIL")
  local line = os.date("%H:%M:%S") .. " [" .. st .. "] " .. tostring(test_id) .. " - " .. tostring(details or "")
  ui_state.last_status_text = line
  ui_state.status_text = line
  Helpers.add_log_line(line)
  if st == "PASS" then
    stats.counters.pass = stats.counters.pass + 1
    Util.msg(line, 1)
  elseif st == "SKIP" then
    stats.counters.skip = stats.counters.skip + 1
    Util.msg(line, 1)
  else
    stats.counters.fail = stats.counters.fail + 1
    Util.msg(line, 2)
  end
end

-- What this function does: Converts a boolean result into PASS or FAIL logging.
-- How it is used: Used by tests for the common success/failure report path.
function Helpers.log_result(test_id, passed, details)
  if passed then
    Helpers.log_outcome(test_id, "PASS", details)
  else
    Helpers.log_outcome(test_id, "FAIL", details)
  end
end

-- What this function does: Writes a SKIP result line with a reason.
-- How it is used: Used when network/provider instability makes a test inconclusive.
function Helpers.mark_skip(test_id, reason)
  Helpers.log_outcome(test_id, "SKIP", reason)
end

-- What this function does: Safely decodes JSON text and returns a table or nil.
-- How it is used: Used by API echo tests to avoid hard errors on invalid JSON.
function Helpers.safe_json_decode(txt)
  if type(txt) ~= "string" or txt == "" then return nil end
  local ok, tbl = pcall(json.decode, txt)
  if ok and type(tbl) == "table" then
    return tbl
  end
  return nil
end

-- What this function does: Checks whether a path is inside the configured sandbox folder.
-- How it is used: Used by destructive-operation guards before cleanup actions.
function Helpers.path_is_inside_sandbox(path)
  return Files.is_path_inside(runtime.sandbox_root, path)
end

-- What this function does: Validates destructive targets: non-empty, inside sandbox, and user-confirmed.
-- How it is used: Used before manual cleanup to reduce accidental file removal risk.
function Helpers.guard_destructive_path(path)
  if type(path) ~= "string" or path == "" then
    return false, "missing path"
  end
  if not Helpers.path_is_inside_sandbox(path) then
    return false, "path outside sandbox: " .. tostring(path)
  end
  if not flags.confirm_destructive then
    return false, "confirmation checkbox is not enabled"
  end
  return true
end

-- What this function does: Combines a base URL and path while handling leading/trailing slashes.
-- How it is used: Used to build test request URLs from provider base + endpoint path.
function Helpers.join_url(base, path)
  local p = tostring(path or "")
  if p:match("^https?://") then return p end
  local b = tostring(base or "")
  if b == "" then return p end
  if b:sub(-1) == "/" and p:sub(1, 1) == "/" then
    return b:sub(1, -2) .. p
  end
  if b:sub(-1) ~= "/" and p:sub(1, 1) ~= "/" then
    return b .. "/" .. p
  end
  return b .. p
end

-- What this function does: Converts selected provider mode into internal key (hybrid/httpbin/postman/httpbun).
-- How it is used: Used by provider selection helpers before each request.
function Helpers.provider_key()
  local idx = PROVIDERS.mode_idx
  if idx < 1 then idx = 1 end
  if idx > #PROVIDERS.modes then idx = #PROVIDERS.modes end
  local mode = PROVIDERS.modes[idx]
  if mode == "Hybrid" then return "hybrid" end
  if mode == "httpbin-only" then return "httpbin" end
  if mode == "postman-only" then return "postman" end
  return "httpbun"
end

-- What this function does: Picks provider by test role; hybrid mode routes some roles specially.
-- How it is used: Used by individual tests to choose the endpoint provider.
function Helpers.select_provider_for_role(role)
  local k = Helpers.provider_key()
  if k == "hybrid" then
    if role == "download" then
      return "postman"
    end
    return "httpbin"
  end
  return k
end

-- What this function does: Maps provider key to its base URL.
-- How it is used: Used when constructing full request URLs.
function Helpers.provider_base(provider)
  if provider == "httpbin" then return PROVIDERS.base_httpbin end
  if provider == "postman" then return PROVIDERS.base_postman end
  return PROVIDERS.base_httpbun
end

-- What this function does: Maps provider key to display-friendly host name.
-- How it is used: Used in result messages and skip reasons.
function Helpers.provider_name(provider)
  if provider == "httpbin" then return "httpbin.org" end
  if provider == "postman" then return "postman-echo.com" end
  return "httpbun.com"
end

-- What this function does: Formats path templates like /status/%d with a runtime value.
-- How it is used: Used by status/delay/download tests to build endpoint paths.
function Helpers.format_path_value(path_fmt, value)
  local fmt = tostring(path_fmt or "")
  if fmt:find("%d", 1, true) then
    local ok, out = pcall(string.format, fmt, tonumber(value) or 0)
    if ok then return out end
  end
  if fmt:find("%", 1, true) then
    local ok, out = pcall(string.format, fmt, tostring(value))
    if ok then return out end
  end
  if fmt:sub(-1) == "/" then
    return fmt .. tostring(value)
  end
  return fmt
end

-- What this function does: Builds Curl/Jobs runtime config from current UI input values.
-- How it is used: Used during runtime initialization and reinitialization.
function Helpers.build_cfg()
  local cfg = {}
  cfg.tmp_dir = runtime.sandbox_root
  cfg.curl =
    Util.mac and "/usr/bin/curl"
    or [===[C:\code\curl_test_01\curl.exe]===]
  cfg.timeout_sec = Util.parse_number(INPUTS.request_timeout_sec, 45, 1)
  cfg.max_concurrent_jobs = Util.parse_int(INPUTS.max_concurrent_jobs, 12, 1)
  cfg.max_concurrent_IVC_jobs = Util.parse_int(INPUTS.max_concurrent_ivc_jobs, 1, 1)
  cfg.curl_connect_timeout_sec = 20
  cfg.curl_speed_limit = 1
  cfg.curl_speed_time = 60
  cfg.use_fail_with_body = true
  cfg.retry_base_backoff_sec = Util.parse_number(INPUTS.retry_base_backoff_sec, 1.0, 0)
  cfg.retry_jitter_ratio = Util.parse_number(INPUTS.retry_jitter_ratio, 0.0, 0)
  cfg.max_wait_time_for_retry = Util.parse_number(INPUTS.max_wait_time_for_retry, 25.0, 0)
  return cfg
end

-- What this function does: Initializes runtime state tables and wires Curl/Jobs callbacks.
-- How it is used: Called at startup and when runtime is manually reinitialized.
function Helpers.init_runtime(test_id)
  local ok_tmp, err_tmp = Files.ensure_tmp_dir(runtime.sandbox_root)
  if not ok_tmp then
    Helpers.log_result(test_id or "runtime_init", false, "ensure_tmp_dir failed: " .. tostring(err_tmp))
    runtime.ready = false
    return false
  end

  local state = {
    status_text = "",
    curl_jobs = {},
    cleanup_queue = {},
    cleanup_failures = {},
    retry_queue = {},
    retry_generation = 0,
    pending_job = nil,
    wait_until = nil,
    running_label = nil,
    ui_lock_network_buttons = false,
    last_http = "",
    last_curl_return = {}
  }
  local cfg = Helpers.build_cfg()
  Curl.init(state, cfg)
  Jobs.init(state, cfg, {
    on_event = function(name, _payload)
      if stats.events[name] ~= nil then
        stats.events[name] = stats.events[name] + 1
      end
    end,
    is_externally_busy = function(_state)
      return runtime.external_busy == true
    end
  })
  runtime.state = state
  runtime.cfg = cfg
  runtime.ready = true
  Helpers.reset_cleanup_ui_telemetry()
  return true
end

-- What this function does: Guarantees runtime exists before a test runs.
-- How it is used: Called at start of each test function.
function Helpers.ensure_runtime(test_id)
  if runtime.ready and runtime.state and runtime.cfg then
    return true
  end
  return Helpers.init_runtime(test_id)
end

-- What this function does: Returns high-precision current time from Reaper.
-- How it is used: Used by wait loops and timeout checks.
function Helpers.now_sec()
  return r.time_precise()
end

-- What this function does: Builds Curl submit options (read body, timeout, keep output, payload-file mode).
-- How it is used: Used by curl request helpers and tests.
function Helpers.pick_opts(read_body, timeout_sec_override, keep_output_override, use_payload_file_override)
  local keep = flags.keep_artifacts
  if keep_output_override ~= nil then
    keep = (keep_output_override == true)
  end
  local opts = {
    read_body = (read_body == true),
    body_max_bytes = 8 * 1024 * 1024,
    timeout_sec = timeout_sec_override or runtime.cfg.timeout_sec,
    keep_output = keep
  }
  if use_payload_file_override ~= nil then
    opts.use_payload_file = (use_payload_file_override == true)
  end
  return opts
end

-- What this function does: Detects likely transient network/provider failures from error text patterns.
-- How it is used: Used to decide whether to mark a test as SKIP instead of FAIL.
function Helpers.has_network_instability(result, submit_err)
  local parts = {}
  if submit_err then table.insert(parts, tostring(submit_err)) end
  if result and result.err then table.insert(parts, tostring(result.err)) end
  if result and result.err_txt then table.insert(parts, tostring(result.err_txt)) end
  local hay = table.concat(parts, " | "):lower()
  if hay == "" then return false end

  local patterns = {
    "could not resolve host",
    "failed to connect",
    "connection refused",
    "timed out",
    "connection timed out",
    "temporary failure",
    "network is unreachable",
    "tls",
    "ssl connect error",
    "schannel",
    "proxy connect aborted",
    "reset by peer",
    "no route to host"
  }
  for i = 1, #patterns do
    if hay:find(patterns[i], 1, true) then
      return true
    end
  end
  return false
end

-- What this function does: Reads a header value from JSON echo response table case-insensitively.
-- How it is used: Used by auth-header test to validate reflected Authorization header.
function Helpers.read_echo_header(tbl, key_name)
  if type(tbl) ~= "table" then return nil end
  local headers = tbl.headers
  if type(headers) ~= "table" then return nil end
  local target = tostring(key_name or ""):lower()
  for k, v in pairs(headers) do
    if tostring(k):lower() == target then
      return tostring(v)
    end
  end
  return nil
end

-- What this function does: Resets Jobs event counters to zero.
-- How it is used: Used before event-focused runtime reset assertions.
function Helpers.reset_events()
  for k in pairs(stats.events) do
    stats.events[k] = 0
  end
end

-- What this function does: Creates a unique sandbox file path for download artifacts.
-- How it is used: Used by download/concurrency/cleanup tests.
function Helpers.build_temp_download_path(prefix)
  local stamp = Util.date_time_stamp_with_time_precise()
  local name = tostring(prefix or "download") .. "_" .. tostring(stamp) .. ".bin"
  return Util.path_join(runtime.sandbox_root, name)
end

-- What this function does: Removes a file unless keep_artifacts is enabled.
-- How it is used: Used by tests after temporary files are created.
function Helpers.cleanup_path_if_needed(path)
  if flags.keep_artifacts then return end
  if type(path) ~= "string" or path == "" then return end
  Files.remove_best_effort(path)
end

-- What this function does: Clears the retained upload source file pointer and removes file when cleanup policy allows.
-- How it is used: Called on runtime/async resets to avoid stale source-file pointers between runs.
function Helpers.clear_upload_source_file(reason)
  local old_path = runtime.upload_source_path
  runtime.upload_source_path = nil
  if type(old_path) ~= "string" or old_path == "" then
    return false, "upload source path was empty"
  end
  if (flags.keep_artifacts ~= true) and Helpers.path_is_inside_sandbox(old_path) then
    Files.remove_best_effort(old_path)
  end
  if reason and reason ~= "" then
    Util.msg("Cleared upload source file: " .. tostring(reason), 0)
  end
  return true, old_path
end

-- What this function does: Stores one retained download artifact path as the source for large-upload test.
-- How it is used: Called after a successful large-download test to make upload use that file.
function Helpers.set_upload_source_file(path)
  if type(path) ~= "string" or path == "" then
    return false, "upload source path must be a non-empty string"
  end
  if r.file_exists(path) ~= true then
    return false, "upload source path does not exist: " .. tostring(path)
  end
  local prev = runtime.upload_source_path
  runtime.upload_source_path = path
  if type(prev) == "string" and prev ~= "" and prev ~= path then
    if (flags.keep_artifacts ~= true) and Helpers.path_is_inside_sandbox(prev) then
      Files.remove_best_effort(prev)
    end
  end
  return true
end

-- What this function does: Returns validated retained upload source file path or an actionable error.
-- How it is used: Called by large-upload test before submitting curl request.
function Helpers.get_upload_source_file()
  local p = runtime.upload_source_path
  if type(p) ~= "string" or p == "" then
    return nil, "missing upload source file; run the large download source test first"
  end
  if r.file_exists(p) ~= true then
    runtime.upload_source_path = nil
    return nil, "upload source file no longer exists; run the large download source test first"
  end
  return p
end
-- What this function does: Checks that a scheduled job runs when ticked.
-- How it is used: Triggered by the "Test jobs_schedule_and_tick" button.
function TestCases.run_jobs_schedule_and_tick_test()
  local test_id = "jobs_schedule_and_tick"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local ran = false
  local ok_sched = Jobs.schedule_job("unit", function() ran = true end, 0)
  local did_run = Jobs.tick_job()
  local passed = (ok_sched == true) and (did_run == true) and (ran == true)
  Helpers.log_result(
    test_id,
    passed,
    "scheduled=" .. tostring(ok_sched) .. "; tick_ran=" .. tostring(did_run) .. "; callback_ran=" .. tostring(ran)
  )
end

-- What this function does: Checks scheduler rejects a second job while one is pending.
-- How it is used: Triggered by the "Test jobs_schedule_reject_when_pending" button.
function TestCases.run_jobs_schedule_reject_pending_test()
  local test_id = "jobs_schedule_reject_when_pending"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local ok1 = Jobs.schedule_job("first", function() end, 2.0)
  local ok2 = Jobs.schedule_job("second", function() end, 0)
  Jobs.reset_runtime("after " .. test_id)
  local passed = (ok1 == true) and (ok2 == false)
  Helpers.log_result(test_id, passed, "first=" .. tostring(ok1) .. "; second=" .. tostring(ok2))
end

-- What this function does: Checks enqueue_retry fires immediately when due now.
-- How it is used: Triggered by the "Test jobs_retry_enqueue_and_fire" button.
function TestCases.run_jobs_retry_enqueue_fire_test()
  local test_id = "jobs_retry_enqueue_and_fire"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local fired = 0
  local ok, err = Jobs.enqueue_retry("retry_now", function() fired = fired + 1 end, 1, 3, "test", nil)
  if not ok then
    Helpers.log_result(test_id, false, "enqueue failed: " .. tostring(err))
    return
  end
  local retry_stats = Jobs.poll_retry_queue(Jobs.now())
  local passed = (fired == 1) and (retry_stats and retry_stats.fired and retry_stats.fired >= 1) and (#runtime.state.retry_queue == 0)
  Helpers.log_result(
    test_id,
    passed,
    "fired=" .. tostring(fired) .. "; stats_fired=" .. tostring(retry_stats and retry_stats.fired) .. "; queue_size=" .. tostring(#runtime.state.retry_queue)
  )
end

-- What this function does: Checks generation bump clears queued retries and prevents firing.
-- How it is used: Triggered by the "Test jobs_retry_stale_generation_skip" button.
function TestCases.run_jobs_retry_stale_generation_test()
  local test_id = "jobs_retry_stale_generation_skip"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local fired = 0
  local ok, err = Jobs.enqueue_retry("retry_later", function() fired = fired + 1 end, 2, 3, "test", nil)
  if not ok then
    Helpers.log_result(test_id, false, "enqueue failed: " .. tostring(err))
    return
  end
  local gen_before = tonumber(runtime.state and runtime.state.retry_generation) or 0
  local gen_after = Jobs.bump_retry_generation("force stale")
  local retry_stats = Jobs.poll_retry_queue(Jobs.now() + 10)
  local stale_skipped = tonumber(retry_stats and retry_stats.stale_skipped) or 0
  local remaining = #(runtime.state and runtime.state.retry_queue or {})
  local passed = (fired == 0) and (remaining == 0) and (tonumber(gen_after) == (gen_before + 1)) and (stale_skipped == 0)
  Helpers.log_result(
    test_id,
    passed,
    "fired=" .. tostring(fired) ..
      "; remaining=" .. tostring(remaining) ..
      "; generation_before=" .. tostring(gen_before) ..
      "; generation_after=" .. tostring(gen_after) ..
      "; stale_skipped=" .. tostring(stale_skipped)
  )
end
-- What this function does: Checks manual retry path updates record state and fires retry submit.
-- How it is used: Triggered by the "Test jobs_manual_retry_record" button.
function TestCases.run_jobs_manual_retry_record_test()
  local test_id = "jobs_manual_retry_record"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local fired = 0
  local rec = {
    _retry_submit = function() fired = fired + 1 end,
    _retry_label = "record_retry",
    _max_attempts = 3,
    _state = "failed_final"
  }
  local ok, err = Jobs.manual_retry_record(rec)
  if not ok then
    Helpers.log_result(test_id, false, "manual_retry_record failed: " .. tostring(err))
    return
  end
  local retry_stats = Jobs.poll_retry_queue(Jobs.now())
  local passed = (rec._state == "retrying") and (fired == 1) and ((retry_stats and retry_stats.fired) or 0) >= 1
  Helpers.log_result(
    test_id,
    passed,
    "state=" .. tostring(rec._state) .. "; fired=" .. tostring(fired) .. "; stats_fired=" .. tostring(retry_stats and retry_stats.fired)
  )
end

-- What this function does: Checks cancel_record marks state and queues file cleanup paths.
-- How it is used: Triggered by the "Test jobs_cancel_record" button.
function TestCases.run_jobs_cancel_record_test()
  local test_id = "jobs_cancel_record"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local p1 = Util.path_join(runtime.sandbox_root, "cancel_input.tmp")
  local p2 = Util.path_join(runtime.sandbox_root, "cancel_output.tmp")
  Files.write_file(p1, "x")
  Files.write_file(p2, "y")

  local rec = {
    _state = "failed_final",
    _next_retry_at = Jobs.now() + 1,
    input_path = p1,
    output_path = p2
  }
  local before = #runtime.state.cleanup_queue
  local ok, err = Jobs.cancel_record(rec, "canceled by test")
  local after = #runtime.state.cleanup_queue
  local passed = (ok == true) and (rec._state == "canceled") and (after >= before + 2)
  Helpers.log_result(
    test_id,
    passed,
    "ok=" .. tostring(ok) .. "; err=" .. tostring(err) .. "; state=" .. tostring(rec._state) ..
      "; cleanup_before=" .. tostring(before) .. "; cleanup_after=" .. tostring(after)
  )
end

-- What this function does: Checks network_busy semantics across pending/external/curl-running states.
-- How it is used: Triggered by the "Test jobs_network_busy_semantics" button.
function TestCases.run_jobs_network_busy_semantics_test()
  local test_id = "jobs_network_busy_semantics"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  runtime.external_busy = false

  local idle_busy = Jobs.network_busy()
  local ok_sched = Jobs.schedule_job("pending", function() end, 2.0)
  local pending_busy = Jobs.network_busy()
  Jobs.reset_runtime("mid " .. test_id)

  local _ok_retry = Jobs.enqueue_retry("future_retry", function() end, 2, 2, "err", nil)
  local retry_only_busy = Jobs.network_busy()
  Jobs.reset_runtime("mid2 " .. test_id)

  runtime.external_busy = true
  local external_busy = Jobs.network_busy()
  runtime.external_busy = false

  runtime.state.curl_jobs["manual_running"] = { phase = "running" }
  local curl_busy = Jobs.network_busy()
  runtime.state.curl_jobs = {}

  Jobs.reset_runtime("after " .. test_id)
  local passed =
    (idle_busy == false) and
    (ok_sched == true) and
    (pending_busy == true) and
    (retry_only_busy == false) and
    (external_busy == true) and
    (curl_busy == true)
  Helpers.log_result(
    test_id,
    passed,
    "idle=" .. tostring(idle_busy) ..
      "; pending=" .. tostring(pending_busy) ..
      "; retry_only=" .. tostring(retry_only_busy) ..
      "; external=" .. tostring(external_busy) ..
      "; curl_running=" .. tostring(curl_busy)
  )
end

-- What this function does: Checks tick_all returns expected stats and runs due job.
-- How it is used: Triggered by the "Test jobs_tick_all_stats" button.
function TestCases.run_jobs_tick_all_stats_test()
  local test_id = "jobs_tick_all_stats"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  local marker = false
  Jobs.schedule_job("tick_all_job", function() marker = true end, 0)
  local tick_stats = Jobs.tick_all()
  local passed =
    type(tick_stats) == "table" and
    (tick_stats.job_ran == true) and
    (tick_stats.curl_polled == true) and
    (tick_stats.cleanup_polled == true) and
    (type(tick_stats.retries_fired) == "number") and
    (type(tick_stats.cleanup_attempted) == "number") and
    (type(tick_stats.cleanup_deleted) == "number") and
    (type(tick_stats.cleanup_retry_scheduled) == "number") and
    (type(tick_stats.cleanup_skipped_not_due) == "number") and
    (type(tick_stats.cleanup_gave_up) == "number") and
    (type(tick_stats.cleanup_remaining) == "number") and
    (marker == true)
  Helpers.log_result(
    test_id,
    passed,
    "job_ran=" .. tostring(tick_stats and tick_stats.job_ran) ..
      "; retries_fired=" .. tostring(tick_stats and tick_stats.retries_fired) ..
      "; cleanup_polled=" .. tostring(tick_stats and tick_stats.cleanup_polled) ..
      "; attempted=" .. tostring(tick_stats and tick_stats.cleanup_attempted) ..
      "; deleted=" .. tostring(tick_stats and tick_stats.cleanup_deleted) ..
      "; retry=" .. tostring(tick_stats and tick_stats.cleanup_retry_scheduled) ..
      "; skipped=" .. tostring(tick_stats and tick_stats.cleanup_skipped_not_due) ..
      "; gave_up=" .. tostring(tick_stats and tick_stats.cleanup_gave_up) ..
      "; remaining=" .. tostring(tick_stats and tick_stats.cleanup_remaining)
  )
end

-- What this function does: Checks reset_runtime clears runtime fields and queues cleanup.
-- How it is used: Triggered by the "Test jobs_reset_runtime" button.
function TestCases.run_jobs_reset_runtime_test()
  local test_id = "jobs_reset_runtime"
  Helpers.log_step(test_id, "Starting")
  if not Helpers.ensure_runtime(test_id) then return end
  Jobs.reset_runtime("before " .. test_id)
  Helpers.reset_events()
  local cfgp = Util.path_join(runtime.sandbox_root, "reset_cfg.tmp")
  local hdrp = Util.path_join(runtime.sandbox_root, "reset_hdr.tmp")
  local errp = Util.path_join(runtime.sandbox_root, "reset_err.tmp")
  local metap = Util.path_join(runtime.sandbox_root, "reset_meta.tmp")
  local outp = Util.path_join(runtime.sandbox_root, "reset_out.tmp")
  Files.write_file(cfgp, "x")
  Files.write_file(hdrp, "x")
  Files.write_file(errp, "x")
  Files.write_file(metap, "x")
  Files.write_file(outp, "x")

  runtime.state.pending_job = { label = "x", fn = function() end }
  runtime.state.wait_until = Jobs.now() + 5
  runtime.state.running_label = "x"
  runtime.state.ui_lock_network_buttons = true
  runtime.state.retry_queue = { { label = "x", due_at = Jobs.now() + 1, submit_fn = function() end } }
  runtime.state.retry_generation = 7
  runtime.state.curl_jobs = {
    fake = {
      id = "fake",
      opts = { keep_output = false },
      cfg_path = cfgp,
      hdr_path = hdrp,
      err_path = errp,
      meta_path = metap,
      out_path = outp,
      payload_path = nil
    }
  }
  runtime.state.curl_jobs_selected_id = "fake"

  local ok = Jobs.reset_runtime("unit reset")
  local queue_sz = #runtime.state.cleanup_queue
  local passed =
    ok and
    (runtime.state.pending_job == nil) and
    (runtime.state.wait_until == nil) and
    (runtime.state.running_label == nil) and
    (runtime.state.ui_lock_network_buttons == false) and
    (type(runtime.state.retry_queue) == "table" and #runtime.state.retry_queue == 0) and
    (type(runtime.state.curl_jobs) == "table" and next(runtime.state.curl_jobs) == nil) and
    (runtime.state.curl_jobs_selected_id == nil) and
    (stats.events.runtime_reset >= 1) and
    (queue_sz >= 4)
  Helpers.log_result(
    test_id,
    passed,
    "ok=" .. tostring(ok) ..
      "; cleanup_queue=" .. tostring(queue_sz) ..
      "; runtime_reset_events=" .. tostring(stats.events.runtime_reset)
  )
end

-- What this function does: Deletes files under sandbox_root after safety checks.
-- How it is used: Triggered by the "Manual cleanup sandbox (destructive)" button.
function TestCases.run_manual_cleanup_sandbox()
  local test_id = "cleanup_sandbox"
  Helpers.log_step(test_id, "Starting cleanup")
  local ok_guard, guard_err = Helpers.guard_destructive_path(runtime.sandbox_root)
  if not ok_guard then
    Helpers.log_result(test_id, false, guard_err)
    return
  end
  local ok, msg = Files.remove_all_files_in_dir(runtime.sandbox_root)
  local text = tostring(msg or "")
  local benign_empty = text:find("Folder empty", 1, true) ~= nil or text:find("No files", 1, true) ~= nil
  Helpers.log_result(test_id, ok or benign_empty, "ok=" .. tostring(ok) .. "; msg=" .. text)
end

-- ============================================================================
-- Async curl test runtime/UI helpers (non-blocking row model).
-- ============================================================================

function AsyncRows.parse_live_timeout_sec()
  return Util.parse_number(INPUTS.request_timeout_sec, 45, 0.2)
end

function AsyncRows.parse_live_max_retry()
  return Util.parse_int(INPUTS.max_retry, 2, 1)
end

function AsyncRows.set_status(msg)
  local txt = tostring(msg or "")
  ui_state.status_text = txt
  if runtime.state then
    runtime.state.status_text = txt
  end
end

function AsyncRows.add_warning(msg)
  local txt = tostring(msg or "Unknown warning.")
  if txt == "" then txt = "Unknown warning." end
  table.insert(ui_state.warnings, txt)
end

function AsyncRows.clear_warnings()
  ui_state.warnings = {}
end

function AsyncRows.row_run_ref(row)
  if not row or row._run_link_disabled then return nil end
  if not row.test_run_id then return nil end
  return ui_state.test_runs[row.test_run_id]
end

function AsyncRows.is_row_terminal(row)
  if not row then return false end
  return row._state == "ok" or row._state == "failed_final" or row._state == "skipped" or row._state == "canceled"
end

function AsyncRows.active_async_rows()
  for i = 1, #ui_state.request_rows do
    local row = ui_state.request_rows[i]
    if row and (not AsyncRows.is_row_terminal(row)) then
      return true
    end
  end
  return false
end

function AsyncRows.clip_text(s, max_len)
  local txt = tostring(s or "")
  local m = tonumber(max_len) or 140
  if #txt <= m then return txt end
  return txt:sub(1, m) .. "... (" .. tostring(#txt - m) .. " more)"
end

function AsyncRows.provider_label(provider)
  local p = tostring(provider or "")
  if p == "httpbin" or p == "postman" or p == "httpbun" then
    return Helpers.provider_name(p)
  end
  if p == "" then return "-" end
  return p
end

function AsyncRows.classify_row_bucket(row, job)
  if row.result_status == "ok" or row._state == "ok" then return "ok" end
  if row.result_status == "skip" or row._state == "skipped" then return "skipped" end
  if row.result_status == "fail" or row._state == "failed_final" then return "failed" end
  if row.result_status == "canceled" or row._state == "canceled" then return "canceled" end
  if row._state == "retrying" then return "retrying" end
  if job then
    if job.phase == "running" then return "running" end
    if job.phase == "created" or job.phase == "launched" then return "queued" end
  end
  return "queued"
end

function AsyncRows.build_status_summary()
  local counts = {
    queued = 0,
    running = 0,
    retrying = 0,
    ok = 0,
    failed = 0,
    skipped = 0,
    canceled = 0
  }
  for i = 1, #ui_state.request_rows do
    local row = ui_state.request_rows[i]
    local job = runtime.state and row and row.job_id and runtime.state.curl_jobs and runtime.state.curl_jobs[row.job_id] or nil
    local bucket = AsyncRows.classify_row_bucket(row, job)
    counts[bucket] = (counts[bucket] or 0) + 1
  end
  local line = table.concat({
    "Queued " .. tostring(counts.queued),
    "Running " .. tostring(counts.running),
    "Retrying " .. tostring(counts.retrying),
    "OK " .. tostring(counts.ok),
    "Failed " .. tostring(counts.failed),
    "Skipped " .. tostring(counts.skipped),
    "Canceled " .. tostring(counts.canceled)
  }, " | ")
  if #ui_state.warnings > 0 then
    line = line .. " | Warnings: " .. tostring(#ui_state.warnings)
  end
  return {
    line = line,
    counts = counts
  }
end

function UI.render_status_panel_inline()
  local summary = AsyncRows.build_status_summary()
  local has_running = (summary.counts.running or 0) > 0 or (summary.counts.retrying or 0) > 0 or (summary.counts.queued or 0) > 0
  if has_running then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xF0F000FF)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00FF00FF)
  end
  ImGui.Text(ctx, "Status: " .. tostring(summary.line))
  ImGui.PopStyleColor(ctx)

  local last = tostring(ui_state.status_text or "")
  if last == "" then last = tostring(ui_state.last_status_text or "(none)") end
  ImGui.TextWrapped(ctx, "Last status: " .. last)

  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, "Warnings")
  else
    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Warnings")
  end
  if #ui_state.warnings == 0 then
    ImGui.TextWrapped(ctx, "None. Looks good!")
  else
    for i = 1, #ui_state.warnings do
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFB000FF)
      ImGui.TextWrapped(ctx, "WARN: " .. tostring(ui_state.warnings[i]))
      ImGui.PopStyleColor(ctx)
    end
  end
  if ImGui.Button(ctx, "Clear warnings") then
    AsyncRows.clear_warnings()
  end
end

function UI.render_cleanup_telemetry_panel()
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, "Cleanup Telemetry")
  else
    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Cleanup Telemetry")
  end

  if not runtime.ready or not runtime.state then
    ImGui.TextWrapped(ctx, "Runtime not initialized.")
    return
  end

  local queue_sz = #((runtime.state and runtime.state.cleanup_queue) or {})
  local failure_rows = Helpers.collect_cleanup_failure_rows()
  local failure_count = #failure_rows
  local last = ui_state.cleanup_last_tick or fresh_cleanup_last_tick()
  local totals = ui_state.cleanup_totals or fresh_cleanup_totals()

  ImGui.TextWrapped(
    ctx,
    "Queue=" .. tostring(queue_sz) .. " | Failures=" .. tostring(failure_count) .. " | Last remaining=" .. tostring(last.remaining or 0)
  )
  ImGui.TextWrapped(
    ctx,
    "Last tick: attempted=" .. tostring(last.attempted or 0) ..
      " deleted=" .. tostring(last.deleted or 0) ..
      " retry=" .. tostring(last.retry_scheduled or 0) ..
      " skipped=" .. tostring(last.skipped_not_due or 0) ..
      " gave_up=" .. tostring(last.gave_up or 0)
  )
  ImGui.TextWrapped(
    ctx,
    "Totals: attempted=" .. tostring(totals.attempted or 0) ..
      " deleted=" .. tostring(totals.deleted or 0) ..
      " retry=" .. tostring(totals.retry_scheduled or 0) ..
      " skipped=" .. tostring(totals.skipped_not_due or 0) ..
      " gave_up=" .. tostring(totals.gave_up or 0)
  )

  if ImGui.Button(ctx, "Clear cleanup failures (all)") then
    local ok, err = Cleanup.clear_cleanup_failures(nil)
    if ok then
      ui_state.cleanup_warned_paths = {}
      ui_state.cleanup_selected_failure_path = nil
      AsyncRows.set_status("Cleanup failures cleared (all).")
    else
      AsyncRows.add_warning("Failed to clear cleanup failures: " .. tostring(err))
      AsyncRows.set_status("Failed to clear cleanup failures.")
    end
  end

  if ui_state.cleanup_selected_failure_path and ui_state.cleanup_selected_failure_path ~= "" then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Clear selected cleanup failure") then
      local path = tostring(ui_state.cleanup_selected_failure_path)
      local ok, err = Cleanup.clear_cleanup_failures(path)
      if ok then
        if type(ui_state.cleanup_warned_paths) == "table" then
          ui_state.cleanup_warned_paths[path] = nil
        end
        ui_state.cleanup_selected_failure_path = nil
        AsyncRows.set_status("Cleanup failure cleared: " .. path)
      else
        AsyncRows.add_warning("Failed to clear cleanup failure: " .. tostring(err))
        AsyncRows.set_status("Failed to clear selected cleanup failure.")
      end
    end
  end

  if failure_count == 0 then
    ImGui.TextWrapped(ctx, "No cleanup failures recorded.")
    return
  end

  ImGui.Text(ctx, "Failures")
  if ImGui.BeginTable then
    local tbl_flags =
      ImGui.TableFlags_Borders |
      ImGui.TableFlags_RowBg |
      ImGui.TableFlags_Resizable |
      ImGui.TableFlags_ScrollY
    local h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 7) or 180
    if ImGui.BeginTable(ctx, "##cleanup_failures_table", 6, tbl_flags, -1, h) then
      ImGui.TableSetupColumn(ctx, "Path", ImGui.TableColumnFlags_WidthStretch, 230)
      ImGui.TableSetupColumn(ctx, "Why", ImGui.TableColumnFlags_WidthFixed, 120)
      ImGui.TableSetupColumn(ctx, "Attempts", ImGui.TableColumnFlags_WidthFixed, 90)
      ImGui.TableSetupColumn(ctx, "Fail#", ImGui.TableColumnFlags_WidthFixed, 60)
      ImGui.TableSetupColumn(ctx, "Last Failed", ImGui.TableColumnFlags_WidthFixed, 140)
      ImGui.TableSetupColumn(ctx, "Error", ImGui.TableColumnFlags_WidthStretch, 260)
      ImGui.TableHeadersRow(ctx)

      for i = 1, #failure_rows do
        local row = failure_rows[i]
        ImGui.TableNextRow(ctx)

        ImGui.TableSetColumnIndex(ctx, 0)
        local selected = (ui_state.cleanup_selected_failure_path == row.path)
        if ImGui.Selectable(ctx, AsyncRows.clip_text(row.path, 88), selected) then
          ui_state.cleanup_selected_failure_path = row.path
        end

        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, AsyncRows.clip_text(row.why, 34))

        ImGui.TableSetColumnIndex(ctx, 2)
        ImGui.Text(ctx, tostring(row.attempts) .. "/" .. tostring(row.max_attempts))

        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.Text(ctx, tostring(row.fail_count))

        ImGui.TableSetColumnIndex(ctx, 4)
        ImGui.TextWrapped(ctx, tostring(row.last_failed_at_str))

        ImGui.TableSetColumnIndex(ctx, 5)
        ImGui.TextWrapped(ctx, AsyncRows.clip_text(row.last_error, 120))
      end
      ImGui.EndTable(ctx)
    end
  else
    for i = 1, #failure_rows do
      local row = failure_rows[i]
      local selected_mark = (ui_state.cleanup_selected_failure_path == row.path) and "[selected] " or ""
      ImGui.TextWrapped(
        ctx,
        selected_mark ..
        AsyncRows.clip_text(row.path, 90) ..
        " | " .. tostring(row.attempts) .. "/" .. tostring(row.max_attempts) ..
        " | fail# " .. tostring(row.fail_count) ..
        " | " .. AsyncRows.clip_text(row.last_error, 90)
      )
      if ImGui.Button(ctx, "Select##cleanup_fail_" .. tostring(i)) then
        ui_state.cleanup_selected_failure_path = row.path
      end
    end
  end
end

function AsyncRows.format_row_progress(row, job)
  if row._state == "canceled" or row.result_status == "canceled" then return "canceled" end
  if row._state == "skipped" or row.result_status == "skip" then return "skip" end
  if row._state == "ok" or row.result_status == "ok" then return "ok" end
  if row._state == "failed_final" or row.result_status == "fail" then return "failed" end
  if row._state == "retrying" then
    if row._next_retry_at then
      local remaining = row._next_retry_at - Helpers.now_sec()
      if remaining < 0 then remaining = 0 end
      return string.format("retry in %.1fs", remaining)
    end
    return "retrying"
  end
  if job then
    if job.phase == "running" then
      local flow_line = job.progress and job.progress.flow and job.progress.flow.line
      if type(flow_line) == "string" and flow_line ~= "" then
        return flow_line
      end
      return "running"
    end
    if job.phase == "created" or job.phase == "launched" then
      return "queued"
    end
  end
  if row.progress_text and row.progress_text ~= "" then return row.progress_text end
  return tostring(row._state or "queued")
end

function AsyncRows.can_retry_row(row)
  if not row or type(row._retry_submit) ~= "function" then return false end
  local run = AsyncRows.row_run_ref(row)
  if run and (not run.finalized) then return false end
  if row.result_status ~= "fail" then return false end
  return row._state == "failed_final"
end

function AsyncRows.can_cancel_row(row)
  if not row then return false end
  if row._state == "canceled" then return false end
  if row._state == "ok" or row._state == "failed_final" or row._state == "skipped" then return false end
  return true
end

function AsyncRows.create_test_run(test_id, expected_parts, finish_fn, poll_fn)
  local run_id = "run_" .. tostring(ui_state.next_run_seq) .. "_" .. tostring(Util.date_time_stamp_with_time_precise())
  ui_state.next_run_seq = ui_state.next_run_seq + 1
  local run = {
    run_id = run_id,
    test_id = test_id,
    expected_parts = math.max(1, tonumber(expected_parts) or 1),
    done_parts = 0,
    parts = {},
    parts_by_row_id = {},
    finalized = false,
    finish_fn = finish_fn,
    poll_fn = poll_fn,
    created_at = Helpers.now_sec()
  }
  ui_state.test_runs[run_id] = run
  return run
end

function AsyncRows.finish_single_part_run(run)
  local part = run.parts[1]
  if not part then
    Helpers.log_result(run.test_id, false, "missing async result")
    return
  end
  if part.status == "ok" then
    Helpers.log_result(run.test_id, true, part.detail or "ok")
    return
  end
  if part.status == "skip" then
    Helpers.mark_skip(run.test_id, part.detail or "skipped")
    return
  end
  if part.status == "canceled" then
    Helpers.log_result(run.test_id, false, part.detail or "canceled by user")
    return
  end
  Helpers.log_result(run.test_id, false, part.detail or "failed")
end

function AsyncRows.maybe_finalize_test_run(run)
  if not run or run.finalized then return end
  if run.done_parts < run.expected_parts then return end
  if run.poll_fn and run.poll_fn(run) ~= true then
    return
  end
  run.finalized = true
  if type(run.finish_fn) == "function" then
    run.finish_fn(run)
  else
    AsyncRows.finish_single_part_run(run)
  end
end

function AsyncRows.mark_run_part_done(row, status, detail, result, submit_err, meta)
  if not row then return end
  if row._part_done then return end
  row._part_done = true
  row.completed_at = Helpers.now_sec()

  local run = AsyncRows.row_run_ref(row)
  if not run then
    return
  end
  local part = {
    row_id = row.id,
    status = status or "fail",
    detail = detail or "",
    result = result,
    submit_err = submit_err,
    meta = meta or {}
  }
  run.parts[#run.parts + 1] = part
  run.parts_by_row_id[row.id] = part
  run.done_parts = run.done_parts + 1
  AsyncRows.maybe_finalize_test_run(run)
end

function AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
  if submit_err then
    if Helpers.has_network_instability(nil, submit_err) then
      return "skip", "provider unstable (" .. Helpers.provider_name(provider) .. "): " .. tostring(submit_err)
    end
    return "fail", "submit failed: " .. tostring(submit_err)
  end
  if not result then
    return "fail", "missing result"
  end
  if result.ok then
    return "ok", ""
  end
  local http = tonumber(result.http_code)
  if (http and http >= 500) or Helpers.has_network_instability(result, nil) then
    return "skip", "provider unstable (" .. Helpers.provider_name(provider) .. "): http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err)
  end
  return "fail", "unexpected non-ok result: http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err)
end

function AsyncRows.should_auto_retry_row(row, spec, result, submit_err, verdict)
  if ui_state.auto_retry ~= true then return false end
  if spec and spec.allow_auto_retry == false then return false end
  local max_attempts = AsyncRows.parse_live_max_retry()
  row._max_attempts = max_attempts
  local current_attempt = tonumber(row._attempt) or 1
  if current_attempt >= max_attempts then return false end
  if verdict and verdict.retryable ~= nil then
    return verdict.retryable == true
  end
  if submit_err then
    return Helpers.has_network_instability(nil, submit_err)
  end
  return Jobs.is_retryable_result(result) == true
end

function AsyncRows.apply_terminal_row_state(row, status, detail, result)
  if status == "ok" then
    row._state = "ok"
    row.result_status = "ok"
    row.error_text = ""
  elseif status == "skip" then
    row._state = "skipped"
    row.result_status = "skip"
    row.error_text = detail
  elseif status == "canceled" then
    row._state = "canceled"
    row.result_status = "canceled"
    row.error_text = detail
  else
    row._state = "failed_final"
    row.result_status = "fail"
    row.error_text = detail
  end
  row.completed_at = Helpers.now_sec()
  row.http_code = result and result.http_code or row.http_code
  row.exitcode = result and result.exitcode or row.exitcode
end

function AsyncRows.finalize_row_verdict(row, run_ctx, spec, result, submit_err, verdict, submit_meta)
  if not row or row._part_done then return end
  local decision = verdict or {}
  local status = tostring(decision.status or "fail")
  local detail = tostring(decision.detail or "")
  local meta = decision.meta or {}
  if submit_meta and type(submit_meta) == "table" then
    for k, v in pairs(submit_meta) do
      meta[k] = v
    end
  end

  if status ~= "ok" and status ~= "skip" and status ~= "canceled" and AsyncRows.should_auto_retry_row(row, spec, result, submit_err, decision) then
    local next_attempt = (tonumber(row._attempt) or 1) + 1
    row._attempt = next_attempt
    row._max_attempts = AsyncRows.parse_live_max_retry()
    local ok_retry, retry_err = Jobs.enqueue_retry(
      row._retry_label or row.request_label or "retry",
      row._retry_submit,
      next_attempt,
      row._max_attempts,
      detail,
      row
    )
    if ok_retry then
      row.result_status = nil
      row.progress_text = "retry scheduled"
      AsyncRows.set_status("Retry scheduled: " .. tostring(row.request_label) .. " (" .. tostring(next_attempt) .. "/" .. tostring(row._max_attempts) .. ")")
      return
    end
    detail = detail .. "; retry enqueue failed: " .. tostring(retry_err)
    AsyncRows.add_warning(detail)
  end

  AsyncRows.apply_terminal_row_state(row, status, detail, result)
  if detail ~= "" and (status == "fail" or status == "skip") then
    AsyncRows.add_warning(detail)
  end
  AsyncRows.mark_run_part_done(row, status, detail, result, submit_err, meta)
end
AsyncRows.submit_row_attempt = function(row, run_ctx, spec)
  if not row or not spec then return end
  if row._state == "canceled" then return end

  row._attempt = tonumber(row._attempt) or 1
  row._max_attempts = AsyncRows.parse_live_max_retry()
  local timeout_override = nil
  if spec.timeout_sec_override ~= nil then
    if type(spec.timeout_sec_override) == "function" then
      local ok_to, val_to = pcall(spec.timeout_sec_override, row, run_ctx)
      if ok_to then timeout_override = tonumber(val_to) end
    else
      timeout_override = tonumber(spec.timeout_sec_override)
    end
  end
  if timeout_override == nil or timeout_override <= 0 then
    timeout_override = AsyncRows.parse_live_timeout_sec()
  end
  row.timeout_used_sec = timeout_override
  row.result_status = nil
  row.progress_text = "queued"
  row.error_text = ""
  row._state = "queued"
  row.created_at = row.created_at or Helpers.now_sec()
  row._part_done = false
  row._next_retry_at = nil

  local req, req_err = spec.req_factory(row, run_ctx)
  if not req then
    local verdict = {
      status = "fail",
      detail = "request build failed: " .. tostring(req_err),
      retryable = false,
      meta = { submitted = false }
    }
    AsyncRows.finalize_row_verdict(row, run_ctx, spec, nil, req_err, verdict, { submitted = false })
    return
  end

  row.method = req.method or row.method
  row.url = req.url or row.url
  row.request_label = req.label or row.request_label
  row.input_path = req.input_path
  row.output_path = req.download_path or req.output_path or row.output_path

  local read_body = (spec.read_body == true)
  local opts = Helpers.pick_opts(read_body, row.timeout_used_sec, spec.keep_output_override, spec.use_payload_file_override)
  local on_done = function(result, job)
    if row._state == "canceled" or row.canceled_by_user then
      return
    end
    row.job_id = job and job.id or row.job_id
    row.http_code = result and result.http_code or row.http_code
    row.exitcode = result and result.exitcode or row.exitcode
    row.error_text = tostring((result and result.err) or "")
    row.progress_text = ""
    if runtime.state and type(Curl.update_last_curl_state) == "function" then
      Curl.update_last_curl_state(result, job, row.request_label)
    end
    local ok_v, verdict_or_err = pcall(spec.validator, row, result, nil)
    local verdict = nil
    if ok_v and type(verdict_or_err) == "table" then
      verdict = verdict_or_err
    else
      verdict = {
        status = "fail",
        detail = "validator error: " .. tostring(verdict_or_err),
        retryable = false,
        meta = {}
      }
    end
    AsyncRows.finalize_row_verdict(row, run_ctx, spec, result, nil, verdict, { submitted = true })
  end

  local job, submit_err = Curl.curl_submit(req, on_done, opts)
  if not job then
    row.progress_text = "submit failed"
    local ok_v, verdict_or_err = pcall(spec.validator, row, nil, submit_err)
    local verdict = nil
    if ok_v and type(verdict_or_err) == "table" then
      verdict = verdict_or_err
    else
      verdict = {
        status = "fail",
        detail = "submit failed: " .. tostring(submit_err),
        retryable = Helpers.has_network_instability(nil, submit_err),
        meta = {}
      }
    end
    AsyncRows.finalize_row_verdict(row, run_ctx, spec, nil, submit_err, verdict, { submitted = false })
    return
  end

  row.job_id = job.id
  row.progress_text = "queued"
  AsyncRows.set_status("Queued: " .. tostring(row.request_label) .. " (" .. tostring(row._attempt) .. "/" .. tostring(row._max_attempts) .. ")")
end

function AsyncRows.submit_request_row(run_ctx, spec)
  local row_id = "row_" .. tostring(ui_state.next_row_seq)
  ui_state.next_row_seq = ui_state.next_row_seq + 1
  local row = {
    id = row_id,
    test_id = spec.test_id or (run_ctx and run_ctx.test_id) or "unknown_test",
    test_run_id = run_ctx and run_ctx.run_id or nil,
    request_label = spec.request_label or "request",
    provider = spec.provider or "n/a",
    method = spec.method or "GET",
    url = spec.url or "",
    job_id = nil,
    created_at = Helpers.now_sec(),
    completed_at = nil,
    _state = "queued",
    _attempt = 1,
    _max_attempts = AsyncRows.parse_live_max_retry(),
    _retry_label = spec.request_label or "request",
    _retry_submit = nil,
    _next_retry_at = nil,
    _retry_generation = runtime.state and runtime.state.retry_generation or 0,
    _part_done = false,
    _run_link_disabled = false,
    http_code = nil,
    exitcode = nil,
    error_text = "",
    progress_text = "queued",
    timeout_used_sec = AsyncRows.parse_live_timeout_sec(),
    canceled_by_user = false,
    result_status = nil,
    _spec = spec
  }

  row._retry_submit = function()
    local run_ref = AsyncRows.row_run_ref(row)
    AsyncRows.submit_row_attempt(row, run_ref, row._spec)
  end

  table.insert(ui_state.request_rows, row)
  ui_state.rows_by_id[row.id] = row
  AsyncRows.submit_row_attempt(row, run_ctx, spec)
  return row
end

function AsyncRows.mark_row_canceled(row, reason)
  if not row then return end
  local why = tostring(reason or "canceled by user")
  row.canceled_by_user = true
  local ok, err = Jobs.cancel_record(row, why)
  if not ok then
    AsyncRows.add_warning("Cancel failed: " .. tostring(err))
    AsyncRows.set_status("Cancel failed: " .. tostring(err))
    return
  end
  AsyncRows.apply_terminal_row_state(row, "canceled", why, nil)
  AsyncRows.set_status("Canceled: " .. tostring(row.request_label))
  if not row._part_done then
    AsyncRows.mark_run_part_done(row, "canceled", why, nil, nil, { submitted = (row.job_id ~= nil) })
  end
end

function AsyncRows.clear_async_table_and_runtime()
  ui_state.request_rows = {}
  ui_state.rows_by_id = {}
  ui_state.test_runs = {}
  ui_state.next_row_seq = 1
  ui_state.next_run_seq = 1
  Helpers.clear_upload_source_file("async table reset")
  if runtime.ready then
    Jobs.reset_runtime("reset async table")
  end
  Helpers.reset_cleanup_ui_telemetry()
  AsyncRows.set_status("Async table cleared and runtime reset.")
end

function AsyncRows.poll_async_rows_and_runs()
  if runtime.ready then
    local tick_stats = Jobs.tick_all()
    Helpers.update_cleanup_telemetry_from_tick(tick_stats)
  end

  for i = 1, #ui_state.request_rows do
    local row = ui_state.request_rows[i]
    if row and (not AsyncRows.is_row_terminal(row)) and runtime.state and runtime.state.curl_jobs then
      local job = row.job_id and runtime.state.curl_jobs[row.job_id] or nil
      if job then
        if job.phase == "running" then
          row._state = "running"
        elseif job.phase == "created" or job.phase == "launched" then
          row._state = "queued"
        end
      end
    end
  end

  for _, run in pairs(ui_state.test_runs) do
    AsyncRows.maybe_finalize_test_run(run)
  end
end

function UI.draw_request_progress_table()
  if #ui_state.request_rows == 0 then
    ImGui.TextWrapped(ctx, "No async request rows yet.")
    return
  end
  if not ImGui.BeginTable then
    ImGui.TextWrapped(ctx, "Table rendering not available in this ImGui build.")
    return
  end

  local running_rows = {}
  for i = 1, #ui_state.request_rows do
    local row = ui_state.request_rows[i]
    local job = runtime.state and runtime.state.curl_jobs and row.job_id and runtime.state.curl_jobs[row.job_id] or nil
    if job and job.phase == "running" then
      table.insert(running_rows, { row = row, job = job })
    end
  end

  ImGui.Text(ctx, "Running meter table")
  if #running_rows == 0 then
    ImGui.TextWrapped(ctx, "No running requests.")
  else
    local running_table_flags =
      ImGui.TableFlags_Borders |
      ImGui.TableFlags_RowBg |
      ImGui.TableFlags_Resizable |
      ImGui.TableFlags_ScrollY |
      ImGui.TableFlags_ScrollX
    local running_table_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 10) or 220
    local running_total_columns = 3 + #ASYNC_METER_COLUMNS + 1
    if ImGui.BeginTable(ctx, "##curl_jobs_running_meter_table", running_total_columns, running_table_flags, -1, running_table_h) then
      ImGui.TableSetupColumn(ctx, "Test", ImGui.TableColumnFlags_WidthFixed, 130)
      ImGui.TableSetupColumn(ctx, "Provider", ImGui.TableColumnFlags_WidthFixed, 110)
      ImGui.TableSetupColumn(ctx, "Progress", ImGui.TableColumnFlags_WidthFixed, 120)
      for i = 1, #ASYNC_METER_COLUMNS do
        local col = ASYNC_METER_COLUMNS[i]
        ImGui.TableSetupColumn(ctx, col.header, ImGui.TableColumnFlags_WidthFixed, col.width)
      end
      ImGui.TableSetupColumn(ctx, "MUpd", ImGui.TableColumnFlags_WidthFixed, 80)
      ImGui.TableHeadersRow(ctx)

      for i = 1, #running_rows do
        local item = running_rows[i]
        local row = item.row
        local job = item.job
        ImGui.TableNextRow(ctx)

        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.Text(ctx, AsyncRows.clip_text(row.test_id, 22))

        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.TextWrapped(ctx, tostring(AsyncRows.provider_label(row.provider)))

        ImGui.TableSetColumnIndex(ctx, 2)
        local flow_line = job.progress and job.progress.flow and job.progress.flow.line
        if type(flow_line) ~= "string" or flow_line == "" then flow_line = "running" end
        ImGui.TextWrapped(ctx, flow_line)

        local col_idx = 3
        for j = 1, #ASYNC_METER_COLUMNS do
          local meter_col = ASYNC_METER_COLUMNS[j]
          ImGui.TableSetColumnIndex(ctx, col_idx)
          local meter_val = job.progress and job.progress.meter and job.progress.meter[meter_col.key]
          local txt = tostring(meter_val or "")
          if txt == "" then txt = "-" end
          ImGui.Text(ctx, txt)
          col_idx = col_idx + 1
        end

        ImGui.TableSetColumnIndex(ctx, col_idx)
        local ts = job.progress and tonumber(job.progress.meter_updated_at) or nil
        if ts == nil then
          ImGui.Text(ctx, "-")
        else
          local age = Helpers.now_sec() - ts
          if age < 0 then age = 0 end
          ImGui.Text(ctx, string.format("%.1fs ago", age))
        end
      end
      ImGui.EndTable(ctx)
    end
  end

  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Request progress table")
  local table_flags =
    ImGui.TableFlags_Borders |
    ImGui.TableFlags_RowBg |
    ImGui.TableFlags_Resizable |
    ImGui.TableFlags_ScrollY |
    ImGui.TableFlags_ScrollX
  local table_h = ImGui.GetTextLineHeight and (ImGui.GetTextLineHeight(ctx) * 16) or 300
  local total_columns = 7
  if ImGui.BeginTable(ctx, "##curl_jobs_progress_table", total_columns, table_flags, -1, table_h) then
    ImGui.TableSetupColumn(ctx, "Test", ImGui.TableColumnFlags_WidthFixed, 130)
    ImGui.TableSetupColumn(ctx, "Provider", ImGui.TableColumnFlags_WidthFixed, 110)
    ImGui.TableSetupColumn(ctx, "Progress", ImGui.TableColumnFlags_WidthFixed, 110)
    ImGui.TableSetupColumn(ctx, "Attempts", ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableSetupColumn(ctx, "Timeout", ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableSetupColumn(ctx, "HTTP", ImGui.TableColumnFlags_WidthFixed, 60)
    ImGui.TableSetupColumn(ctx, "Actions", ImGui.TableColumnFlags_WidthFixed, 150)
    ImGui.TableHeadersRow(ctx)

    for i = 1, #ui_state.request_rows do
      local row = ui_state.request_rows[i]
      local job = runtime.state and runtime.state.curl_jobs and row.job_id and runtime.state.curl_jobs[row.job_id] or nil
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.Text(ctx, AsyncRows.clip_text(row.test_id, 22))

      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.TextWrapped(ctx, tostring(AsyncRows.provider_label(row.provider)))

      ImGui.TableSetColumnIndex(ctx, 2)
      ImGui.TextWrapped(ctx, AsyncRows.format_row_progress(row, job))

      ImGui.TableSetColumnIndex(ctx, 3)
      ImGui.Text(ctx, tostring(row._attempt or 1) .. "/" .. tostring(row._max_attempts or AsyncRows.parse_live_max_retry()))

      ImGui.TableSetColumnIndex(ctx, 4)
      ImGui.Text(ctx, string.format("%.1fs", tonumber(row.timeout_used_sec) or 0))

      ImGui.TableSetColumnIndex(ctx, 5)
      ImGui.Text(ctx, tostring(row.http_code or "-"))

      ImGui.TableSetColumnIndex(ctx, 6)
      local retry_enabled = AsyncRows.can_retry_row(row)
      if not retry_enabled then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, "Retry##" .. tostring(row.id)) then
        row._run_link_disabled = true
        row._part_done = false
        row.canceled_by_user = false
        row._max_attempts = AsyncRows.parse_live_max_retry()
        local ok, err = Jobs.manual_retry_record(row)
        if ok then
          row.result_status = nil
          row.error_text = ""
          AsyncRows.set_status("Retry queued: " .. tostring(row.request_label))
        else
          AsyncRows.add_warning("Retry failed: " .. tostring(err))
          AsyncRows.set_status("Retry failed: " .. tostring(err))
        end
      end
      if not retry_enabled then ImGui.EndDisabled(ctx) end
      ImGui.SameLine(ctx)

      local cancel_enabled = AsyncRows.can_cancel_row(row)
      if not cancel_enabled then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, "Cancel##" .. tostring(row.id)) then
        AsyncRows.mark_row_canceled(row, "canceled by user")
      end
      if not cancel_enabled then ImGui.EndDisabled(ctx) end
    end
    ImGui.EndTable(ctx)
  end
end

-- ============================================================================
-- Async curl/tls test handlers.
-- ============================================================================
TestCases.run_curl_json_get_echo_test = function()
  local test_id = "curl_json_get_echo"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("json")
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "curl_json_get_echo",
    read_body = true,
    req_factory = function()
      local req_url = Helpers.join_url(Helpers.provider_base(provider), PATHS.get) .. "?hello=world&n=42"
      return {
        label = "curl_json_get_echo",
        kind = "test_get",
        method = "GET",
        url = req_url
      }
    end,
    validator = function(_row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then return { status = st, detail = reason } end
      local body_tbl = Helpers.safe_json_decode(result.body)
      if not body_tbl then
        return { status = "fail", detail = "response body is not JSON", retryable = false }
      end
      local args = body_tbl.args or {}
      local ok_hello = tostring(args.hello or "") == "world"
      local ok_n = tostring(args.n or "") == "42"
      local passed = ok_hello and ok_n
      local details =
        "provider=" .. Helpers.provider_name(provider) .. "; http=" .. tostring(result.http_code) .. "; hello=" .. tostring(args.hello) .. "; n=" .. tostring(args.n)
      if passed then
        return { status = "ok", detail = details }
      end
      return { status = "fail", detail = details, retryable = false }
    end
  })
end
TestCases.run_curl_json_post_echo_test = function()
  local test_id = "curl_json_post_echo"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("json")
  local payload = { message = "hello-json", number = 123, tags = { "a", "b" } }
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "curl_json_post_echo",
    read_body = true,
    req_factory = function()
      local req_url = Helpers.join_url(Helpers.provider_base(provider), PATHS.post)
      return {
        label = "curl_json_post_echo",
        kind = "test_post",
        method = "POST",
        url = req_url,
        json_payload_tbl = payload,
        headers = { ["Content-Type"] = "application/json" }
      }
    end,
    validator = function(_row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then return { status = st, detail = reason } end
      local tbl = Helpers.safe_json_decode(result.body)
      if not tbl then
        return { status = "fail", detail = "response body is not JSON", retryable = false }
      end
      local got_message, got_number = nil, nil
      if type(tbl.json) == "table" then
        got_message = tbl.json.message
        got_number = tbl.json.number
      elseif type(tbl.data) == "table" then
        got_message = tbl.data.message
        got_number = tbl.data.number
      elseif type(tbl.data) == "string" and tbl.data ~= "" then
        local data_tbl = Helpers.safe_json_decode(tbl.data)
        if type(data_tbl) == "table" then
          got_message = data_tbl.message
          got_number = data_tbl.number
        end
      end
      local passed = (tostring(got_message or "") == payload.message) and (tonumber(got_number) == payload.number)
      local details =
        "provider=" .. Helpers.provider_name(provider) .. "; http=" .. tostring(result.http_code) ..
        "; message=" .. tostring(got_message) .. "; number=" .. tostring(got_number)
      if passed then
        return { status = "ok", detail = details }
      end
      return { status = "fail", detail = details, retryable = false }
    end
  })
end
TestCases.run_curl_auth_header_echo_test = function()
  local test_id = "curl_auth_header_echo"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("headers")
  local token = "Bearer test-token-abc"
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "curl_auth_header_echo",
    read_body = true,
    req_factory = function()
      local req_url = Helpers.join_url(Helpers.provider_base(provider), PATHS.headers)
      return {
        label = "curl_auth_header_echo",
        kind = "test_auth",
        method = "GET",
        url = req_url,
        headers = { ["Authorization"] = token }
      }
    end,
    validator = function(_row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then return { status = st, detail = reason } end
      local tbl = Helpers.safe_json_decode(result.body)
      if not tbl then
        return { status = "fail", detail = "response body is not JSON", retryable = false }
      end
      local echoed = Helpers.read_echo_header(tbl, "authorization") or ""
      local passed = echoed:find("test%-token%-abc", 1, false) ~= nil
      local details =
        "provider=" .. Helpers.provider_name(provider) .. "; http=" .. tostring(result.http_code) .. "; echoed_authorization=" .. tostring(echoed)
      if passed then
        return { status = "ok", detail = details }
      end
      return { status = "fail", detail = details, retryable = false }
    end
  })
end
TestCases.run_curl_large_upload_test = function()
  local test_id = "curl_large_upload_from_download_file"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local source_path, source_err = Helpers.get_upload_source_file()
  if not source_path then
    Helpers.log_result(test_id, false, tostring(source_err))
    return
  end
  local source_size = Files.file_size(source_path) or 0
  if source_size <= 0 then
    runtime.upload_source_path = nil
    Helpers.log_result(test_id, false, "upload source file is empty/missing: " .. tostring(source_path))
    return
  end
  local provider = Helpers.select_provider_for_role("upload")
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "curl_large_upload_from_download_file",
    read_body = true,
    timeout_sec_override = 1000,
    use_payload_file_override = true,
    req_factory = function()
      local req_url = Helpers.join_url(Helpers.provider_base(provider), PATHS.post)
      return {
        label = "curl_large_upload_from_download_file",
        kind = "test_upload",
        method = "POST",
        url = req_url,
        body_file_path = source_path,
        use_payload_file = true,
        headers = { ["Content-Type"] = "application/octet-stream" }
      }
    end,
    validator = function(_row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then return { status = st, detail = reason } end

      local echoed_len = nil
      local tbl = Helpers.safe_json_decode(result.body)
      if type(tbl) == "table" then
        if type(tbl.data) == "string" then
          echoed_len = #tbl.data
        elseif type(tbl.data) == "table" then
          local txt = json.encode(tbl.data)
          echoed_len = #tostring(txt or "")
        end
      end
      local uploaded_meta = tonumber(result.size_upload) or 0

      if provider == "httpbun" and echoed_len and echoed_len < source_size then
        return {
          status = "skip",
          detail = "provider " .. Helpers.provider_name(provider) .. " truncates echoed body in this endpoint (sent=" .. tostring(source_size) .. ", echoed=" .. tostring(echoed_len) .. ")"
        }
      end
      local http = tonumber(result.http_code) or 0
      if provider == "postman" and http >= 500 and source_size > 65536 then
        return {
          status = "skip",
          detail = "provider " .. Helpers.provider_name(provider) .. " rejected large source-file payload with HTTP " .. tostring(http)
        }
      end

      local passed = false
      if echoed_len ~= nil then
        passed = (echoed_len == source_size)
      else
        passed = (math.floor(uploaded_meta + 0.5) == source_size)
      end
      local details =
        "provider=" .. Helpers.provider_name(provider) ..
        "; source_path=" .. tostring(source_path) ..
        "; source_size=" .. tostring(source_size) ..
        "; echoed=" .. tostring(echoed_len) ..
        "; size_upload=" .. tostring(result.size_upload) ..
        "; http=" .. tostring(result.http_code)
      if passed then
        return { status = "ok", detail = details }
      end
      return { status = "fail", detail = details, retryable = false }
    end
  })
end
TestCases.run_curl_large_download_test = function()
  local test_id = "curl_large_download_source_file"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("download")
  local want_bytes = Util.parse_int(INPUTS.download_bytes, 1048576, 1)
  if provider == "httpbin" and want_bytes > 102400 then
    Helpers.mark_skip(test_id, "provider " .. Helpers.provider_name(provider) .. " /bytes endpoint is capped in practice (~100KB)")
    return
  end
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "curl_large_download_source_file",
    read_body = false,
    timeout_sec_override = 1000,
    keep_output_override = true,
    use_payload_file_override = true,
    req_factory = function(row)
      local req_path = Helpers.format_path_value(PATHS.download_fmt, want_bytes)
      local req_url = Helpers.join_url(Helpers.provider_base(provider), req_path)
      local out_path = Helpers.build_temp_download_path("single_download_" .. tostring(row.id))
      return {
        label = "curl_large_download_source_file",
        kind = "test_download",
        method = "GET",
        url = req_url,
        use_payload_file = true,
        download_path = out_path
      }
    end,
    validator = function(row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then
        Helpers.cleanup_path_if_needed(row.output_path)
        return { status = st, detail = reason }
      end
      local sz = Files.file_size(row.output_path) or 0
      local passed = sz >= want_bytes
      if passed then
        local ok_src, src_err = Helpers.set_upload_source_file(row.output_path)
        if not ok_src then
          Helpers.cleanup_path_if_needed(row.output_path)
          return {
            status = "fail",
            detail = "download completed but cannot retain source file: " .. tostring(src_err),
            retryable = false,
            meta = { size_ok = false }
          }
        end
      else
        Helpers.cleanup_path_if_needed(row.output_path)
      end
      local details =
        "provider=" .. Helpers.provider_name(provider) ..
        "; want_bytes=" .. tostring(want_bytes) ..
        "; file_size=" .. tostring(sz) ..
        "; retained_source=" .. tostring(runtime.upload_source_path or "(none)") ..
        "; http=" .. tostring(result.http_code)
      if passed then
        return { status = "ok", detail = details, meta = { size_ok = true, source_path = runtime.upload_source_path } }
      end
      return { status = "fail", detail = details, retryable = false, meta = { size_ok = false } }
    end
  })
end
TestCases.run_curl_concurrency_test = function()
  local test_id = "curl_concurrency_8x1mb"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("download")
  local n = Util.parse_int(INPUTS.concurrency, 8, 1)
  local want_bytes = Util.parse_int(INPUTS.download_bytes, 1048576, 1)
  if provider == "httpbin" and want_bytes > 102400 then
    Helpers.mark_skip(test_id, "provider " .. Helpers.provider_name(provider) .. " /bytes endpoint is capped in practice (~100KB)")
    return
  end

  local run = AsyncRows.create_test_run(test_id, n, function(run_done)
    local submitted = 0
    local ok_count = 0
    local size_ok_count = 0
    local net_fail_count = 0
    local submit_errors = {}
    for i = 1, #run_done.parts do
      local part = run_done.parts[i]
      local meta = part.meta or {}
      if meta.submitted == true then
        submitted = submitted + 1
      elseif part.submit_err then
        submit_errors[#submit_errors + 1] = tostring(part.submit_err)
      end
      if part.status == "ok" then ok_count = ok_count + 1 end
      if meta.size_ok then size_ok_count = size_ok_count + 1 end
      if meta.net_fail then net_fail_count = net_fail_count + 1 end
    end

    if submitted == 0 then
      Helpers.mark_skip(test_id, "no jobs submitted; errors=" .. table.concat(submit_errors, " | "))
      return
    end
    local success_ratio = ok_count / submitted
    local pass_ratio = 0.75
    if success_ratio >= pass_ratio then
      Helpers.log_result(
        test_id,
        true,
        "provider=" .. Helpers.provider_name(provider) ..
          "; submitted=" .. tostring(submitted) ..
          "; ok=" .. tostring(ok_count) ..
          "; size_ok=" .. tostring(size_ok_count) ..
          "; success_ratio=" .. string.format("%.2f", success_ratio)
      )
    elseif net_fail_count == submitted then
      Helpers.mark_skip(
        test_id,
        "provider unstable under load (" .. Helpers.provider_name(provider) .. "), success_ratio=" .. string.format("%.2f", success_ratio)
      )
    else
      Helpers.log_result(
        test_id,
        false,
        "provider=" .. Helpers.provider_name(provider) ..
          "; submitted=" .. tostring(submitted) ..
          "; ok=" .. tostring(ok_count) ..
          "; net_fail=" .. tostring(net_fail_count) ..
          "; success_ratio=" .. string.format("%.2f", success_ratio)
      )
    end
  end)

  for i = 1, n do
    local idx = i
    AsyncRows.submit_request_row(run, {
      test_id = test_id,
      provider = provider,
      request_label = "concurrency_" .. tostring(idx),
      read_body = false,
      keep_output_override = true,
      req_factory = function(row)
        local req_path = Helpers.format_path_value(PATHS.download_fmt, want_bytes)
        local req_url = Helpers.join_url(Helpers.provider_base(provider), req_path)
        local out_path = Helpers.build_temp_download_path("conc_" .. tostring(idx) .. "_" .. tostring(row.id))
        return {
          label = "concurrency_" .. tostring(idx),
          kind = "test_concurrency",
          method = "GET",
          url = req_url,
          download_path = out_path
        }
      end,
      validator = function(row, result, submit_err)
        if submit_err then
          Helpers.cleanup_path_if_needed(row.output_path)
          return {
            status = "fail",
            detail = "submit failed: " .. tostring(submit_err),
            retryable = Helpers.has_network_instability(nil, submit_err),
            meta = { submitted = false, net_fail = Helpers.has_network_instability(nil, submit_err) }
          }
        end
        if not result then
          Helpers.cleanup_path_if_needed(row.output_path)
          return { status = "fail", detail = "missing result", retryable = false, meta = { submitted = true, net_fail = false } }
        end
        if result.ok then
          local sz = Files.file_size(row.output_path) or 0
          local size_ok = sz >= want_bytes
          Helpers.cleanup_path_if_needed(row.output_path)
          return {
            status = "ok",
            detail = "http=" .. tostring(result.http_code) .. "; file_size=" .. tostring(sz),
            meta = { submitted = true, ok = true, size_ok = size_ok, net_fail = false }
          }
        end
        local http = tonumber(result.http_code)
        local net_fail = Helpers.has_network_instability(result, nil) or (http and http >= 500)
        Helpers.cleanup_path_if_needed(row.output_path)
        return {
          status = "fail",
          detail = "http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err),
          retryable = net_fail,
          meta = { submitted = true, ok = false, size_ok = false, net_fail = net_fail }
        }
      end
    })
  end
end
TestCases.run_curl_status_429_500_test = function()
  local test_id = "curl_status_429_and_500"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("status")
  local run = AsyncRows.create_test_run(test_id, 2, function(run_done)
    local p429 = nil
    local p500 = nil
    for i = 1, #run_done.parts do
      local part = run_done.parts[i]
      local code = part.meta and tonumber(part.meta.code) or nil
      if code == 429 then p429 = part end
      if code == 500 then p500 = part end
    end
    if p429 and p429.status == "skip" then
      Helpers.mark_skip(test_id, p429.detail)
      return
    end
    if p500 and p500.status == "skip" then
      Helpers.mark_skip(test_id, p500.detail)
      return
    end
    local ok429 = p429 and p429.status == "ok"
    local ok500 = p500 and p500.status == "ok"
    local passed = ok429 and ok500
    Helpers.log_result(
      test_id,
      passed,
      "provider=" .. Helpers.provider_name(provider) ..
        "; http429=" .. tostring(p429 and p429.meta and p429.meta.http_code) ..
        "; http500=" .. tostring(p500 and p500.meta and p500.meta.http_code)
    )
  end)

  local function submit_status_code(code)
    AsyncRows.submit_request_row(run, {
      test_id = test_id,
      provider = provider,
      request_label = "status_" .. tostring(code),
      read_body = true,
      allow_auto_retry = false,
      req_factory = function()
        local req_url = Helpers.join_url(Helpers.provider_base(provider), Helpers.format_path_value(PATHS.status_fmt, code))
        return {
          label = "status_" .. tostring(code),
          kind = "test_status",
          method = "GET",
          url = req_url
        }
      end,
      validator = function(_row, result, submit_err)
        if submit_err and Helpers.has_network_instability(nil, submit_err) then
          return {
            status = "skip",
            detail = "provider unstable (" .. Helpers.provider_name(provider) .. "): " .. tostring(submit_err),
            retryable = false,
            meta = { code = code, http_code = nil }
          }
        end
        if submit_err then
          return {
            status = "fail",
            detail = "submit failed: " .. tostring(submit_err),
            retryable = false,
            meta = { code = code, http_code = nil }
          }
        end
        if not result then
          return {
            status = "fail",
            detail = "missing result",
            retryable = false,
            meta = { code = code, http_code = nil }
          }
        end
        local expected_ok = (result.ok == false) and (tonumber(result.http_code) == code)
        local details = "expected HTTP " .. tostring(code) .. "; got http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err)
        if expected_ok then
          return { status = "ok", detail = details, retryable = false, meta = { code = code, http_code = result.http_code } }
        end
        return { status = "fail", detail = details, retryable = false, meta = { code = code, http_code = result.http_code } }
      end
    })
  end

  submit_status_code(429)
  submit_status_code(500)
end
TestCases.run_curl_timeout_delay_test = function()
  local test_id = "curl_timeout_via_delay"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("delay")
  local delay_sec = Util.parse_int(INPUTS.delay_seconds, 4, 1)
  local short_timeout = Util.parse_number(INPUTS.short_timeout_sec, 1, 0.2)
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "timeout_delay",
    read_body = true,
    allow_auto_retry = false,
    timeout_sec_override = short_timeout,
    req_factory = function()
      local req_url = Helpers.join_url(Helpers.provider_base(provider), Helpers.format_path_value(PATHS.delay_fmt, delay_sec))
      return {
        label = "timeout_delay",
        kind = "test_timeout",
        method = "GET",
        url = req_url
      }
    end,
    validator = function(_row, result, submit_err)
      if submit_err and Helpers.has_network_instability(nil, submit_err) then
        return { status = "skip", detail = "provider unstable (" .. Helpers.provider_name(provider) .. "): " .. tostring(submit_err), retryable = false }
      end
      if not result then
        return { status = "fail", detail = "missing result", retryable = false }
      end
      local timeout_like =
        (result.timed_out == true) or
        ((result.err or ""):lower():find("timeout", 1, true) ~= nil) or
        (tonumber(result.exitcode) ~= nil and tonumber(result.exitcode) ~= 0 and (result.err or ""):lower():find("tim", 1, true) ~= nil)
      if (result.ok == false) and timeout_like then
        return {
          status = "ok",
          detail = "provider=" .. Helpers.provider_name(provider) .. "; http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err),
          retryable = false
        }
      end
      if (result.ok == false) and Helpers.has_network_instability(result, nil) then
        return { status = "skip", detail = "provider/network instability during timeout test: " .. tostring(result.err), retryable = false }
      end
      return {
        status = "fail",
        detail = "expected timeout-like failure; got ok=" .. tostring(result.ok) .. "; http=" .. tostring(result.http_code) .. "; err=" .. tostring(result.err),
        retryable = false
      }
    end
  })
end
TestCases.run_curl_cleanup_queue_smoke_test = function()
  local test_id = "curl_cleanup_queue_smoke"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local provider = Helpers.select_provider_for_role("download")
  local bytes = math.min(Util.parse_int(INPUTS.download_bytes, 1048576, 1), 65536)
  local run = AsyncRows.create_test_run(
    test_id,
    1,
    function(run_done)
      local outcome = run_done._cleanup_outcome
      if not outcome then
        Helpers.log_result(test_id, false, "cleanup outcome missing")
        return
      end
      if outcome.status == "skip" then
        Helpers.mark_skip(test_id, outcome.detail)
        return
      end
      Helpers.log_result(test_id, outcome.status == "ok", outcome.detail)
    end,
    function(run_poll)
      local part = run_poll.parts[1]
      if not part then return false end
      if part.status ~= "ok" then
        run_poll._cleanup_outcome = { status = part.status, detail = part.detail }
        return true
      end

      local meta = part.meta or {}
      if not run_poll._cleanup_wait then
        run_poll._cleanup_wait = {
          started = Helpers.now_sec(),
          out_path = meta.out_path
        }
      end
      local wait_ctx = run_poll._cleanup_wait
      local elapsed = Helpers.now_sec() - wait_ctx.started
      local drained = (not runtime.state.cleanup_queue) or (#runtime.state.cleanup_queue == 0)
      if elapsed < 6.0 and not drained then
        return false
      end

      local exists = (wait_ctx.out_path and r.file_exists(wait_ctx.out_path) == true) or false
      if flags.keep_artifacts then
        run_poll._cleanup_outcome = {
          status = drained and "ok" or "fail",
          detail = "retain artifacts enabled; cleanup_queue_drained=" .. tostring(drained) .. "; output_exists=" .. tostring(exists)
        }
      else
        local passed = drained and (not exists)
        run_poll._cleanup_outcome = {
          status = passed and "ok" or "fail",
          detail = "cleanup_queue_drained=" .. tostring(drained) .. "; output_exists_after_cleanup=" .. tostring(exists)
        }
      end
      Helpers.cleanup_path_if_needed(wait_ctx.out_path)
      return true
    end
  )

  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = provider,
    request_label = "cleanup_smoke_download",
    read_body = false,
    keep_output_override = false,
    req_factory = function(row)
      local req_url = Helpers.join_url(Helpers.provider_base(provider), Helpers.format_path_value(PATHS.download_fmt, bytes))
      local out_path = Helpers.build_temp_download_path("cleanup_smoke_" .. tostring(row.id))
      return {
        label = "cleanup_smoke_download",
        kind = "test_cleanup",
        method = "GET",
        url = req_url,
        download_path = out_path
      }
    end,
    validator = function(row, result, submit_err)
      local st, reason = AsyncRows.classify_success_result_or_skip_reason(provider, result, submit_err)
      if st ~= "ok" then
        Helpers.cleanup_path_if_needed(row.output_path)
        return { status = st, detail = reason }
      end
      return {
        status = "ok",
        detail = "download completed; waiting for cleanup queue drain",
        meta = { out_path = row.output_path }
      }
    end
  })
end
TestCases.run_tls_expired_badssl_expected_fail_test = function()
  local test_id = "tls_expired_badssl_expected_fail"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = "badssl",
    request_label = "tls_expired",
    read_body = true,
    allow_auto_retry = false,
    req_factory = function()
      return {
        label = "tls_expired",
        kind = "tls_negative",
        method = "GET",
        url = PATHS.tls_url_expired
      }
    end,
    validator = function(_row, result, submit_err)
      if submit_err and Helpers.has_network_instability(nil, submit_err) then
        return { status = "skip", detail = "network/connectivity prevented TLS check: " .. tostring(submit_err), retryable = false }
      end
      if not result then
        return { status = "skip", detail = "missing result", retryable = false }
      end
      if result.ok == true then
        return { status = "fail", detail = "unexpected success against expired.badssl.com", retryable = false }
      end
      local err_txt = tostring(result.err or "") .. " " .. tostring(result.err_txt or "")
      local lower = err_txt:lower()
      local tls_like =
        (lower:find("ssl", 1, true) ~= nil) or
        (lower:find("tls", 1, true) ~= nil) or
        (lower:find("certificate", 1, true) ~= nil)
      if tls_like then
        return { status = "ok", detail = "expected TLS failure observed; err=" .. tostring(result.err), retryable = false }
      end
      return { status = "skip", detail = "request failed but not clearly TLS-related; err=" .. tostring(result.err), retryable = false }
    end
  })
end
TestCases.run_tls_self_signed_badssl_expected_fail_test = function()
  local test_id = "tls_self_signed_badssl_expected_fail"
  Helpers.log_step(test_id, "Starting (async)")
  if not Helpers.ensure_runtime(test_id) then return end
  local run = AsyncRows.create_test_run(test_id, 1, AsyncRows.finish_single_part_run)
  AsyncRows.submit_request_row(run, {
    test_id = test_id,
    provider = "badssl",
    request_label = "tls_self_signed",
    read_body = true,
    allow_auto_retry = false,
    req_factory = function()
      return {
        label = "tls_self_signed",
        kind = "tls_negative",
        method = "GET",
        url = PATHS.tls_url_self_signed
      }
    end,
    validator = function(_row, result, submit_err)
      if submit_err and Helpers.has_network_instability(nil, submit_err) then
        return { status = "skip", detail = "network/connectivity prevented TLS check: " .. tostring(submit_err), retryable = false }
      end
      if not result then
        return { status = "skip", detail = "missing result", retryable = false }
      end
      if result.ok == true then
        return { status = "fail", detail = "unexpected success against self-signed.badssl.com", retryable = false }
      end
      local err_txt = tostring(result.err or "") .. " " .. tostring(result.err_txt or "")
      local lower = err_txt:lower()
      local tls_like =
        (lower:find("ssl", 1, true) ~= nil) or
        (lower:find("tls", 1, true) ~= nil) or
        (lower:find("certificate", 1, true) ~= nil)
      if tls_like then
        return { status = "ok", detail = "expected TLS failure observed; err=" .. tostring(result.err), retryable = false }
      end
      return { status = "skip", detail = "request failed but not clearly TLS-related; err=" .. tostring(result.err), retryable = false }
    end
  })
end

-- What this function does: Forces runtime reinitialization and logs the result.
-- How it is used: Triggered by the "Reinitialize runtime (Curl + Jobs)" button.
function UI.reinit_runtime_button()
  Helpers.clear_upload_source_file("runtime reinit")
  Helpers.reset_cleanup_ui_telemetry()
  runtime.ready = false
  local ok = Helpers.init_runtime("runtime_reinit")
  Helpers.log_result("runtime_reinit", ok == true, "ok=" .. tostring(ok) .. "; tmp_dir=" .. tostring(runtime.sandbox_root))
end

-- What this function does: Draws provider mode UI and updates selected mode.
-- How it is used: Called from GuiLoop in the provider settings section.
function UI.draw_provider_mode_selector()
  local providers = PROVIDERS
  if ImGui.BeginCombo then
    local preview = providers.modes[providers.mode_idx] or providers.modes[1]
    if ImGui.BeginCombo(ctx, "provider_mode", preview) then
      for i = 1, #providers.modes do
        local selected = (i == providers.mode_idx)
        if ImGui.Selectable(ctx, providers.modes[i], selected) then
          providers.mode_idx = i
        end
        if selected and ImGui.SetItemDefaultFocus then
          ImGui.SetItemDefaultFocus(ctx)
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    local changed, new_val = ImGui.SliderInt(ctx, "provider_mode_idx", providers.mode_idx, 1, #providers.modes)
    if changed then
      providers.mode_idx = new_val
    end
    ImGui.Text(ctx, "provider_mode: " .. tostring(providers.modes[providers.mode_idx]))
  end
end

-- What this function does: Renders the main ReaImGui window and handles all button/input actions.
-- How it is used: Called via r.defer every frame while the window stays open.
function UI.GuiLoop()
  local providers = PROVIDERS
  local paths = PATHS
  local inputs = INPUTS
  local s = stats
  AsyncRows.poll_async_rows_and_runs()
  local visible, open = ImGui.Begin(ctx, "Curl + Jobs Module Tester", true)
  if visible then
    ImGui.PushFont(ctx, FONT, font_size)
    UI.render_status_panel_inline()
    UI.render_cleanup_telemetry_panel()
    ImGui.Text(
      ctx,
      "Totals: PASS=" .. tostring(s.counters.pass) .. " FAIL=" .. tostring(s.counters.fail) .. " SKIP=" .. tostring(s.counters.skip)
    )

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
      local changed_override_level, new_override_level = ImGui.SliderInt(
        ctx,
        "log_level_override",
        tonumber(Util.log_level_override) or 0,
        0,
        4
      )
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
    ImGui.Text(ctx, "Provider and endpoint settings")
    UI.draw_provider_mode_selector()

    local ch_hb, nv_hb = ImGui.InputText(ctx, "base_httpbin", tostring(providers.base_httpbin or ""))
    if ch_hb then providers.base_httpbin = nv_hb end
    local ch_pm, nv_pm = ImGui.InputText(ctx, "base_postman", tostring(providers.base_postman or ""))
    if ch_pm then providers.base_postman = nv_pm end
    local ch_hu, nv_hu = ImGui.InputText(ctx, "base_httpbun", tostring(providers.base_httpbun or ""))
    if ch_hu then providers.base_httpbun = nv_hu end

    local ch_pg, nv_pg = ImGui.InputText(ctx, "path_get", tostring(paths.get or ""))
    if ch_pg then paths.get = nv_pg end
    local ch_pp, nv_pp = ImGui.InputText(ctx, "path_post", tostring(paths.post or ""))
    if ch_pp then paths.post = nv_pp end
    local ch_ph, nv_ph = ImGui.InputText(ctx, "path_headers", tostring(paths.headers or ""))
    if ch_ph then paths.headers = nv_ph end
    local ch_ps, nv_ps = ImGui.InputText(ctx, "path_status_fmt", tostring(paths.status_fmt or ""))
    if ch_ps then paths.status_fmt = nv_ps end
    local ch_pd, nv_pd = ImGui.InputText(ctx, "path_delay_fmt", tostring(paths.delay_fmt or ""))
    if ch_pd then paths.delay_fmt = nv_pd end
    local ch_pdl, nv_pdl = ImGui.InputText(ctx, "path_download_fmt", tostring(paths.download_fmt or ""))
    if ch_pdl then paths.download_fmt = nv_pdl end

    local ch_tls1, nv_tls1 = ImGui.InputText(ctx, "tls_url_expired", tostring(paths.tls_url_expired or ""))
    if ch_tls1 then paths.tls_url_expired = nv_tls1 end
    local ch_tls2, nv_tls2 = ImGui.InputText(ctx, "tls_url_self_signed", tostring(paths.tls_url_self_signed or ""))
    if ch_tls2 then paths.tls_url_self_signed = nv_tls2 end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Load profile and CFG")
    local ch_sandbox, nv_sandbox = ImGui.InputText(ctx, "sandbox_root", tostring(runtime.sandbox_root or ""))
    if ch_sandbox then
      runtime.sandbox_root = nv_sandbox
      Helpers.sync_logger_with_sandbox()
      runtime.ready = false
    end
    local ch_conc, nv_conc = ImGui.InputText(ctx, "concurrency_input", tostring(inputs.concurrency or ""))
    if ch_conc then inputs.concurrency = nv_conc end
    local ch_dl, nv_dl = ImGui.InputText(ctx, "download_bytes_input", tostring(inputs.download_bytes or ""))
    if ch_dl then inputs.download_bytes = nv_dl end
    local ch_ul, nv_ul = ImGui.InputText(ctx, "upload_bytes_input", tostring(inputs.upload_bytes or ""))
    if ch_ul then inputs.upload_bytes = nv_ul end
    local ch_req_to, nv_req_to = ImGui.InputText(ctx, "request_timeout_sec_input", tostring(inputs.request_timeout_sec or ""))
    if ch_req_to then inputs.request_timeout_sec = nv_req_to end
    local ch_max_retry, nv_max_retry = ImGui.InputText(ctx, "max_retry_input", tostring(inputs.max_retry or ""))
    if ch_max_retry then inputs.max_retry = nv_max_retry end
    local ch_auto_retry, nv_auto_retry = ImGui.Checkbox(ctx, "auto_retry", ui_state.auto_retry == true)
    if ch_auto_retry then ui_state.auto_retry = nv_auto_retry end
    local ch_poll_to, nv_poll_to = ImGui.InputText(ctx, "poll_timeout_sec_input", tostring(inputs.poll_timeout_sec or ""))
    if ch_poll_to then inputs.poll_timeout_sec = nv_poll_to end
    local ch_delay, nv_delay = ImGui.InputText(ctx, "delay_seconds_input", tostring(inputs.delay_seconds or ""))
    if ch_delay then inputs.delay_seconds = nv_delay end
    local ch_short_to, nv_short_to = ImGui.InputText(ctx, "short_timeout_sec_input", tostring(inputs.short_timeout_sec or ""))
    if ch_short_to then inputs.short_timeout_sec = nv_short_to end

    local ch_mcj, nv_mcj = ImGui.InputText(ctx, "max_concurrent_jobs", tostring(inputs.max_concurrent_jobs or ""))
    if ch_mcj then inputs.max_concurrent_jobs = nv_mcj end
    local ch_mivc, nv_mivc = ImGui.InputText(ctx, "max_concurrent_ivc_jobs", tostring(inputs.max_concurrent_ivc_jobs or ""))
    if ch_mivc then inputs.max_concurrent_ivc_jobs = nv_mivc end
    local ch_rbb, nv_rbb = ImGui.InputText(ctx, "retry_base_backoff_sec", tostring(inputs.retry_base_backoff_sec or ""))
    if ch_rbb then inputs.retry_base_backoff_sec = nv_rbb end
    local ch_rjr, nv_rjr = ImGui.InputText(ctx, "retry_jitter_ratio", tostring(inputs.retry_jitter_ratio or ""))
    if ch_rjr then inputs.retry_jitter_ratio = nv_rjr end
    local ch_mwr, nv_mwr = ImGui.InputText(ctx, "max_wait_time_for_retry", tostring(inputs.max_wait_time_for_retry or ""))
    if ch_mwr then inputs.max_wait_time_for_retry = nv_mwr end

    local ch_keep, nv_keep = ImGui.Checkbox(ctx, "keep_artifacts", flags.keep_artifacts == true)
    if ch_keep then flags.keep_artifacts = nv_keep end
    local ch_tls, nv_tls = ImGui.Checkbox(ctx, "enable_tls_negative_section", flags.enable_tls_negative == true)
    if ch_tls then flags.enable_tls_negative = nv_tls end
    local ch_confirm, nv_confirm = ImGui.Checkbox(ctx, "Confirm destructive actions", flags.confirm_destructive == true)
    if ch_confirm then flags.confirm_destructive = nv_confirm end

    if ImGui.Button(ctx, "Reinitialize runtime (Curl + Jobs)") then
      UI.reinit_runtime_button()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Ensure sandbox root exists") then
      local ok, err = Files.ensure_tmp_dir(runtime.sandbox_root)
      Helpers.log_result("ensure_sandbox_root", ok == true, "ok=" .. tostring(ok) .. "; err=" .. tostring(err))
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Manual cleanup sandbox (destructive)") then
      TestCases.run_manual_cleanup_sandbox()
    end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Curl tests")
    if ImGui.Button(ctx, "Test curl_json_get_echo") then TestCases.run_curl_json_get_echo_test() end
    if ImGui.Button(ctx, "Test curl_json_post_echo") then TestCases.run_curl_json_post_echo_test() end
    if ImGui.Button(ctx, "Test curl_auth_header_echo") then TestCases.run_curl_auth_header_echo_test() end
    if ImGui.Button(ctx, "Test curl_large_upload_from_download_file") then TestCases.run_curl_large_upload_test() end
    if ImGui.Button(ctx, "Test curl_large_download_source_file") then TestCases.run_curl_large_download_test() end
    if ImGui.Button(ctx, "Test curl_concurrency_8x1mb") then TestCases.run_curl_concurrency_test() end
    if ImGui.Button(ctx, "Test curl_status_429_and_500") then TestCases.run_curl_status_429_500_test() end
    if ImGui.Button(ctx, "Test curl_timeout_via_delay") then TestCases.run_curl_timeout_delay_test() end
    if ImGui.Button(ctx, "Test curl_cleanup_queue_smoke") then TestCases.run_curl_cleanup_queue_smoke_test() end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Request progress table")
    if ImGui.Button(ctx, "Clear table and reset async state") then
      AsyncRows.clear_async_table_and_runtime()
    end
    UI.draw_request_progress_table()

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Jobs tests")
    local jobs_disabled = AsyncRows.active_async_rows()
    if jobs_disabled then
      ImGui.TextWrapped(ctx, "Jobs tests are disabled while async curl rows are active.")
      ImGui.BeginDisabled(ctx, true)
    end
    if ImGui.Button(ctx, "Test jobs_schedule_and_tick") then TestCases.run_jobs_schedule_and_tick_test() end
    if ImGui.Button(ctx, "Test jobs_schedule_reject_when_pending") then TestCases.run_jobs_schedule_reject_pending_test() end
    if ImGui.Button(ctx, "Test jobs_retry_enqueue_and_fire") then TestCases.run_jobs_retry_enqueue_fire_test() end
    if ImGui.Button(ctx, "Test jobs_retry_stale_generation_skip") then TestCases.run_jobs_retry_stale_generation_test() end
    if ImGui.Button(ctx, "Test jobs_manual_retry_record") then TestCases.run_jobs_manual_retry_record_test() end
    if ImGui.Button(ctx, "Test jobs_cancel_record") then TestCases.run_jobs_cancel_record_test() end
    if ImGui.Button(ctx, "Test jobs_network_busy_semantics") then TestCases.run_jobs_network_busy_semantics_test() end
    if ImGui.Button(ctx, "Test jobs_tick_all_stats") then TestCases.run_jobs_tick_all_stats_test() end
    if ImGui.Button(ctx, "Test jobs_reset_runtime") then TestCases.run_jobs_reset_runtime_test() end
    if jobs_disabled then
      ImGui.EndDisabled(ctx)
    end

    ImGui.Text(
      ctx,
      "Event counts: job_scheduled=" .. tostring(s.events.job_scheduled) ..
        " job_started=" .. tostring(s.events.job_started) ..
        " retry_scheduled=" .. tostring(s.events.retry_scheduled) ..
        " retry_fired=" .. tostring(s.events.retry_fired) ..
        " retry_submit_error=" .. tostring(s.events.retry_submit_error) ..
        " record_canceled=" .. tostring(s.events.record_canceled) ..
        " runtime_reset=" .. tostring(s.events.runtime_reset)
    )

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Optional TLS-negative tests")
    if not flags.enable_tls_negative then
      ImGui.Text(ctx, "TLS-negative section is disabled. Enable checkbox above to run.")
    else
      if ImGui.Button(ctx, "Test tls_expired_badssl_expected_fail") then TestCases.run_tls_expired_badssl_expected_fail_test() end
      if ImGui.Button(ctx, "Test tls_self_signed_badssl_expected_fail") then TestCases.run_tls_self_signed_badssl_expected_fail_test() end
    end

    ImGui.Separator(ctx)
    ImGui.Text(ctx, "Rolling result log")
    if ImGui.Button(ctx, "Clear result log") then
      ui_state.rolling_log_lines = {}
      ui_state.last_status_text = "Log cleared."
      ui_state.status_text = "Log cleared."
      s.counters = { pass = 0, fail = 0, skip = 0 }
      Helpers.reset_cleanup_ui_telemetry()
    end
    local start_index = math.max(1, #ui_state.rolling_log_lines - 89)
    for i = start_index, #ui_state.rolling_log_lines do
      ImGui.TextWrapped(ctx, ui_state.rolling_log_lines[i])
    end
    ImGui.PopFont(ctx)
  end
  ImGui.End(ctx)

  if open then
    r.defer(UI.GuiLoop)
  end
end

if Helpers.init_runtime("startup_init") then
  Helpers.log_result("startup_init", true, "Runtime initialized. mode=" .. tostring(PROVIDERS.modes[PROVIDERS.mode_idx]))
end

r.defer(UI.GuiLoop)




