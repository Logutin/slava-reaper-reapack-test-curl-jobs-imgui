-- @noindex
-- Curl transport/scheduler helper module for ReaScript projects.
-- Exported functions:
-- Curl.init(State, CFG[, launch_policy]): bind shared state/config before any other call.
-- Curl.get_jobs(): return read-only shallow snapshot of current jobs table.
-- Curl.join_cmd(argv): join command arguments to one shell command string.
-- Curl.shell_quote(arg): quote one shell argument for current OS shell style.
-- Curl.curl_cfg_quote(value): quote value for curl config file syntax.
-- Curl.make_curl_job_paths(kind, id): build file paths for one curl job.
-- Curl.write_curl_config(req, job, opts): write curl config file for a request.
-- Curl.prepare_curl_job(req, on_done, opts): build job table and config file.
-- Curl.launch_curl_job(job): launch curl process for a prepared job.
-- Curl.curl_submit(req, on_done, opts): enqueue and maybe launch a curl job.
--   Optional job metadata:
--     req.owner / opts.owner       - "workflow" by default, "telemetry" for background telemetry.
--     req.blocking / opts.blocking - true by default; false jobs do not block workflow buttons.
--     req.visible / opts.visible   - true by default; UI may hide false jobs.
--     req.priority / opts.priority - "foreground" by default, "background" for support work.
--   Request payload options:
--     req.body_string        - inline body text
--     req.json_payload_tbl   - JSON-encoded body
--     req.body_file_path     - existing file path used as --data-binary source
-- Curl.parse_progress_meter_line(text): parse latest curl progress-meter row from stderr tail text
--   (supports both full 12-column and compact 9-column curl meter formats).
-- Curl.try_update_progress(job): update progress fields from stderr/output files.
-- Curl.is_job_done(job): inspect curl write-out meta file and decode JSON.
-- Curl.parse_curl_results(job, meta_tbl): build normalized result table.
-- Curl.complete_curl_job(job, result): finalize job, call callback, cleanup.
-- Curl.poll_curl_job(job, now_t): advance a running job by polling files.
-- Curl.poll_curl_jobs(now_t): launch queued jobs and poll active jobs.
-- Curl.update_last_curl_state(result, job, label): write shared last-curl state.
--
-- Usage:
-- local Curl = require("modules.Curl")
-- Curl.init(State, CFG)
-- -- optional custom launch policy:
-- -- Curl.init(State, CFG, function(job, snapshot, cfg) return true end)
--
-- Beginner note about launch_policy:
-- 1) A "job" is a network request waiting to start.
-- 2) launch_policy decides "can this job start now?" (true/false).
-- 3) If you do not pass launch_policy, Curl uses its default policy:
--    - keep total running jobs under max_concurrent_jobs
--    - for kind == "el_ivc_create", also keep under max_concurrent_IVC_jobs
-- 4) launch_policy does not launch jobs itself; it only allows/blocks launch.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules.Util")
local Files = require("modules.Files")
local Cleanup = require("modules.Cleanup")
local json = require("modules.json")

local Curl = {}

local DEFAULT_CFG = {
  curl = Util.mac and "/usr/bin/curl" or "curl",
  timeout_sec = 320,
  max_concurrent_jobs = 12,
  max_concurrent_IVC_jobs = 1,
  curl_connect_timeout_sec = 45,
  curl_speed_limit = 1,
  curl_speed_time = 120,
  use_fail_with_body = true
}

local State = nil
local CFG = nil
-- Optional custom gate function:
-- function(job, snapshot, cfg) -> boolean
local launch_policy = nil
local initialized = false
local LIVE_DELTA_DEADBAND_BYTES = 128
local init_live_flow_state
local ensure_live_flow_state

-- Reads one config value and falls back to module defaults.
local function cfg_value(key)
  local cfg = CFG or {}
  local v = cfg[key]
  if v == nil then
    v = DEFAULT_CFG[key]
  end
  return v
end

-- Ensures init() was called before stateful operations.
local function ensure_initialized()
  assert(initialized, "Curl.init(State, CFG) must be called before using Curl module")
end

-- Fills required shared state keys when missing.
local function ensure_state_shape(state)
  if type(state.curl_jobs) ~= "table" then
    state.curl_jobs = {}
  end
  if type(state.last_http) ~= "string" then
    state.last_http = ""
  end
  if type(state.last_curl_return) ~= "table" then
    state.last_curl_return = {}
  end
  local last = state.last_curl_return
  if last.ok == nil then last.ok = "" end
  if last.http == nil then last.http = "" end
  if last.body == nil then last.body = "" end
  if last.headers_txt == nil then last.headers_txt = "" end
  if last.meta == nil then last.meta = "" end
  if last.err == nil then last.err = "" end
  if last.cmd == nil then last.cmd = "" end
  if type(state.req_count) ~= "number" then
    state.req_count = 0
  end
end

-- Makes a shallow read-only snapshot table for safer inspection.
local function shallow_readonly_snapshot(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = v
  end
  return setmetatable(out, {
    __newindex = function()
      error("snapshot is read-only", 2)
    end,
    __metatable = false
  })
end

-- Builds a tiny "scheduler snapshot" used by launch_policy.
-- snapshot fields:
--   running      - all launched/running jobs
--   running_ivc  - launched/running jobs with kind "el_ivc_create"
--   max_jobs     - configured global concurrency limit
--   max_ivc_jobs - configured IVC-specific concurrency limit
local function snapshot_running()
  local jobs = State.curl_jobs
  local running = 0
  local running_ivc = 0
  for _, j in pairs(jobs) do
    if j and (j.phase == "launched" or j.phase == "running") then
      running = running + 1
      if j.kind == "el_ivc_create" then
        running_ivc = running_ivc + 1
      end
    end
  end
  local max_jobs = tonumber(cfg_value("max_concurrent_jobs")) or 1
  local max_ivc_jobs = tonumber(cfg_value("max_concurrent_IVC_jobs")) or 1
  if max_jobs < 1 then max_jobs = 1 end
  if max_ivc_jobs < 1 then max_ivc_jobs = 1 end
  return {
    running = running,
    running_ivc = running_ivc,
    max_jobs = max_jobs,
    max_ivc_jobs = max_ivc_jobs
  }
end

-- Default launch_policy that matches existing ElevenLabs behavior.
-- Returns true when job can start now, false when it should wait in queue.
local function default_launch_policy(job, snap, _cfg)
  local can_launch = (snap.running < snap.max_jobs)
  if can_launch and job and job.kind == "el_ivc_create" then
    can_launch = (snap.running_ivc < snap.max_ivc_jobs)
  end
  return can_launch
end

-- Runs chosen launch_policy with safety wrapper.
-- If custom policy throws error, we log it and block launch for safety.
local function can_launch_with_policy(job, snap)
  local policy = launch_policy or default_launch_policy
  local ok, result = pcall(policy, job, snap, CFG)
  if not ok then
    Util.msg("curl launch_policy error: " .. tostring(result), 2)
    return false
  end
  return result == true
end

-- Validates headers table shape before config generation.
local function validate_headers(headers)
  if headers == nil then return true end
  if type(headers) ~= "table" then
    return false, "headers must be a table or nil"
  end
  for k, v in pairs(headers) do
    if type(k) ~= "string" or k == "" then
      return false, "header key must be a non-empty string"
    end
    local tv = type(v)
    if tv == "table" or tv == "function" or tv == "thread" or tv == "userdata" then
      return false, "header value for key '" .. tostring(k) .. "' must be scalar-like"
    end
  end
  return true
end

-- Validates multipart field structure before config generation.
local function validate_form_fields(form_fields)
  if form_fields == nil then return true end
  if type(form_fields) ~= "table" then
    return false, "form_fields must be a table or nil"
  end
  for i, f in ipairs(form_fields) do
    if type(f) ~= "table" then
      return false, ("form_fields[%d] must be a table"):format(i)
    end
    if type(f.name) ~= "string" or f.name == "" then
      return false, ("form_fields[%d].name must be a non-empty string"):format(i)
    end
    local has_file = (f.filepath ~= nil)
    local has_value = (f.value ~= nil)
    if has_file == has_value then
      return false, ("form_fields[%d] must specify exactly one of filepath/value"):format(i)
    end
    if has_file and (type(f.filepath) ~= "string" or f.filepath == "") then
      return false, ("form_fields[%d].filepath must be a non-empty string"):format(i)
    end
    if f.content_type ~= nil and type(f.content_type) ~= "string" then
      return false, ("form_fields[%d].content_type must be a string or nil"):format(i)
    end
  end
  return true
end

-- Validates request table for expected transport shape.
local function validate_req(req)
  if type(req) ~= "table" then
    return false, "req must be a table"
  end
  if type(req.url) ~= "string" or req.url == "" then
    return false, "req.url must be a non-empty string"
  end
  local ok_h, err_h = validate_headers(req.headers)
  if not ok_h then return false, err_h end

  local ok_f, err_f = validate_form_fields(req.form_fields)
  if not ok_f then return false, err_f end

  local has_payload_inline = (req.json_payload_tbl ~= nil) or (req.body_string ~= nil)
  local has_payload_file = (req.body_file_path ~= nil)
  local has_payload = has_payload_inline or has_payload_file
  local has_form = (type(req.form_fields) == "table" and req.form_fields[1] ~= nil)
  if has_payload and has_form then
    return false, "form_fields and payload are mutually exclusive"
  end
  if has_payload_inline and has_payload_file then
    return false, "body_file_path is mutually exclusive with json_payload_tbl/body_string"
  end
  if req.body_string ~= nil and type(req.body_string) ~= "string" then
    return false, "req.body_string must be a string or nil"
  end
  if req.body_file_path ~= nil then
    if type(req.body_file_path) ~= "string" or req.body_file_path == "" then
      return false, "req.body_file_path must be a non-empty string or nil"
    end
    local fh = io.open(req.body_file_path, "rb")
    if not fh then
      return false, "req.body_file_path not found/readable: " .. tostring(req.body_file_path)
    end
    fh:close()
  end
  return true
end

local function normalize_job_owner(value)
  local text = tostring(value or "")
  if text == "" then return "workflow" end
  return text
end

local function normalize_job_priority(value)
  local text = tostring(value or "")
  if text == "" then return "foreground" end
  return text
end

local function normalize_job_bool(value, fallback)
  if value == true then return true end
  if value == false then return false end
  return fallback
end

-- Initialize once before any Curl operation:
--   Curl.init(State, CFG[, launch_policy])
-- launch_policy signature: function(job, snapshot, cfg) -> boolean
-- launch_policy is optional; nil means "use default launch policy".
function Curl.init(state_tbl, cfg_tbl, launch_policy_fn)
  assert(type(state_tbl) == "table", "Curl.init(State, CFG): State table required")
  assert(type(cfg_tbl) == "table", "Curl.init(State, CFG): CFG table required")
  assert(type(cfg_tbl.tmp_dir) == "string" and cfg_tbl.tmp_dir ~= "", "Curl.init(State, CFG): CFG.tmp_dir is required")
  if launch_policy_fn ~= nil then
    assert(type(launch_policy_fn) == "function", "Curl.init(State, CFG): launch_policy must be a function or nil")
  end

  State = state_tbl
  CFG = cfg_tbl
  launch_policy = launch_policy_fn
  ensure_state_shape(State)
  Cleanup.init(state_tbl, cfg_tbl)
  initialized = true
  return true
end

-- Returns a read-only snapshot of all tracked curl jobs.
function Curl.get_jobs()
  ensure_initialized()
  return shallow_readonly_snapshot(State.curl_jobs)
end

-- Joins a command argv array into one command string.
function Curl.join_cmd(argv)
  ensure_initialized()
  return table.concat(argv, " ")
end

-- Quotes one shell argument according to current OS rules.
function Curl.shell_quote(arg)
  ensure_initialized()
  return Util.shell_quote(arg)
end

-- Quotes one value for curl config file syntax.
function Curl.curl_cfg_quote(value)
  ensure_initialized()
  local s = tostring(value or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\r", "\\r")
  s = s:gsub("\n", "\\n")
  return '"' .. s .. '"'
end

-- Builds file paths for one curl job artifact set.
function Curl.make_curl_job_paths(kind, id)
  ensure_initialized()
  local job_id = id or Util.date_time_stamp_with_time_precise()
  local stem = string.format("%s_%s", kind or "req", job_id)
  local dir = CFG.tmp_dir
  local function J(name) return Util.path_join(dir, name) end
  return {
    id = job_id,
    stem = stem,
    cfg = J(stem .. ".config"),
    out = J(stem .. ".output.file"),
    hdr = J(stem .. ".headers.txt"),
    err = J(stem .. ".error.log"),
    meta = J(stem .. ".meta.json"),
    payload = J(stem .. ".payload.bin")
  }
end

-- Writes curl config text file for one request/job pair.
function Curl.write_curl_config(req, job, opts)
  ensure_initialized()
  local ok_req, req_err = validate_req(req)
  if not ok_req then
    return false, "write_curl_config: " .. tostring(req_err)
  end
  local lines = {}
  local use_payload_file = ((opts and opts.use_payload_file) == true) or (req.use_payload_file == true)

  table.insert(lines, "# --- Request ---")
  table.insert(lines, "url = " .. Curl.curl_cfg_quote(req.url))
  if req.method and req.method ~= "" then
    table.insert(lines, "request = " .. Curl.curl_cfg_quote(req.method))
  end
  if req.follow_redirects then
    table.insert(lines, "location")
  end

  if req.headers then
    local keys = {}
    for k in pairs(req.headers) do
      table.insert(keys, k)
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = req.headers[k]
      table.insert(lines, "header = " .. Curl.curl_cfg_quote(string.format("%s: %s", k, tostring(v))))
    end
  end

  local payload_string = nil
  if req.json_payload_tbl then
    local ok, payload = pcall(json.encode, req.json_payload_tbl)
    if not ok then
      return false, "JSON encode failed: " .. tostring(payload)
    end
    payload_string = payload
  elseif req.body_string then
    payload_string = req.body_string
  end

  if req.form_fields and req.form_fields[1] then
    if payload_string then
      return false, "write_curl_config: form_fields and payload are mutually exclusive"
    end
    if req.headers and req.headers["Content-Type"] then
      return false, "write_curl_config: don't set Content-Type header when using form_fields"
    end
    for i, f in ipairs(req.form_fields) do
      if f.filepath and f.name then
        local f_test = io.open(f.filepath, "rb")
        if not f_test then
          return false, ("write_curl_config: file not found for form_fields[%d]: %s"):format(i, tostring(f.filepath))
        end
        f_test:close()
        if f.filepath:find(";", 1, true) then
          return false, ("write_curl_config: filepath contains ';' (unsupported in form value): %s"):format(f.filepath)
        end
        local part = f.name .. [[=@]] .. f.filepath
        if f.content_type and f.content_type ~= "" then
          part = part .. [[;type=]] .. f.content_type
        end
        table.insert(lines, "form = " .. Curl.curl_cfg_quote(part))
      elseif f.value ~= nil and f.name then
        local val = tostring(f.value)
        if val:find(";", 1, true) then
          return false, ("write_curl_config: form value contains ';' (unsupported in form value): %s"):format(val)
        end
        local part = f.name .. [[=]] .. val
        if f.content_type and f.content_type ~= "" then
          part = part .. [[;type=]] .. f.content_type
        end
        table.insert(lines, "form = " .. Curl.curl_cfg_quote(part))
      else
        return false, ("write_curl_config: check form_fields keys at index %d"):format(i)
      end
    end
  elseif req.body_file_path ~= nil then
    local fh = io.open(req.body_file_path, "rb")
    if not fh then
      return false, "write_curl_config: body_file_path not found/readable: " .. tostring(req.body_file_path)
    end
    fh:close()
    table.insert(lines, "data-binary = " .. Curl.curl_cfg_quote("@" .. req.body_file_path))
    job.payload_path = nil
  elseif payload_string then
    if use_payload_file then
      local ok_write, err = Files.write_file(job.payload_path, payload_string)
      if not ok_write then
        return false, "Cannot write payload: " .. tostring(err)
      end
      table.insert(lines, "data-binary = " .. Curl.curl_cfg_quote("@" .. job.payload_path))
    else
      table.insert(lines, "data-binary = " .. Curl.curl_cfg_quote(payload_string))
      job.payload_path = nil
    end
  else
    job.payload_path = nil
  end

  table.insert(lines, "")
  table.insert(lines, "# --- Connection Tuning ---")
  local connect_timeout = tonumber(req.connect_timeout_sec or cfg_value("curl_connect_timeout_sec"))
  if connect_timeout then
    table.insert(lines, "connect-timeout = " .. tostring(connect_timeout))
  end
  local speed_limit = tonumber(req.speed_limit or cfg_value("curl_speed_limit"))
  local speed_time = tonumber(req.speed_time or cfg_value("curl_speed_time"))
  if speed_limit then
    table.insert(lines, "speed-limit = " .. tostring(speed_limit))
  end
  if speed_time then
    table.insert(lines, "speed-time = " .. tostring(speed_time))
  end

  table.insert(lines, "")
  table.insert(lines, "# --- Output & Logging ---")
  table.insert(lines, "output = " .. Curl.curl_cfg_quote(job.out_path))
  table.insert(lines, "dump-header = " .. Curl.curl_cfg_quote(job.hdr_path))
  table.insert(lines, "stderr = " .. Curl.curl_cfg_quote(job.err_path))
  table.insert(lines, "show-error")
  if cfg_value("use_fail_with_body") ~= false then
    table.insert(lines, "fail-with-body")
  end

  local write_out = string.format("%%output{%s}%%{json}", job.meta_path)
  table.insert(lines, "write-out = " .. Curl.curl_cfg_quote(write_out))

  local timeout = tonumber((opts and opts.timeout_sec) or req.timeout_sec or cfg_value("timeout_sec"))
  if timeout then
    table.insert(lines, "max-time = " .. tostring(timeout))
  end

  local ok, err = Files.write_file(job.cfg_path, table.concat(lines, "\n") .. "\n")
  if not ok then
    return false, err
  end
  return true
end

-- Creates in-memory job table and writes initial curl config.
function Curl.prepare_curl_job(req, on_done, opts)
  ensure_initialized()
  local ok_req, req_err = validate_req(req)
  if not ok_req then
    return nil, "prepare_curl_job: " .. tostring(req_err)
  end
  local submit_opts = opts or {}
  local owner = normalize_job_owner(submit_opts.owner ~= nil and submit_opts.owner or req.owner)
  local priority = normalize_job_priority(submit_opts.priority ~= nil and submit_opts.priority or req.priority)
  local blocking = normalize_job_bool(submit_opts.blocking ~= nil and submit_opts.blocking or req.blocking, true)
  local visible = normalize_job_bool(submit_opts.visible ~= nil and submit_opts.visible or req.visible, true)
  local paths = Curl.make_curl_job_paths(req.kind or "req", Util.date_time_stamp_with_time_precise())
  local out_path = req.download_path or paths.out
  local job = {
    id = paths.id,
    label = req.label or req.kind or "request",
    kind = req.kind or "req",
    owner = owner,
    blocking = blocking,
    visible = visible,
    priority = priority,
    cfg_path = paths.cfg,
    out_path = out_path,
    hdr_path = paths.hdr,
    err_path = paths.err,
    meta_path = paths.meta,
    payload_path = paths.payload,
    created_at = r.time_precise(),
    created_at_str = os.date("%Y-%m-%d %H:%M:%S"),
    launched_at = nil,
    deadline_at = nil,
    phase = "created",
    result = nil,
    progress = {
      pct = nil,
      last_line = nil,
      last_bytes = nil,
      meter = {},
      meter_updated_at = nil,
      flow = init_live_flow_state(r.time_precise())
    },
    opts = {
      timeout_sec = tonumber((opts and opts.timeout_sec) or req.timeout_sec or cfg_value("timeout_sec")) or 570,
      early_secret_cleanup = (opts and opts.early_secret_cleanup) ~= false,
      retain_artifacts = (opts and opts.retain_artifacts) == true,
      use_payload_file = (opts and opts.use_payload_file) == true,
      keep_output = (opts and opts.keep_output) ~= false,
      read_body = (opts and opts.read_body) == true,
      body_max_bytes = (opts and opts.body_max_bytes) or (2 * 1024 * 1024)
    },
    on_done = on_done
  }

  local ok, err = Curl.write_curl_config(req, job, opts)
  if not ok then
    Util.msg("curl config failed: " .. tostring(err), 2)
    return nil, err
  end
  local raw_url = tostring(req.url or "")
  local safe_url = raw_url:gsub("^(%w+://)[^/@]+@", "%1")
  safe_url = safe_url:match("^[^?]+") or safe_url
  local method_txt = req.method or "GET"
  Util.msg(
    "curl job prepared: " ..
    tostring(job.label) ..
    " (id " .. tostring(job.id) .. ", " .. tostring(method_txt) .. " " .. tostring(safe_url) .. ")",
    0
  )
  return job
end

-- Launches one prepared curl job using ExecProcess.
function Curl.launch_curl_job(job)
  ensure_initialized()
  assert(job and job.cfg_path, "launch_curl_job: job.cfg_path required")
  local argv = { Curl.shell_quote(cfg_value("curl")), "-q", "--config", Curl.shell_quote(job.cfg_path) }
  local cmd = Curl.join_cmd(argv)
  local exec_output = r.ExecProcess(cmd, -2)
  if not exec_output then
    Util.msg("curl launch failed: " .. tostring(job.id) .. " (" .. tostring(job.label) .. ")", 2)
    return false, "ExecProcess returned nil (command likely failed to start)"
  end
  job.launched_at = r.time_precise()
  local timeout = tonumber(job.opts and job.opts.timeout_sec) or 0
  if timeout > 0 then
    job.deadline_at = job.launched_at + timeout
  else
    job.deadline_at = nil
  end
  job.phase = "launched"
  if type(job.progress) ~= "table" then
    job.progress = {}
  end
  local flow = ensure_live_flow_state(job.progress, job.launched_at)
  if flow then
    flow.phase = "starting"
    flow.line = "Starting"
    flow.prev_recv_bytes = nil
    flow.prev_xferd_bytes = nil
    flow.sample_count = 0
  end
  Util.msg("curl job launched: " .. tostring(job.label) .. " (id " .. tostring(job.id) .. ")", 1)
  return true
end

-- Submits one request to queue and tries immediate launch.
-- Decision flow:
-- 1) prepare job
-- 2) read current snapshot (running counts/limits)
-- 3) ask launch_policy(job, snapshot, cfg)
-- 4) launch only when policy returns true
function Curl.curl_submit(req, on_done, opts)
  ensure_initialized()
  local job, err = Curl.prepare_curl_job(req, on_done, opts)
  if not job then return nil, err end
  State.curl_jobs[job.id] = job

  local snap = snapshot_running()
  Util.msg("curl job queued: " .. tostring(job.label) .. " (id " .. tostring(job.id) .. ")", 1)
  local can_launch = can_launch_with_policy(job, snap)
  if can_launch then
    local ok, launch_err = Curl.launch_curl_job(job)
    if not ok then
      State.curl_jobs[job.id] = nil
      return nil, launch_err
    end
  end
  return job
end

-- Creates default per-job live transfer flow state used for delta-based UI line.
init_live_flow_state = function(now_t)
  return {
    phase = "starting",
    line = "Starting",
    prev_recv_bytes = nil,
    prev_xferd_bytes = nil,
    sample_count = 0
  }
end

-- Ensures progress.flow shape so callers can always read a stable table.
ensure_live_flow_state = function(progress_tbl, now_t)
  if type(progress_tbl) ~= "table" then
    return nil
  end
  if type(progress_tbl.flow) ~= "table" then
    progress_tbl.flow = init_live_flow_state(now_t)
  end
  local flow = progress_tbl.flow
  local phase_txt = tostring(flow.phase or "")
  if phase_txt == "waiting" or phase_txt == "stalled" then
    phase_txt = "connecting"
  end
  if phase_txt == "" then
    phase_txt = "starting"
  end
  flow.phase = phase_txt

  if type(flow.line) ~= "string" or flow.line == "" then
    flow.line = (phase_txt == "connecting") and "Connecting" or "Starting"
  end
  if phase_txt == "connecting" and (flow.line == "waiting" or flow.line == "stalled") then
    flow.line = "Connecting"
  end
  if phase_txt == "starting" and (flow.line == "waiting" or flow.line == "stalled") then
    flow.line = "Starting"
  end

  if type(flow.phase) ~= "string" or flow.phase == "" then
    flow.phase = "starting"
  end
  flow.sample_count = tonumber(flow.sample_count) or 0
  return flow
end

-- Parses one curl meter size token (for example: 0, 123k, 1.2M) into bytes.
local function parse_meter_size_to_bytes(token)
  if token == nil then return nil end
  local s = tostring(token):match("^%s*(.-)%s*$")
  if s == "" then return nil end
  local num_txt, unit = s:match("^([%+%-]?%d*%.?%d+)([kKmMgGtTpPeE]?)$")
  if not num_txt then
    return nil
  end
  local value = tonumber(num_txt)
  if not value or value < 0 then return nil end
  local mult_map = {
    [""] = 1,
    k = 1024,
    m = 1024 * 1024,
    g = 1024 * 1024 * 1024,
    t = 1024 * 1024 * 1024 * 1024,
    p = 1024 * 1024 * 1024 * 1024 * 1024,
    e = 1024 * 1024 * 1024 * 1024 * 1024 * 1024
  }
  local mul = mult_map[(unit or ""):lower()]
  if not mul then return nil end
  return value * mul
end

-- Parses one percent token (for example: 42 or 42.5%) and clamps to 0..100.
local function parse_meter_pct(token)
  if token == nil then return nil end
  local s = tostring(token):match("^%s*(.-)%s*$")
  if s == "" then return nil end
  local pct = tonumber(s:match("^([%+%-]?%d*%.?%d+)%%?$"))
  if pct == nil then return nil end
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end
  return pct
end

local function format_pct_value(pct)
  if pct == nil then return nil end
  local rounded = math.floor(pct + 0.0001)
  if math.abs(pct - rounded) < 0.0001 then
    return tostring(rounded)
  end
  return string.format("%.1f", pct)
end

local function has_material_delta(curr_bytes, prev_bytes)
  if curr_bytes == nil or prev_bytes == nil then
    return false
  end
  return math.abs(curr_bytes - prev_bytes) >= LIVE_DELTA_DEADBAND_BYTES
end

-- Builds the short UI one-liner from a machine phase and latest meter snapshot.
local function format_live_phase_line(phase, meter_tbl)
  if phase == "starting" then
    return "Starting"
  end
  if phase == "connecting" then
    return "Connecting"
  end
  if phase == "uploading" then
    local pct = parse_meter_pct(meter_tbl and meter_tbl.xferd_pct)
    if pct and pct > 0 and pct < 100 then
      return "UP: " .. tostring(format_pct_value(pct)) .. "%"
    end
    local size_txt = tostring(meter_tbl and meter_tbl.xferd_size or "0")
    if size_txt == "" then size_txt = "0" end
    return "UP: " .. size_txt
  end
  if phase == "downloading" then
    local pct = parse_meter_pct(meter_tbl and meter_tbl.received_pct)
    if pct and pct > 0 and pct < 100 then
      return "DL: " .. tostring(format_pct_value(pct)) .. "%"
    end
    local size_txt = tostring(meter_tbl and meter_tbl.received_size or "0")
    if size_txt == "" then size_txt = "0" end
    return "DL: " .. size_txt
  end
  if phase == "transferring" then
    local recv_txt = tostring(meter_tbl and meter_tbl.received_size or "0")
    local xferd_txt = tostring(meter_tbl and meter_tbl.xferd_size or "0")
    if recv_txt == "" then recv_txt = "0" end
    if xferd_txt == "" then xferd_txt = "0" end
    return "UL/DL: " .. recv_txt .. " + " .. xferd_txt
  end
  return "Starting"
end

-- Classifies live data movement phase from flow history and latest meter values.
local function classify_live_phase(flow_state, meter_tbl, now_t, delta_ctx)
  if type(flow_state) ~= "table" then
    return "starting"
  end

  if type(meter_tbl) ~= "table" then
    return "connecting"
  end

  local recv_bytes = nil
  local xferd_bytes = nil
  local moved_recv = false
  local moved_xferd = false
  local sample_count = tonumber(flow_state.sample_count) or 0
  if type(delta_ctx) == "table" then
    recv_bytes = delta_ctx.recv_bytes
    xferd_bytes = delta_ctx.xferd_bytes
    moved_recv = (delta_ctx.moved_recv == true)
    moved_xferd = (delta_ctx.moved_xferd == true)
    sample_count = tonumber(delta_ctx.sample_count) or sample_count
  else
    recv_bytes = parse_meter_size_to_bytes(meter_tbl.received_size)
    xferd_bytes = parse_meter_size_to_bytes(meter_tbl.xferd_size)
    local prev_recv = tonumber(flow_state.prev_recv_bytes)
    local prev_xferd = tonumber(flow_state.prev_xferd_bytes)
    moved_recv = has_material_delta(recv_bytes, prev_recv)
    moved_xferd = has_material_delta(xferd_bytes, prev_xferd)
  end

  if sample_count <= 1 then
    local recv_now = recv_bytes or 0
    local xferd_now = xferd_bytes or 0
    if recv_now > 0 or xferd_now > 0 then
      return "starting"
    end
    return "connecting"
  end

  if moved_recv and moved_xferd then
    return "transferring"
  end
  if moved_xferd then
    return "uploading"
  end
  if moved_recv then
    return "downloading"
  end

  local recv_zero = (recv_bytes ~= nil and recv_bytes <= 0)
  local xferd_zero = (xferd_bytes ~= nil and xferd_bytes <= 0)
  if recv_zero and xferd_zero then
    return "connecting"
  end
  local prev_phase = tostring(flow_state.phase or "")
  if prev_phase == "waiting" or prev_phase == "stalled" then
    prev_phase = "connecting"
  end
  if prev_phase == "uploading" or prev_phase == "downloading" or prev_phase == "transferring" then
    return prev_phase
  end
  return "connecting"
end

-- Updates progress.flow state when we parsed one new/last meter row.
local function update_live_flow_from_meter(job, meter_tbl, now_t)
  if type(job) ~= "table" or type(meter_tbl) ~= "table" then
    return false
  end
  if type(job.progress) ~= "table" then
    job.progress = {}
  end

  local ts = tonumber(now_t) or r.time_precise()
  local flow = ensure_live_flow_state(job.progress, ts)
  if not flow then return false end

  local recv_bytes = parse_meter_size_to_bytes(meter_tbl.received_size)
  local xferd_bytes = parse_meter_size_to_bytes(meter_tbl.xferd_size)
  local prev_recv = tonumber(flow.prev_recv_bytes)
  local prev_xferd = tonumber(flow.prev_xferd_bytes)
  local sample_count = (tonumber(flow.sample_count) or 0) + 1

  local moved_recv = false
  local moved_xferd = false
  moved_recv = has_material_delta(recv_bytes, prev_recv)
  moved_xferd = has_material_delta(xferd_bytes, prev_xferd)

  local phase = classify_live_phase(flow, meter_tbl, ts, {
    recv_bytes = recv_bytes,
    xferd_bytes = xferd_bytes,
    moved_recv = moved_recv,
    moved_xferd = moved_xferd,
    sample_count = sample_count
  })

  flow.sample_count = sample_count
  -- Rebase previous counters to current sample after phase decision.
  if recv_bytes ~= nil then
    flow.prev_recv_bytes = recv_bytes
  end
  if xferd_bytes ~= nil then
    flow.prev_xferd_bytes = xferd_bytes
  end

  flow.phase = phase
  flow.line = format_live_phase_line(phase, meter_tbl)
  return true
end

-- Parses latest curl progress-meter row from stderr tail text, scanning newest
-- lines first. Supports both:
-- 1) full 12-column rows:
--   1 %Total        -> total_pct
--   2 Total size    -> total_size
--   3 %Received     -> received_pct
--   4 Received size -> received_size
--   5 %Xferd        -> xferd_pct
--   6 Xferd size    -> xferd_size
--   7 Avg Dload     -> avg_dload_speed
--   8 Avg Upload    -> avg_upload_speed
--   9 Time Total    -> time_total
--  10 Time Spent    -> time_spent
--  11 Time Left     -> time_left
--  12 Current Speed -> current_speed
-- 2) compact 9-column rows (no time fields):
--   1 %Total        -> total_pct
--   2 Total size    -> total_size
--   3 %Received     -> received_pct
--   4 Received size -> received_size
--   5 %Xferd        -> xferd_pct
--   6 Xferd size    -> xferd_size
--   7 Avg Dload     -> avg_dload_speed
--   8 Avg Upload    -> avg_upload_speed
--   9 Current Speed -> current_speed
function Curl.parse_progress_meter_line(s)
  ensure_initialized()
  if type(s) ~= "string" or s == "" then return nil end

  local normalized = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in normalized:gmatch("([^\n]+)") do
    lines[#lines + 1] = line
  end

  -- Pass 1: prefer full 12-column rows.
  for i = #lines, 1, -1 do
    local line = lines[i]
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local lower = trimmed:lower()
      local is_header =
        lower:match("^%%+%s*total") or
        lower:match("^dload%s+upload%s+total%s+spent%s+left%s+speed")
      local is_separator = trimmed:match("^[- ]+$")
      if (not is_header) and (not is_separator) then
        local tokens = {}
        for tok in trimmed:gmatch("%S+") do
          tokens[#tokens + 1] = tok
        end
        if #tokens >= 12 then
          return {
            total_pct = tokens[1],
            total_size = tokens[2],
            received_pct = tokens[3],
            received_size = tokens[4],
            xferd_pct = tokens[5],
            xferd_size = tokens[6],
            avg_dload_speed = tokens[7],
            avg_upload_speed = tokens[8],
            time_total = tokens[9],
            time_spent = tokens[10],
            time_left = tokens[11],
            current_speed = tokens[12]
          }
        end
      end
    end
  end

  -- Pass 2: fallback to compact 9-column rows when 12-column parse is absent.
  for i = #lines, 1, -1 do
    local line = lines[i]
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local lower = trimmed:lower()
      local is_header =
        lower:match("^%%+%s*total") or
        lower:match("^dload%s+upload%s+total%s+spent%s+left%s+speed")
      local is_separator = trimmed:match("^[- ]+$")
      if (not is_header) and (not is_separator) then
        local tokens = {}
        for tok in trimmed:gmatch("%S+") do
          tokens[#tokens + 1] = tok
        end
        if #tokens >= 9 then
          return {
            total_pct = tokens[1],
            total_size = tokens[2],
            received_pct = tokens[3],
            received_size = tokens[4],
            xferd_pct = tokens[5],
            xferd_size = tokens[6],
            avg_dload_speed = tokens[7],
            avg_upload_speed = tokens[8],
            current_speed = tokens[9]
          }
        end
      end
    end
  end
  return nil
end

-- Merges parsed meter fields into job.progress and updates compatibility pct alias.
local function merge_meter_into_job_progress(job, meter_tbl, updated_at)
  if type(job) ~= "table" or type(meter_tbl) ~= "table" then
    return false
  end
  if type(job.progress) ~= "table" then
    job.progress = {}
  end
  if type(job.progress.meter) ~= "table" then
    job.progress.meter = {}
  end
  for k, v in pairs(meter_tbl) do
    if v ~= nil then
      job.progress.meter[k] = v
    end
  end

  local ts = tonumber(updated_at) or r.time_precise()
  job.progress.meter_updated_at = ts
  update_live_flow_from_meter(job, meter_tbl, ts)

  local pct = tonumber(tostring(meter_tbl.total_pct or ""):match("^([%d]+%.?%d*)%%?$"))
  if pct ~= nil then
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local prev = tonumber(job.progress.pct)
    if prev ~= nil and prev > pct then
      pct = prev
    end
    -- Keep pct for backward compatibility with existing callers.
    job.progress.pct = pct
  end
  return true
end

-- Best-effort completion-time refresh: parse full stderr once so callback gets
-- the latest progress meter row even when done is detected between poll ticks.
local function finalize_progress_from_stderr(job)
  if type(job) ~= "table" then return false end
  local err_txt = Files.slurp_with_cap(job.err_path, 256 * 1024)
  if type(err_txt) ~= "string" or err_txt == "" then
    return false
  end
  local meter = Curl.parse_progress_meter_line(err_txt)
  if not meter then
    return false
  end
  return merge_meter_into_job_progress(job, meter, r.time_precise())
end

-- Updates job.progress fields from curl stderr and output size.
-- job.progress shape:
--   pct              - compatibility alias (% Total), monotonic
--   last_line        - stderr tail text snapshot
--   last_bytes       - current output file size
--   meter            - parsed 12-column curl meter snapshot (raw strings)
--   meter_updated_at - r.time_precise() when meter was last parsed
--   flow             - live phase inference state and one-liner
function Curl.try_update_progress(job)
  ensure_initialized()
  local tail = Files.read_tail(job.err_path, 1024)
  if not tail then return false end
  job.progress.last_line = tail

  local merged_meter = false
  local meter = Curl.parse_progress_meter_line(tail)
  if meter then
    merged_meter = (merge_meter_into_job_progress(job, meter, r.time_precise()) == true)
  end

  local sz = Files.file_size(job.out_path)
  if sz then
    job.progress.last_bytes = sz
  end
  return merged_meter
end

-- Checks whether curl write-out meta file exists and is decoded.
function Curl.is_job_done(job)
  ensure_initialized()
  if not job.meta_path or not r.file_exists(job.meta_path) then
    return nil
  end
  local meta_txt = Files.slurp_with_cap(job.meta_path, 256 * 1024)
  if not meta_txt or meta_txt == "" then
    return nil
  end
  local ok, mt = pcall(json.decode, meta_txt)
  if ok and type(mt) == "table" then
    return mt
  end
  return nil
end

local function artifact_paths_for_job(job)
  if type(job) ~= "table" then return nil end
  return {
    cfg = job.cfg_path,
    output = job.out_path,
    headers = job.hdr_path,
    stderr = job.err_path,
    meta = job.meta_path,
    payload = job.payload_path
  }
end

-- Parses raw curl artifacts/meta into normalized result shape.
function Curl.parse_curl_results(job, meta_tbl)
  ensure_initialized()
  local meta = meta_tbl or Curl.is_job_done(job)
  local headers_txt = Files.slurp_with_cap(job.hdr_path, 256 * 1024)
  local err_txt = Files.slurp_with_cap(job.err_path, 256 * 1024)
  local body_txt = nil
  if job.opts and job.opts.read_body then
    local maxb = tonumber(job.opts.body_max_bytes) or (2 * 1024 * 1024)
    body_txt = Files.slurp_with_cap(job.out_path, maxb)
  end

  local http_code = nil
  local err_msg = nil
  local meta_url = nil
  local meta_effective_url = nil
  local meta_redirect_url = nil
  local meta_content_type = nil
  local meta_total_time = nil
  local meta_namelookup_time = nil
  local meta_connect_time = nil
  local meta_appconnect_time = nil
  local meta_starttransfer_time = nil
  local meta_size_download = nil
  local meta_size_upload = nil
  if meta and type(meta) == "table" then
    http_code = meta.http_code or meta.response_code or meta.status or meta.code
    err_msg = meta.errormsg or meta.error or meta.error_message
    meta_url = meta.url or meta.request_url
    meta_effective_url = meta.effective_url or meta.url_effective
    meta_redirect_url = meta.redirect_url
    meta_content_type = meta.content_type
    meta_total_time = meta.total_time
    meta_namelookup_time = meta.namelookup_time
    meta_connect_time = meta.connect_time
    meta_appconnect_time = meta.appconnect_time
    meta_starttransfer_time = meta.starttransfer_time
    meta_size_download = meta.size_download
    meta_size_upload = meta.size_upload
  end
  if not http_code and headers_txt then
    local first = headers_txt:match("^(.-)\r?\n")
    if first then
      http_code = first:match("HTTP/%d+%.%d+%s+(%d+)")
    end
  end
  local exitcode = nil
  if meta and type(meta) == "table" then
    exitcode = meta.exitcode or meta.exit_code
  end
  local exit_num = exitcode and tonumber(exitcode) or nil
  local http_num = http_code and tonumber(http_code) or nil
  local ok_exit = (exit_num == nil) or (exit_num == 0)
  local ok_http = (http_num == nil) or (http_num >= 200 and http_num < 300)
  local ok_result = ok_exit and ok_http
  local err = nil
  if not ok_result then
    if exit_num and exit_num ~= 0 then
      err = "curl exitcode " .. tostring(exit_num)
    elseif http_num then
      err = "HTTP " .. tostring(http_num)
    else
      err = "curl failed"
    end
    if err_msg and err_msg ~= "" then
      err = err .. " - " .. err_msg
    end
  end

  return {
    ok = ok_result,
    http_code = http_num or http_code,
    exitcode = exit_num,
    body = body_txt,
    headers_txt = headers_txt,
    err_txt = err_txt,
    err = err,
    err_msg = err_msg,
    url = meta_url,
    effective_url = meta_effective_url,
    redirect_url = meta_redirect_url,
    content_type = meta_content_type,
    total_time = meta_total_time,
    namelookup_time = meta_namelookup_time,
    connect_time = meta_connect_time,
    appconnect_time = meta_appconnect_time,
    starttransfer_time = meta_starttransfer_time,
    size_download = meta_size_download,
    size_upload = meta_size_upload,
    meta = meta,
    out_path = job.out_path,
    artifact_paths = artifact_paths_for_job(job),
    artifacts_retained = job.opts and job.opts.retain_artifacts == true,
    job_id = job.id,
    timed_out = false
  }
end

-- Finalizes one job, emits callback, and schedules cleanup.
function Curl.complete_curl_job(job, result)
  ensure_initialized()
  -- Force one final stderr parse so on_done sees the latest meter row.
  finalize_progress_from_stderr(job)
  job.result = result
  job.phase = "completed"
  job.completed_at = r.time_precise()
  local ok_result = result and result.ok or false
  local status_txt = "completed"
  if result and result.timed_out then
    status_txt = "completed (timeout)"
  end
  local http_txt = result and result.http_code or ""
  local exit_txt = result and result.exitcode or ""
  local time_txt = result and result.total_time or ""
  local up_txt = result and result.size_upload or ""
  local down_txt = result and result.size_download or ""
  local msg_txt =
    "curl job " .. status_txt .. ": " ..
    tostring(job.label) ..
    " (id " .. tostring(job.id) .. ")" ..
    " http=" .. tostring(http_txt) ..
    " exit=" .. tostring(exit_txt) ..
    " time=" .. tostring(time_txt) ..
    " up=" .. tostring(up_txt) ..
    " down=" .. tostring(down_txt)
  if not ok_result and result and result.err and result.err ~= "" then
    msg_txt = msg_txt .. " err=" .. tostring(result.err)
  end
  Util.msg(msg_txt, ok_result and 1 or 2)
  if job.on_done then
    local ok_cb, cb_err = pcall(job.on_done, result, job)
    if not ok_cb then
      Util.msg("curl job on_done error: " .. tostring(cb_err), 2)
    end
  end
  if job.opts and job.opts.retain_artifacts then
    local paths = artifact_paths_for_job(job) or {}
    Util.msg(
      "curl artifacts retained: " ..
      tostring(job.label) ..
      " (id " .. tostring(job.id) .. ")" ..
      " cfg=" .. tostring(paths.cfg or "") ..
      " output=" .. tostring(paths.output or "") ..
      " headers=" .. tostring(paths.headers or "") ..
      " stderr=" .. tostring(paths.stderr or "") ..
      " meta=" .. tostring(paths.meta or ""),
      1
    )
  else
    Cleanup.enqueue_job_cleanup(job)
  end
  if not job.keep_in_list then
    State.curl_jobs[job.id] = nil
  end
end

-- Polls one running/launched job and resolves completion/timeout.
function Curl.poll_curl_job(job, now_t)
  ensure_initialized()
  local t = now_t or r.time_precise()
  if job.opts and job.opts.early_secret_cleanup and (not job.opts.retain_artifacts) and (not job._cfg_cleanup_queued) then
    local sz = Files.file_size(job.err_path)
    if sz and sz > 0 then
      Cleanup.enqueue_cleanup(job.cfg_path, "curl cfg (early)")
      job._cfg_cleanup_queued = true
    end
  end

  local err_sz = Files.file_size(job.err_path)
  if job.phase == "launched" and err_sz and err_sz > 0 then
    job.phase = "running"
    Util.msg("curl job running: " .. tostring(job.label) .. " (id " .. tostring(job.id) .. ")", 0)
  end

  Curl.try_update_progress(job)

  local meta_tbl = Curl.is_job_done(job)
  if meta_tbl then
    job.phase = "done"
    local result = Curl.parse_curl_results(job, meta_tbl)
    Curl.complete_curl_job(job, result)
    return
  end

  if job.deadline_at and t >= job.deadline_at then
    local result = {
      ok = false,
      http_code = nil,
      exitcode = nil,
      body = nil,
      headers_txt = nil,
      err_txt = nil,
      err = "curl timeout",
      meta = nil,
      out_path = job.out_path,
      artifact_paths = artifact_paths_for_job(job),
      artifacts_retained = job.opts and job.opts.retain_artifacts == true,
      job_id = job.id,
      timed_out = true
    }
    Curl.complete_curl_job(job, result)
  end
end

-- Scheduler tick for all curl jobs.
-- Applies launch_policy to each queued job on every poll cycle.
-- If policy returns false, job stays in "created" and waits for next poll.
function Curl.poll_curl_jobs(now_t)
  ensure_initialized()
  local t = now_t or r.time_precise()
  local snap = snapshot_running()
  local job_ids = {}
  for id in pairs(State.curl_jobs) do
    table.insert(job_ids, id)
  end

  if snap.running < snap.max_jobs then
    for _, id in ipairs(job_ids) do
      local job = State.curl_jobs[id]
      local can_launch = can_launch_with_policy(job, snap)
      if job.phase == "created" and (not job.manual_launch) and can_launch then
        local ok, launch_err = Curl.launch_curl_job(job)
        if ok then
          snap.running = snap.running + 1
          if job.kind == "el_ivc_create" then
            snap.running_ivc = snap.running_ivc + 1
          end
        else
          local result = {
            ok = false,
            http_code = nil,
            exitcode = nil,
            body = nil,
            headers_txt = nil,
            err_txt = nil,
            err = launch_err or "launch failed",
            meta = nil,
            out_path = job.out_path,
            artifact_paths = artifact_paths_for_job(job),
            artifacts_retained = job.opts and job.opts.retain_artifacts == true,
            job_id = job.id,
            timed_out = false
          }
          Curl.complete_curl_job(job, result)
        end
      end
    end
  end

  for _, id in ipairs(job_ids) do
    local job = State.curl_jobs[id]
    if job and (job.phase == "launched" or job.phase == "running") then
      Curl.poll_curl_job(job, t)
    end
  end
end

-- Writes compact last-request status fields into shared State.
function Curl.update_last_curl_state(result, job, label)
  ensure_initialized()
  State.last_http = tostring(result and result.http_code or "")
  State.last_curl_return = {
    ok = result and result.ok or false,
    http = result and result.http_code or "",
    body = result and result.body or "",
    headers_txt = result and result.headers_txt or "",
    meta = result and result.meta or "",
    err = result and result.err or "",
    cmd = label or (job and ("async job " .. tostring(job.id)) or "")
  }
end

return Curl

