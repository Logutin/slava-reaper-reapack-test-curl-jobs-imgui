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
local DEFAULT_CFG = { retry_base_backoff_sec = 1.0, max_wait_time_for_retry = 25.0, retry_jitter_ratio = 0.0 }
local EVENT_NAMES = { job_scheduled=true, job_started=true, retry_scheduled=true, retry_fired=true, retry_submit_error=true, record_canceled=true, runtime_reset=true }
local State, CFG, initialized = nil, nil, false
local now_fn, rand_fn, on_event_fn, is_externally_busy_fn
local function ensure_initialized() assert(initialized, "Jobs.init(State, CFG[, opts]) must be called before using Jobs module") end
local function cfg_value(key) local v=(CFG or {})[key]; if v==nil then v=DEFAULT_CFG[key] end; return v end
local function emit_event(name,payload) if not EVENT_NAMES[name] or type(on_event_fn)~="function" then return end; local ok,err=pcall(on_event_fn,name,payload); if not ok then Util.msg("jobs on_event callback error: "..tostring(err),2) end end
local function ensure_state_shape(state)
  if type(state.retry_queue)~="table" then state.retry_queue={} end
  state.retry_generation=tonumber(state.retry_generation) or 0
  if type(state.curl_jobs)~="table" then state.curl_jobs={} end
  if state.pending_job~=nil and type(state.pending_job)~="table" then state.pending_job=nil end
  if state.wait_until~=nil and type(state.wait_until)~="number" then state.wait_until=nil end
  if state.running_label~=nil and type(state.running_label)~="string" then state.running_label=tostring(state.running_label) end
  if state.ui_lock_network_buttons~=true then state.ui_lock_network_buttons=false end
  if type(state.status_text)~="string" then state.status_text=tostring(state.status_text or "") end
end
local function call_now() return now_fn() end
local function call_rand() local n=tonumber(rand_fn()); if not n then return .5 end; if n<0 then return 0 end; if n>1 then return 1 end; return n end
local function is_job_running() return State.pending_job~=nil or (State.wait_until and call_now()<State.wait_until) or State.running_label~=nil end
local function is_active_curl_job(job) return type(job)=="table" and job.phase~="completed" end
local function is_blocking_curl_job(job) return is_active_curl_job(job) and job.blocking~=false end
local function retry_backoff_sec(attempt)
  attempt=tonumber(attempt) or 1; if attempt<=1 then return 0 end
  local delay=(tonumber(cfg_value("retry_base_backoff_sec")) or 1)*(2^(attempt-2))
  local jr=tonumber(cfg_value("retry_jitter_ratio")) or 0
  if jr>0 then delay=math.max(0,delay+((call_rand()*2)-1)*delay*jr) end
  return math.min(delay,tonumber(cfg_value("max_wait_time_for_retry")) or 25)
end
local function classify_fail_kind(result) if not result then return "unknown" end; if result.timed_out then return "timeout" end; local h=tonumber(result.http_code); if h then return "http_"..h end; local e=tonumber(result.exitcode); if e and e~=0 then return "exit_"..e end; return "unknown" end
local function remove_retry_queue_for_record(rec) local out={}; for i=1,#(State.retry_queue or {}) do local x=State.retry_queue[i]; if x.rec~=rec then out[#out+1]=x end end; State.retry_queue=out end
function Jobs.init(state,cfg,opts)
  assert(type(state)=="table" and type(cfg)=="table"); opts=opts or {}; assert(type(opts)=="table")
  State,CFG=state,cfg; now_fn=opts.now_fn or r.time_precise; rand_fn=opts.rand_fn or math.random; on_event_fn=opts.on_event; is_externally_busy_fn=opts.is_externally_busy
  ensure_state_shape(State); initialized=true; return true
end
function Jobs.now() ensure_initialized(); return call_now() end
function Jobs.schedule_job(label,fn,delay)
  ensure_initialized(); if State.pending_job or (State.wait_until and call_now()<State.wait_until) then return false end
  label=label or "request"; State.pending_job={label=label,fn=fn}; delay=tonumber(delay) or .06; State.wait_until=call_now()+delay; State.running_label=nil; State.status_text="RUNNING: "..label; Util.msg("Scheduled job: "..label,0); emit_event("job_scheduled",{label=label,delay_sec=delay,due_at=State.wait_until}); return true
end
function Jobs.tick_job()
  ensure_initialized(); if not State.pending_job or (State.wait_until and call_now()<State.wait_until) then return false end
  local job=State.pending_job; State.pending_job=nil; State.wait_until=nil; State.running_label=job.label; State.status_text="Running server request: "..(job.label or "request"); emit_event("job_started",{label=job.label or "request"}); if job.fn then job.fn() end; State.running_label=nil; return true
end
function Jobs.format_attempt_label(base,a,m) ensure_initialized(); a=tonumber(a) or 0; m=tonumber(m) or 0; if m<=1 then return base end; return string.format("%s (attempt %d/%d)",tostring(base),a,m) end
function Jobs.is_retryable_result(result) ensure_initialized(); if not result or result.timed_out then return true end; local h=tonumber(result.http_code); if h and h>=100 then return h==408 or h==429 or (h>=500 and h<=599) end; local e=tonumber(result.exitcode); return e~=nil and e~=0 end
function Jobs.update_record_retry_state(rec,err,result,snippet) ensure_initialized(); if rec then rec._last_error_summary=err; rec._last_error_snippet=snippet; rec._last_fail_kind=classify_fail_kind(result); rec._last_http_code=result and result.http_code; rec._last_exitcode=result and result.exitcode end end
function Jobs.bump_retry_generation(reason) ensure_initialized(); State.retry_generation=(tonumber(State.retry_generation) or 0)+1; State.retry_queue={}; if reason and reason~="" then Util.msg("Retry queue cleared: "..tostring(reason),1) end; return State.retry_generation end
function Jobs.enqueue_retry(label,submit_fn,attempt,max_attempts,err_txt,rec)
  ensure_initialized(); if type(submit_fn)~="function" then return false,"submit_fn missing" end; if rec then remove_retry_queue_for_record(rec) end
  local delay=retry_backoff_sec(attempt); local due=call_now()+delay; State.retry_queue[#State.retry_queue+1]={label=label or "retry",due_at=due,attempt=attempt,max_attempts=max_attempts,submit_fn=submit_fn,last_err=err_txt or "",rec=rec,generation=State.retry_generation}
  if rec then rec._next_retry_at=due; rec._state="retrying" end; emit_event("retry_scheduled",{label=label or "retry",attempt=attempt,max_attempts=max_attempts,due_at=due,delay_sec=delay,rec=rec}); return true
end
function Jobs.poll_retry_queue(now)
  ensure_initialized(); if #(State.retry_queue or {})==0 then return {fired=0,stale_skipped=0,submit_errors=0,remaining=0} end
  local t=now or call_now(); local remain={}; local fired,stale,errors=0,0,0
  for i=1,#State.retry_queue do local item=State.retry_queue[i]; if item.generation~=nil and item.generation~=State.retry_generation then stale=stale+1 elseif item.due_at and item.due_at>t then remain[#remain+1]=item else if item.submit_fn then emit_event("retry_fired",item); local ok,err=pcall(item.submit_fn); if not ok then errors=errors+1; Util.msg("retry submit error: "..tostring(err),2); emit_event("retry_submit_error",{err=tostring(err),rec=item.rec}) end end; fired=fired+1 end end
  State.retry_queue=remain; return {fired=fired,stale_skipped=stale,submit_errors=errors,remaining=#remain}
end
function Jobs.manual_retry_record(rec) ensure_initialized(); if not rec or type(rec._retry_submit)~="function" then return false,"manual retry not available" end; remove_retry_queue_for_record(rec); rec._attempt=1; rec._retry_generation=State.retry_generation; rec._state="retrying"; rec._force_truncate=true; rec._last_error_summary=nil; rec._last_error_snippet=nil; rec._last_fail_kind=nil; rec._next_retry_at=nil; return Jobs.enqueue_retry(rec._retry_label or "retry",rec._retry_submit,rec._attempt,rec._max_attempts or 1,"manual retry",rec) end
function Jobs.cancel_record(rec,reason) ensure_initialized(); if not rec then return false,"record missing" end; rec._state="canceled"; rec._next_retry_at=nil; remove_retry_queue_for_record(rec); if rec.input_path and rec.input_path~="" then Cleanup.enqueue_cleanup(rec.input_path,"retry canceled input") end; if rec.output_path and rec.output_path~="" then Cleanup.enqueue_cleanup(rec.output_path,"retry canceled output") end; if reason and reason~="" then rec._last_error_summary=reason end; emit_event("record_canceled",{rec=rec,reason=reason}); return true end
local function external_busy() if not is_externally_busy_fn then return false end; local ok,b=pcall(is_externally_busy_fn,State); if not ok then Util.msg("jobs is_externally_busy callback error: "..tostring(b),2); return false end; return b==true end
function Jobs.network_busy() ensure_initialized(); if is_job_running() or State.ui_lock_network_buttons or external_busy() then return true end; for _,j in pairs(State.curl_jobs or {}) do if is_blocking_curl_job(j) then return true end end; return false end
function Jobs.any_network_busy() ensure_initialized(); if is_job_running() or State.ui_lock_network_buttons or external_busy() then return true end; for _,j in pairs(State.curl_jobs or {}) do if is_active_curl_job(j) then return true end end; return false end
local function parse_reset_runtime_args(x) if type(x)=="table" then return {reason=tostring(x.reason or "reset runtime"),scope=tostring(x.scope or "workflow")} end; return {reason=tostring(x or "reset runtime"),scope="workflow"} end
function Jobs.reset_runtime(reason)
  ensure_initialized(); local a=parse_reset_runtime_args(reason); Jobs.bump_retry_generation(a.reason); State.pending_job=nil; State.wait_until=nil; State.running_label=nil; State.ui_lock_network_buttons=false
  local remain={}; for id,j in pairs(State.curl_jobs or {}) do if a.scope=="all" or tostring(j.owner or "workflow")==a.scope then pcall(Cleanup.enqueue_job_cleanup,j) else remain[id]=j end end; State.curl_jobs=remain
  if State.curl_jobs_selected_id and not State.curl_jobs[State.curl_jobs_selected_id] then State.curl_jobs_selected_id=nil end; emit_event("runtime_reset",a); return true
end
function Jobs.tick_all(now)
  ensure_initialized(); local t=now or call_now(); local s={job_ran=Jobs.tick_job()==true,curl_polled=false,retries_fired=0,retry_submit_errors=0,retry_stale_skipped=0,cleanup_polled=false,cleanup_attempted=0,cleanup_deleted=0,cleanup_retry_scheduled=0,cleanup_skipped_not_due=0,cleanup_gave_up=0,cleanup_remaining=0}
  Curl.poll_curl_jobs(t); s.curl_polled=true; local rs=Jobs.poll_retry_queue(t); s.retries_fired=tonumber(rs.fired) or 0; s.retry_submit_errors=tonumber(rs.submit_errors) or 0; s.retry_stale_skipped=tonumber(rs.stale_skipped) or 0
  local cs=Cleanup.poll_cleanup_queue(t) or {}; s.cleanup_attempted=tonumber(cs.attempted) or 0; s.cleanup_deleted=tonumber(cs.deleted) or 0; s.cleanup_retry_scheduled=tonumber(cs.retry_scheduled) or 0; s.cleanup_skipped_not_due=tonumber(cs.skipped_not_due) or 0; s.cleanup_gave_up=tonumber(cs.gave_up) or 0; s.cleanup_remaining=tonumber(cs.remaining) or 0; s.cleanup_polled=true; return s
end
return Jobs
