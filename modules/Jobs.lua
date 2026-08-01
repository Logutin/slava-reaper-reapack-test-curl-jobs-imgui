-- @noindex
-- Jobs orchestrator/scheduler helper module for ReaScript projects.
-- Exported functions:
-- Jobs.init(State, CFG[, opts]): bind shared state/config and optional hooks.
-- Jobs.now(): return scheduler clock value.
-- Jobs.schedule_job(label, fn, delay_sec): queue one delayed job.
-- Jobs.tick_job(): run due scheduled job once.
-- Jobs.tick_all([now_t]): run one orchestrator cycle (scheduler/curl/retry/cleanup).
-- Jobs.format_attempt_label(base_label, attempt, max_attempts): build retry label.
-- Jobs.is_retryable_result(result): classify retryability from curl-like result.
-- Jobs.update_record_retry_state(rec, err_txt, result, snippet): write retry diagnostics to record.
-- Jobs.bump_retry_generation([reason]): increment retry generation and clear retry queue.
-- Jobs.enqueue_retry(label, submit_fn, attempt, max_attempts, err_txt, rec): enqueue one retry task.
-- Jobs.poll_retry_queue([now_t]): execute due retries and keep pending retries.
-- Jobs.manual_retry_record(rec): enqueue manual retry for a record with retry metadata.
-- Jobs.cancel_record(rec[, reason]): mark record canceled and enqueue cleanup paths.
-- Jobs.network_busy(): return whether scheduler/network is busy now.
-- Jobs.any_network_busy(): return whether any scheduler/network work is busy, including background jobs.
-- Jobs.reset_runtime([reason]): reset scheduler/retry/curl runtime state only.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper
local Util = require("modules.Util")
local Curl = require("modules.Curl")
local Cleanup = require("modules.Cleanup")

local Jobs = {}

local DEFAULT_CFG = {
  retry_base_backoff_sec = 1.0,
  max_wait_time_for_retry = 25.0,
  retry_jitter_ratio = 0.0
}

local EVENT_NAMES = {
  job_scheduled = true,
  job_started = true,
  retry_scheduled = true,
  retry_fired = true,
  retry_submit_error = true,
  record_canceled = true,
  runtime_reset = true
}

local State = nil
local CFG = nil
local initialized = false

local now_fn = nil
local rand_fn = nil
local on_event_fn = nil
local is_externally_busy_fn = nil

local function ensure_initialized()
  assert(initialized, "Jobs.init(State, CFG[, opts]) must be called before using Jobs module")
end

local function cfg_value(key)
  local cfg = CFG or {}
  local v = cfg[key]
  if v == nil then
    v = DEFAULT_CFG[key]
  end
  return v
end

local function emit_event(name, payload)
  if not EVENT_NAMES[name] then return end
  if type(on_event_fn) ~= "function" then return end
  local ok, err = pcall(on_event_fn, name, payload)
  if not ok then
    Util.msg("jobs on_event callback error: " .. tostring(err), 2)
  end
end

local function ensure_state_shape(state)
  if type(state.retry_queue) ~= "table" then
    state.retry_queue = {}
  end
  state.retry_generation = tonumber(state.retry_generation) or 0
  if type(state.curl_jobs) ~= "table" then
    state.curl_jobs = {}
  end
  if state.pending_job ~= nil and type(state.pending_job) ~= "table" then
    state.pending_job = nil
  end
  if state.wait_until ~= nil and type(state.wait_until) ~= "number" then
    state.wait_until = nil
  end
  if state.running_label ~= nil and type(state.running_label) ~= "string" then
    state.running_label = tostring(state.running_label)
  end
  if state.ui_lock_network_buttons ~= true then
    state.ui_lock_network_buttons = false
  end
  if type(state.status_text) ~= "string" then
    state.status_text = tostring(state.status_text or "")
  end
end

local function call_now()
  return now_fn()
end

local function call_rand()
  local n = rand_fn()
  n = tonumber(n)
  if not n then return 0.5 end
  if n < 0 then return 0 end
  if n > 1 then return 1 end
  return n
end

local function is_job_running()
  return (State.pending_job ~= nil) or (State.wait_until and call_now() < State.wait_until) or (State.running_label ~= nil)
end

local function is_active_curl_job(job)
  return type(job) == "table" and job.phase ~= "completed"
end

local function is_blocking_curl_job(job)
  if not is_active_curl_job(job) then return false end
  return job.blocking ~= false
end

local function retry_backoff_sec(attempt_1based)
  local attempt = tonumber(attempt_1based) or 1
  if attempt <= 1 then return 0 end
  local base = tonumber(cfg_value("retry_base_backoff_sec")) or 1.0
  local delay = base * (2 ^ (attempt - 2))
  local jitter_ratio = tonumber(cfg_value("retry_jitter_ratio")) or 0
  if jitter_ratio > 0 then
    local jitter_span = delay * jitter_ratio
    delay = delay + ((call_rand() * 2) - 1) * jitter_span
    if delay < 0 then delay = 0 end
  end
  local max_wait = tonumber(cfg_value("max_wait_time_for_retry")) or 25
  if delay > max_wait then
    delay = max_wait
  end
  return delay
end

local function classify_fail_kind(result)
  if not result then return "unknown" end
  if result.timed_out then return "timeout" end
  local http = tonumber(result.http_code)
  if http then return "http_" .. tostring(http) end
  local exitc = tonumber(result.exitcode)
  if exitc and exitc ~= 0 then return "exit_" .. tostring(exitc) end
  return "unknown"
end

local function remove_retry_queue_for_record(rec)
  if not State.retry_queue or #State.retry_queue == 0 then return end
  local remaining = {}
  for i = 1, #State.retry_queue do
    local item = State.retry_queue[i]
    if item.rec ~= rec then
      table.insert(remaining, item)
    end
  end
  State.retry_queue = remaining
end

function Jobs.init(state_tbl, cfg_tbl, opts_tbl)
  assert(type(state_tbl) == "table", "Jobs.init(State, CFG[, opts]): State table required")
  assert(type(cfg_tbl) == "table", "Jobs.init(State, CFG[, opts]): CFG table required")
  if opts_tbl ~= nil then
    assert(type(opts_tbl) == "table", "Jobs.init(State, CFG[, opts]): opts must be a table or nil")
  end
  assert(type(Curl.poll_curl_jobs) == "function", "Jobs.init: Curl.poll_curl_jobs function is required")
  assert(type(Cleanup.poll_cleanup_queue) == "function", "Jobs.init: Cleanup.poll_cleanup_queue function is required")
  assert(type(Cleanup.enqueue_cleanup) == "function", "Jobs.init: Cleanup.enqueue_cleanup function is required")
  assert(type(Cleanup.enqueue_job_cleanup) == "function", "Jobs.init: Cleanup.enqueue_job_cleanup function is required")

  local opts = opts_tbl or {}
  if opts.now_fn ~= nil then
    assert(type(opts.now_fn) == "function", "Jobs.init: opts.now_fn must be a function or nil")
  end
  if opts.rand_fn ~= nil then
    assert(type(opts.rand_fn) == "function", "Jobs.init: opts.rand_fn must be a function or nil")
  end
  if opts.on_event ~= nil then
    assert(type(opts.on_event) == "function", "Jobs.init: opts.on_event must be a function or nil")
  end
  if opts.is_externally_busy ~= nil then
    assert(type(opts.is_externally_busy) == "function", "Jobs.init: opts.is_externally_busy must be a function or nil")
  end

  State = state_tbl
  CFG = cfg_tbl
  now_fn = opts.now_fn or r.time_precise
  rand_fn = opts.rand_fn or math.random
  on_event_fn = opts.on_event
  is_externally_busy_fn = opts.is_externally_busy
  ensure_state_shape(State)
  initialized = true
  return true
end

function Jobs.now()
  ensure_initialized()
  return call_now()
end

function Jobs.schedule_job(label, fn, delay_sec)
  ensure_initialized()
  if State.pending_job or (State.wait_until and call_now() < State.wait_until) then return false end
  local final_label = label or "request"
  State.pending_job = { label = final_label, fn = fn }
  local delay = tonumber(delay_sec) or 0.06
  State.wait_until = call_now() + delay
  State.running_label = nil
  State.status_text = "RUNNING: " .. final_label
  Util.msg("Scheduled job: " .. tostring(final_label), 0)
  emit_event("job_scheduled", {
    label = final_label,
    delay_sec = delay,
    due_at = State.wait_until
  })
  return true
end

function Jobs.tick_job()
  ensure_initialized()
  if not State.pending_job then return false end
  if State.wait_until and call_now() < State.wait_until then return false end

  local job = State.pending_job
  State.pending_job = nil
  State.wait_until = nil
  State.running_label = job.label
  State.status_text = "Running server request: " .. (job.label or "request")
  Util.msg("Running job: " .. tostring(job.label or "request"), 0)
  emit_event("job_started", { label = job.label or "request" })

  if job.fn then job.fn() end
  State.running_label = nil
  return true
end

function Jobs.format_attempt_label(base_label, attempt, max_attempts)
  ensure_initialized()
  local a = tonumber(attempt) or 0
  local m = tonumber(max_attempts) or 0
  if m <= 1 then return base_label end
  return string.format("%s (attempt %d/%d)", tostring(base_label), a, m)
end

function Jobs.is_retryable_result(result)
  ensure_initialized()
  if not result then return true end
  if result.timed_out then return true end
  local http = tonumber(result.http_code)
  if http and http >= 100 then
    if http == 408 then return true end
    if http == 429 then return true end
    if http >= 500 and http <= 599 then return true end
    return false
  end
  local exitc = tonumber(result.exitcode)
  if exitc and exitc ~= 0 then return true end
  return false
end

function Jobs.update_record_retry_state(rec, err_txt, result, snippet)
  ensure_initialized()
  if not rec then return end
  rec._last_error_summary = err_txt
  rec._last_error_snippet = snippet
  rec._last_fail_kind = classify_fail_kind(result)
  rec._last_http_code = result and result.http_code or nil
  rec._last_exitcode = result and result.exitcode or nil
end

function Jobs.bump_retry_generation(reason)
  ensure_initialized()
  State.retry_generation = (tonumber(State.retry_generation) or 0) + 1
  State.retry_queue = {}
  if reason and reason ~= "" then
    Util.msg("Retry queue cleared: " .. tostring(reason), 1)
  end
  return State.retry_generation
end

function Jobs.enqueue_retry(label, submit_fn, attempt, max_attempts, err_txt, rec)
  ensure_initialized()
  if type(submit_fn) ~= "function" then
    return false, "submit_fn missing"
  end
  if not State.retry_queue then State.retry_queue = {} end
  if rec then remove_retry_queue_for_record(rec) end
  local now_t = call_now()
  local delay = retry_backoff_sec(attempt)
  local due_at = now_t + delay
  table.insert(State.retry_queue, {
    label = label or "retry",
    due_at = due_at,
    attempt = attempt,
    max_attempts = max_attempts,
    submit_fn = submit_fn,
    last_err = err_txt or "",
    rec = rec,
    generation = State.retry_generation
  })
  if rec then
    rec._next_retry_at = due_at
    rec._state = "retrying"
  end
  Util.msg(
    "Retry scheduled: " .. tostring(label or "retry") ..
    " (" .. tostring(attempt or 0) .. "/" .. tostring(max_attempts or 0) .. ")" ..
    " in " .. string.format("%.2f", delay) .. "s",
    1
  )
  emit_event("retry_scheduled", {
    label = label or "retry",
    attempt = attempt,
    max_attempts = max_attempts,
    due_at = due_at,
    delay_sec = delay,
    rec = rec
  })
  return true
end

function Jobs.poll_retry_queue(now_t)
  ensure_initialized()
  if not State.retry_queue or #State.retry_queue == 0 then
    return { fired = 0, stale_skipped = 0, submit_errors = 0, remaining = 0 }
  end
  local t = now_t or call_now()
  local remaining = {}
  local fired = 0
  local stale_skipped = 0
  local submit_errors = 0

  for i = 1, #State.retry_queue do
    local item = State.retry_queue[i]
    if item.generation ~= nil and item.generation ~= State.retry_generation then
      stale_skipped = stale_skipped + 1
    elseif item.due_at and item.due_at > t then
      table.insert(remaining, item)
    else
      if item.submit_fn then
        State.status_text = ("Retrying (%d/%d): %s"):format(
          tonumber(item.attempt) or 0,
          tonumber(item.max_attempts) or 0,
          tostring(item.label or "request")
        )
        Util.msg(
          "Retrying: " ..
          tostring(item.label or "request") ..
          " (" .. tostring(item.attempt or 0) .. "/" .. tostring(item.max_attempts or 0) .. ")",
          1
        )
        emit_event("retry_fired", {
          label = item.label or "request",
          attempt = item.attempt,
          max_attempts = item.max_attempts,
          rec = item.rec
        })
        local ok, cb_err = pcall(item.submit_fn)
        if not ok then
          submit_errors = submit_errors + 1
          Util.msg("retry submit error: " .. tostring(cb_err), 2)
          emit_event("retry_submit_error", {
            label = item.label or "request",
            attempt = item.attempt,
            max_attempts = item.max_attempts,
            err = tostring(cb_err),
            rec = item.rec
          })
        end
      end
      fired = fired + 1
    end
  end

  State.retry_queue = remaining
  return {
    fired = fired,
    stale_skipped = stale_skipped,
    submit_errors = submit_errors,
    remaining = #remaining
  }
end

function Jobs.manual_retry_record(rec)
  ensure_initialized()
  if not rec or type(rec._retry_submit) ~= "function" then
    return false, "manual retry not available"
  end
  remove_retry_queue_for_record(rec)
  rec._attempt = 1
  rec._retry_generation = State.retry_generation
  rec._state = "retrying"
  rec._force_truncate = true
  rec._last_error_summary = nil
  rec._last_error_snippet = nil
  rec._last_fail_kind = nil
  rec._next_retry_at = nil
  return Jobs.enqueue_retry(
    rec._retry_label or "retry",
    rec._retry_submit,
    rec._attempt,
    rec._max_attempts or 1,
    "manual retry",
    rec
  )
end

function Jobs.cancel_record(rec, reason)
  ensure_initialized()
  if not rec then return false, "record missing" end
  rec._state = "canceled"
  rec._next_retry_at = nil
  remove_retry_queue_for_record(rec)
  if rec.input_path and rec.input_path ~= "" then
    Cleanup.enqueue_cleanup(rec.input_path, "retry canceled input")
  end
  if rec.output_path and rec.output_path ~= "" then
    Cleanup.enqueue_cleanup(rec.output_path, "retry canceled output")
  end
  if reason and reason ~= "" then
    rec._last_error_summary = reason
  end
  emit_event("record_canceled", { rec = rec, reason = reason })
  return true
end

function Jobs.network_busy()
  ensure_initialized()
  if is_job_running() or (State.ui_lock_network_buttons == true) then return true end

  if is_externally_busy_fn then
    local ok, is_busy = pcall(is_externally_busy_fn, State)
    if not ok then
      Util.msg("jobs is_externally_busy callback error: " .. tostring(is_busy), 2)
    elseif is_busy == true then
      return true
    end
  end

  if State.curl_jobs then
    for _, job in pairs(State.curl_jobs) do
      if is_blocking_curl_job(job) then
        return true
      end
    end
  end
  return false
end

function Jobs.any_network_busy()
  ensure_initialized()
  if is_job_running() or (State.ui_lock_network_buttons == true) then return true end

  if is_externally_busy_fn then
    local ok, is_busy = pcall(is_externally_busy_fn, State)
    if not ok then
      Util.msg("jobs is_externally_busy callback error: " .. tostring(is_busy), 2)
    elseif is_busy == true then
      return true
    end
  end

  if State.curl_jobs then
    for _, job in pairs(State.curl_jobs) do
      if is_active_curl_job(job) then
        return true
      end
    end
  end
  return false
end

local function parse_reset_runtime_args(reason_or_opts)
  if type(reason_or_opts) == "table" then
    return {
      reason = tostring(reason_or_opts.reason or "reset runtime"),
      scope = tostring(reason_or_opts.scope or "workflow")
    }
  end
  return {
    reason = tostring(reason_or_opts or "reset runtime"),
    scope = "workflow"
  }
end

local function reset_should_remove_job(job, scope)
  if tostring(scope or "workflow") == "all" then return true end
  local owner = tostring(job and job.owner or "workflow")
  return owner == tostring(scope or "workflow")
end

function Jobs.reset_runtime(reason)
  ensure_initialized()
  local args = parse_reset_runtime_args(reason)
  local why = args.reason
  local scope = args.scope
  Jobs.bump_retry_generation(why)
  State.pending_job = nil
  State.wait_until = nil
  State.running_label = nil
  State.ui_lock_network_buttons = false

  if State.curl_jobs then
    local remaining = {}
    for id, job in pairs(State.curl_jobs) do
      if reset_should_remove_job(job, scope) then
        local ok, err = pcall(Cleanup.enqueue_job_cleanup, job)
        if not ok then
          Util.msg("jobs reset cleanup enqueue error: " .. tostring(err), 2)
        end
      else
        remaining[id] = job
      end
    end
    State.curl_jobs = remaining
  end

  if State.curl_jobs_selected_id ~= nil and (not State.curl_jobs or State.curl_jobs[State.curl_jobs_selected_id] == nil) then
    State.curl_jobs_selected_id = nil
  end
  emit_event("runtime_reset", { reason = why, scope = scope })
  return true
end

function Jobs.tick_all(now_t)
  ensure_initialized()
  local t = now_t or call_now()
  local stats = {
    job_ran = false,
    curl_polled = false,
    retries_fired = 0,
    retry_submit_errors = 0,
    retry_stale_skipped = 0,
    cleanup_polled = false,
    cleanup_attempted = 0,
    cleanup_deleted = 0,
    cleanup_retry_scheduled = 0,
    cleanup_skipped_not_due = 0,
    cleanup_gave_up = 0,
    cleanup_remaining = 0
  }

  stats.job_ran = (Jobs.tick_job() == true)
  Curl.poll_curl_jobs(t)
  stats.curl_polled = true
  local retry_stats = Jobs.poll_retry_queue(t)
  stats.retries_fired = tonumber(retry_stats and retry_stats.fired) or 0
  stats.retry_submit_errors = tonumber(retry_stats and retry_stats.submit_errors) or 0
  stats.retry_stale_skipped = tonumber(retry_stats and retry_stats.stale_skipped) or 0
  local cleanup_stats = Cleanup.poll_cleanup_queue(t) or {}
  stats.cleanup_attempted = tonumber(cleanup_stats.attempted) or 0
  stats.cleanup_deleted = tonumber(cleanup_stats.deleted) or 0
  stats.cleanup_retry_scheduled = tonumber(cleanup_stats.retry_scheduled) or 0
  stats.cleanup_skipped_not_due = tonumber(cleanup_stats.skipped_not_due) or 0
  stats.cleanup_gave_up = tonumber(cleanup_stats.gave_up) or 0
  stats.cleanup_remaining = tonumber(cleanup_stats.remaining) or 0
  stats.cleanup_polled = true
  return stats
end

return Jobs

