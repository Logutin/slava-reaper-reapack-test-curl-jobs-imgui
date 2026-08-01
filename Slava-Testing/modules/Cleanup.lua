-- @noindex
-- Cleanup queue helper module for ReaScript projects.
-- Exported functions:
-- Cleanup.init(State, CFG): bind shared state/config before any other call.
-- Cleanup.get_cleanup_queue(): return read-only shallow snapshot of cleanup queue.
-- Cleanup.get_cleanup_failures(): return read-only shallow snapshot of cleanup failure map.
-- Cleanup.clear_cleanup_failures([path]): clear one failure record or all records.
-- Cleanup.enqueue_cleanup(path, why, max_attempts): enqueue file path cleanup.
-- Cleanup.enqueue_job_cleanup(job): enqueue standard cleanup files for a job.
-- Cleanup.poll_cleanup_queue(now_t): retry queued file removals with backoff and return poll stats.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules.Util")
local Files = require("modules.Files")

local Cleanup = {}

local State = nil
local CFG = nil
local initialized = false

local function ensure_initialized()
  assert(initialized, "Cleanup.init(State, CFG) must be called before using Cleanup module")
end

local function ensure_state_shape(state)
  if type(state.cleanup_queue) ~= "table" then
    state.cleanup_queue = {}
  end
  if type(state.cleanup_failures) ~= "table" then
    state.cleanup_failures = {}
  end
end

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

function Cleanup.init(state_tbl, cfg_tbl)
  assert(type(state_tbl) == "table", "Cleanup.init(State, CFG): State table required")
  assert(type(cfg_tbl) == "table", "Cleanup.init(State, CFG): CFG table required")
  State = state_tbl
  CFG = cfg_tbl
  ensure_state_shape(State)
  initialized = true
  return true
end

function Cleanup.get_cleanup_queue()
  ensure_initialized()
  return shallow_readonly_snapshot(State.cleanup_queue)
end

function Cleanup.get_cleanup_failures()
  ensure_initialized()
  return shallow_readonly_snapshot(State.cleanup_failures)
end

function Cleanup.clear_cleanup_failures(path)
  ensure_initialized()
  if path == nil then
    State.cleanup_failures = {}
    return true
  end
  if type(path) ~= "string" or path == "" then
    return false, "path must be nil or a non-empty string"
  end
  State.cleanup_failures[path] = nil
  return true
end

function Cleanup.enqueue_cleanup(path, why, max_attempts)
  ensure_initialized()
  if not path or path == "" then return end
  if not r.file_exists(path) then return end
  for i = 1, #State.cleanup_queue do
    local item = State.cleanup_queue[i]
    if item and item.path == path then
      return
    end
  end
  table.insert(State.cleanup_queue, {
    path = path,
    attempts = 0,
    next_try_at = r.time_precise(),
    max_attempts = max_attempts or 50,
    why = why or ""
  })
end

local function record_cleanup_failure(item, err_txt, now_t)
  local rec = State.cleanup_failures[item.path]
  local fail_count = 1
  local first_failed_at = now_t
  local first_failed_at_str = os.date("%Y-%m-%d %H:%M:%S", math.floor(now_t))
  if type(rec) == "table" then
    fail_count = (tonumber(rec.fail_count) or 0) + 1
    first_failed_at = tonumber(rec.first_failed_at) or first_failed_at
    first_failed_at_str = tostring(rec.first_failed_at_str or first_failed_at_str)
  end
  State.cleanup_failures[item.path] = {
    path = item.path,
    why = item.why or "",
    attempts = tonumber(item.attempts) or 0,
    max_attempts = tonumber(item.max_attempts) or 50,
    last_error = tostring(err_txt or ""),
    fail_count = fail_count,
    first_failed_at = first_failed_at,
    first_failed_at_str = first_failed_at_str,
    last_failed_at = now_t,
    last_failed_at_str = os.date("%Y-%m-%d %H:%M:%S", math.floor(now_t))
  }
end

function Cleanup.enqueue_job_cleanup(job)
  ensure_initialized()
  local keep_output = (job.opts and job.opts.keep_output) ~= false
  Cleanup.enqueue_cleanup(job.cfg_path, "curl cfg")
  Cleanup.enqueue_cleanup(job.meta_path, "curl meta")
  Cleanup.enqueue_cleanup(job.hdr_path, "curl headers")
  Cleanup.enqueue_cleanup(job.err_path, "curl stderr")
  if job.payload_path then
    Cleanup.enqueue_cleanup(job.payload_path, "curl payload")
  end
  if (not keep_output) and job.out_path then
    Cleanup.enqueue_cleanup(job.out_path, "curl output")
  end
end

function Cleanup.poll_cleanup_queue(now_t)
  ensure_initialized()
  if not State.cleanup_queue or #State.cleanup_queue == 0 then
    return {
      attempted = 0,
      deleted = 0,
      retry_scheduled = 0,
      skipped_not_due = 0,
      gave_up = 0,
      remaining = 0
    }
  end
  local t = now_t or r.time_precise()
  local remaining = {}
  local stats = {
    attempted = 0,
    deleted = 0,
    retry_scheduled = 0,
    skipped_not_due = 0,
    gave_up = 0,
    remaining = 0
  }
  for i = 1, #State.cleanup_queue do
    local item = State.cleanup_queue[i]
    if item.next_try_at and item.next_try_at > t then
      table.insert(remaining, item)
      stats.skipped_not_due = stats.skipped_not_due + 1
    else
      stats.attempted = stats.attempted + 1
      local ok, err_txt = Files.remove_best_effort(item.path)
      if not ok then
        item.attempts = (item.attempts or 0) + 1
        if item.attempts < (item.max_attempts or 50) then
          local backoff = math.min(0.2 * (2 ^ item.attempts), 6.0)
          item.next_try_at = t + backoff
          table.insert(remaining, item)
          stats.retry_scheduled = stats.retry_scheduled + 1
        else
          record_cleanup_failure(item, err_txt, t)
          Util.msg(
            "cleanup give-up: " ..
            tostring(item.path or "") ..
            " why=" .. tostring(item.why or "") ..
            " attempts=" .. tostring(item.attempts or 0) ..
            " max=" .. tostring(item.max_attempts or 50) ..
            " err=" .. tostring(err_txt or ""),
            2
          )
          stats.gave_up = stats.gave_up + 1
        end
      else
        stats.deleted = stats.deleted + 1
      end
    end
  end
  State.cleanup_queue = remaining
  stats.remaining = #remaining
  return stats
end

return Cleanup
