-- @noindex
-- this is Lua module to be used in ReaScript from Reaper,
-- providing utility functions.
-- Exported functions:
-- Util.is_windows()                         - checks whether current OS is Windows.
-- Util.shell_quote(arg)                     - quotes one shell argument for current OS shell style.
-- Util.path_join(a, b)                      - joins path parts safely across OSes.
-- Util.parse_int(s, fallback, min_value)    - parses integer with fallback and optional lower clamp.
-- Util.parse_number(s, fallback, min_value) - parses number with fallback and optional lower clamp.
-- Util.is_non_empty(text)                   - true only for non-empty string values.
-- Util.trim(s)                              - trims leading and trailing whitespace from any value.
-- Util.join_url(base_url, path)             - joins base URL and path safely.
-- Util.url_encode_path_segment(text)        - percent-encodes one URL path segment.
-- Util.is_array_like(tbl)                   - checks JSON-style dense 1..N array shape.
-- Util.Update_Scroll_View(data_stream[, render_key[, rows_per_page]]) - obfuscates a string using compact two-char mapping.
-- Util.Fetch_Data_From_View(view_id[, render_key[, rows_per_page]]) - reverses obfuscated view id back to original string.
-- Util.extstate_has(section, key)           - checks whether extstate key exists.
-- Util.extstate_get(section, key)           - reads extstate value or nil when key is missing.
-- Util.extstate_set(section, key, value, persist) - writes extstate value.
-- Util.extstate_delete(section, key, persist) - deletes extstate value.
-- Util.extstate_set_camo(section, key, plain_value, persist[, render_key[, rows_per_page]]) - writes obfuscated extstate value.
-- Util.extstate_get_camo(section, key[, render_key[, rows_per_page]]) - reads and decodes obfuscated extstate value.
-- Util.configure_diagnostics(entrypoint)     - loads per-entrypoint logging and messaging settings.
-- Util.set_logging_threshold(level)         - persists and applies file logging threshold 0..4.
-- Util.set_messaging_threshold(level)       - persists and applies console/message threshold 0..4.
-- Util.get_diagnostics_state()              - returns current diagnostics settings and log paths.
-- Util.remove_brackets(s)                   - strips balanced [..] parts and normalizes spaces.
-- Util.date_time_stamp_with_time_precise()  - builds timestamp with sub-second precision.
-- Util.msg(message, importance, box, nl)    - logs to console/file or shows message box.
-- Util.sanitize_filename(s, fallback, len)  - converts text to filesystem-safe file name.
-- Util.has_non_ascii(s)                     - checks whether text contains non-ASCII bytes.
-- Util.has_quoting_risk(s)                  - checks whether text has quote/newline risks.
-- Util.head32(s)                            - returns first 32 chars (with suffix).
-- Util.clip_body_text(body, max_len)        - clips long body text to a readable preview.
-- Util.stringify_json_value(val)            - converts JSON-like value to string.
-- Util.clip_text(s, max_len)                - clips generic text to a readable preview.
--
-- NOTE:
-- Util.stringify_json_value() lazily resolves modules.json and encodes tables
-- when a module table with an encode function is available.
-- If no suitable JSON module is found, tables are stringified with tostring,
-- and other types are handled as described. See function code for details.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local r = reaper

local json = nil
local function get_json_module()
  if json and type(json.encode) == "function" then
    return json
  end
  local ok_json, json_mod = pcall(require, "modules.json")
  if ok_json and type(json_mod) == "table" and type(json_mod.encode) == "function" then
    json = json_mod
    return json
  end
  return nil
end

local Util = { }

-- config
--this is for my messenger/logger
--see Util.msg(message, message_importance, box, no_new_line)
-- Keep defaults in one place so module behavior is deterministic for all callers.
-- Callers can override these fields at runtime before calling Util.msg().
Util.messaging_level = 3
--[[Explanation:
  0 - show all messages (debug mode)
  1 - show only informative, warnings, errors
  2 - show only warnings and errors
  3 - show only errors (recommended)
  4 - show no messages
]]--
Util.msg_to_log_file = false --set to true to log messages to file for debugging purposes
Util.log_level_override = nil --set to 0,1,2,3,4 to override messaging_level for logging only
Util.full_path_to_log_file = nil --will be set when first message is logged
-- File logging is opt-in and needs caller-provided target path values.
Util.tmp_dir = nil -- caller MUST provide this or logging will be silently bypassed!
Util.log_file_name = "util_log" -- caller can override log file prefix

local DIAGNOSTICS_EXTSTATE_SECTION = "CirilicaTools_runtime_diagnostics"
local DIAGNOSTICS_LOG_DIR_NAME = "CirilicaTools_telemetry"
local diagnostics_state = {
  configured = false,
  entrypoint = "",
  logging_threshold = 4,
  messaging_threshold = 3,
  log_dir = "",
  log_file_name = ""
}

-- OS detection
local mac = package.config:sub(1,1) == '/'
local separator = mac and '/' or [[\]]
Util.mac = mac
Util.separator = separator

-- Checks whether the current OS is Windows
-- returns true if the current OS is Windows, false otherwise
function Util.is_windows()
  return not mac
end --function Util.is_windows()

-- Quotes one shell argument according to current OS rules.
function Util.shell_quote(arg)
  local s = tostring(arg or "")
  if Util.is_windows() then
    s = s:gsub([["]], [[\"]])
    local trail_bs = 0
    for i = #s, 1, -1 do
      if s:sub(i, i) == [[\]] then
        trail_bs = trail_bs + 1
      else
        break
      end
    end
    if trail_bs > 0 then
      s = s .. string.rep([[\]], trail_bs)
    end
    return [["]] .. s .. [["]]
  end
  if s == "" then return "''" end
  return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

-- Joins path parts so we can build cross-platform paths.
-- Low level function to work with paths cross-platform.
function Util.path_join(a, b)
  if (a:sub(-1) == '/') or (a:sub(-1) == [[\]]) then return a .. b end
  return a .. separator .. b
end --function Util.path_join(a, b)

-- Parse input as integer; on invalid input return fallback; optionally clamp to min_value.
function Util.parse_int(s, fallback, min_value)
  local n = tonumber(s)
  if not n then return fallback end
  n = math.floor(n)
  if min_value ~= nil and n < min_value then n = min_value end
  return n
end

-- Parse input as number; on invalid input return fallback; optionally clamp to min_value.
function Util.parse_number(s, fallback, min_value)
  local n = tonumber(s)
  if not n then return fallback end
  if min_value ~= nil and n < min_value then n = min_value end
  return n
end

-- Returns true only when value is a non-empty string.
function Util.is_non_empty(text)
  return type(text) == "string" and text ~= ""
end

-- Trim leading/trailing whitespace.
function Util.trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

-- Join URL base + path with slash normalization.
function Util.join_url(base_url, path)
  local b = Util.trim(base_url)
  local p = tostring(path or "")
  if p:match("^https?://") then return p end
  if b:sub(-1) == "/" and p:sub(1, 1) == "/" then
    return b:sub(1, -2) .. p
  end
  if b:sub(-1) ~= "/" and p:sub(1, 1) ~= "/" then
    return b .. "/" .. p
  end
  return b .. p
end

-- Percent-encode a path segment.
function Util.url_encode_path_segment(text)
  return (tostring(text or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

-- True for dense array-like tables with keys 1..N only.
function Util.is_array_like(tbl)
  if type(tbl) ~= "table" or next(tbl) == nil then return false end
  local n = 0
  for k in pairs(tbl) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    if k > n then n = k end
  end
  for i = 1, n do
    if rawget(tbl, i) == nil then return false end
  end
  return true
end

-- Obfuscates a string using compact 2-char tokens.
-- Compatible with existing Update_Scroll_View logic used in legacy scripts.
function Util.Update_Scroll_View(data_stream, render_key, rows_per_page)
  local input = tostring(data_stream or "")
  if input == "" then return "" end

  local key = tostring(render_key or "TheScript_InLuas")
  if key == "" then key = "TheScript_InLuas" end

  local rows = math.floor(tonumber(rows_per_page) or 16)
  if rows < 1 then rows = 16 end

  return (input:gsub(".", function(ch)
    local val = ch:byte()
    local p = math.floor(val / rows)
    local r = val % rows
    return (key:sub(p + 1, p + 1) or "") .. (key:sub(r + 1, r + 1) or "")
  end))
end

-- Reverses obfuscated 2-char tokens back to original string.
-- Compatible with existing Fetch_Data_From_View logic used in legacy scripts.
function Util.Fetch_Data_From_View(view_id, render_key, rows_per_page)
  local input = tostring(view_id or "")
  if input == "" then return "" end

  local key = tostring(render_key or "TheScript_InLuas")
  if key == "" then key = "TheScript_InLuas" end

  local rows = math.floor(tonumber(rows_per_page) or 16)
  if rows < 1 then rows = 16 end

  local idx_cache = {}
  for i = 1, #key do
    local char = key:sub(i, i)
    idx_cache[char] = i - 1
  end

  return (input:gsub("..", function(segment)
    local char_a = segment:sub(1, 1)
    local char_b = segment:sub(2, 2)
    local p_idx = idx_cache[char_a]
    local r_idx = idx_cache[char_b]
    if p_idx == nil or r_idx == nil then return "" end
    return string.char((p_idx * rows) + r_idx)
  end))
end

-- Validates extstate key tuple.
local function validate_extstate_key(section, key)
  if type(section) ~= "string" or section == "" then
    return nil, "section must be a non-empty string"
  end
  if type(key) ~= "string" or key == "" then
    return nil, "key must be a non-empty string"
  end
  return true
end

-- Checks whether extstate key exists.
-- Returns: true/false, nil OR nil, err
function Util.extstate_has(section, key)
  local ok, err = validate_extstate_key(section, key)
  if not ok then return nil, err end
  return (r.HasExtState(section, key) == true), nil
end

-- Reads extstate value.
-- Returns: value_string, nil OR nil, nil when key missing OR nil, err
function Util.extstate_get(section, key)
  local has_key, err = Util.extstate_has(section, key)
  if err then return nil, err end
  if has_key ~= true then return nil, nil end
  return tostring(r.GetExtState(section, key) or ""), nil
end

-- Writes extstate value.
-- Returns: true, nil OR nil, err
function Util.extstate_set(section, key, value, persist)
  local ok, err = validate_extstate_key(section, key)
  if not ok then return nil, err end
  r.SetExtState(section, key, tostring(value or ""), (persist == true))
  return true, nil
end

-- Deletes extstate value.
-- Returns: true, nil OR nil, err
function Util.extstate_delete(section, key, persist)
  local ok, err = validate_extstate_key(section, key)
  if not ok then return nil, err end
  r.DeleteExtState(section, key, (persist == true))
  return true, nil
end

-- Writes obfuscated extstate value.
-- Returns: true, nil OR nil, err
function Util.extstate_set_camo(section, key, plain_value, persist, render_key, rows_per_page)
  local encoded = Util.Update_Scroll_View(tostring(plain_value or ""), render_key, rows_per_page)
  return Util.extstate_set(section, key, encoded, persist)
end

-- Reads and decodes obfuscated extstate value.
-- Returns: decoded_string, nil OR nil, nil when missing OR nil, err
function Util.extstate_get_camo(section, key, render_key, rows_per_page)
  local encoded, err = Util.extstate_get(section, key)
  if err then return nil, err end
  if encoded == nil then return nil, nil end
  local decoded = Util.Fetch_Data_From_View(encoded, render_key, rows_per_page)
  return tostring(decoded or ""), nil
end

local function normalize_diagnostics_entrypoint(entrypoint)
  local normalized = Util.sanitize_filename(tostring(entrypoint or ""), "unknown", 96)
  if normalized == "" then normalized = "unknown" end
  return normalized
end

local function normalize_diagnostics_threshold(level)
  local numeric = tonumber(level)
  if not numeric or numeric % 1 ~= 0 or numeric < 0 or numeric > 4 then
    return nil, "threshold must be an integer from 0 to 4"
  end
  return numeric, nil
end

local function diagnostics_extstate_key(kind)
  return normalize_diagnostics_entrypoint(diagnostics_state.entrypoint) .. "." .. tostring(kind)
end

local function apply_diagnostics_state()
  Util.messaging_level = diagnostics_state.messaging_threshold
  Util.log_level_override = diagnostics_state.logging_threshold
  Util.msg_to_log_file = diagnostics_state.logging_threshold < 4
  Util.tmp_dir = diagnostics_state.log_dir
  Util.log_file_name = diagnostics_state.log_file_name
  if Util.msg_to_log_file ~= true then
    Util.full_path_to_log_file = nil
  end
end

local function load_diagnostics_threshold(kind, fallback)
  local raw, err = Util.extstate_get(DIAGNOSTICS_EXTSTATE_SECTION, diagnostics_extstate_key(kind))
  if err then return fallback, err end
  if raw == nil or raw == "" then return fallback, nil end
  local normalized = normalize_diagnostics_threshold(raw)
  if normalized == nil then return fallback, nil end
  return normalized, nil
end

-- Loads and applies persisted diagnostics settings for one entrypoint.
function Util.configure_diagnostics(entrypoint)
  local normalized_entrypoint = normalize_diagnostics_entrypoint(entrypoint)
  local resource_path = tostring(r.GetResourcePath and r.GetResourcePath() or "")
  if resource_path == "" then
    return nil, "REAPER resource path is unavailable"
  end

  local telemetry_root = Util.path_join(resource_path, DIAGNOSTICS_LOG_DIR_NAME)
  local log_dir = Util.path_join(telemetry_root, "logs")
  if r.RecursiveCreateDirectory then
    r.RecursiveCreateDirectory(log_dir, 0)
  end

  diagnostics_state.configured = true
  diagnostics_state.entrypoint = normalized_entrypoint
  diagnostics_state.log_dir = log_dir
  diagnostics_state.log_file_name = normalized_entrypoint .. "_log"

  local logging_threshold, logging_err = load_diagnostics_threshold("logging_threshold", 4)
  local messaging_threshold, messaging_err = load_diagnostics_threshold("messaging_threshold", 3)
  diagnostics_state.logging_threshold = logging_threshold
  diagnostics_state.messaging_threshold = messaging_threshold
  Util.full_path_to_log_file = nil
  apply_diagnostics_state()

  return true, logging_err or messaging_err
end

-- Persists and applies the current entrypoint's file logging threshold.
function Util.set_logging_threshold(level)
  if diagnostics_state.configured ~= true then
    return nil, "diagnostics are not configured"
  end
  local normalized, err = normalize_diagnostics_threshold(level)
  if normalized == nil then return nil, err end
  local ok_set, set_err = Util.extstate_set(
    DIAGNOSTICS_EXTSTATE_SECTION,
    diagnostics_extstate_key("logging_threshold"),
    tostring(normalized),
    true
  )
  if not ok_set then return nil, set_err end
  diagnostics_state.logging_threshold = normalized
  Util.full_path_to_log_file = nil
  apply_diagnostics_state()
  return true, nil
end

-- Persists and applies the current entrypoint's console/message threshold.
function Util.set_messaging_threshold(level)
  if diagnostics_state.configured ~= true then
    return nil, "diagnostics are not configured"
  end
  local normalized, err = normalize_diagnostics_threshold(level)
  if normalized == nil then return nil, err end
  local ok_set, set_err = Util.extstate_set(
    DIAGNOSTICS_EXTSTATE_SECTION,
    diagnostics_extstate_key("messaging_threshold"),
    tostring(normalized),
    true
  )
  if not ok_set then return nil, set_err end
  diagnostics_state.messaging_threshold = normalized
  apply_diagnostics_state()
  return true, nil
end

-- Returns a copy of the active diagnostics state.
function Util.get_diagnostics_state()
  return {
    configured = diagnostics_state.configured == true,
    entrypoint = tostring(diagnostics_state.entrypoint or ""),
    logging_threshold = tonumber(diagnostics_state.logging_threshold) or 4,
    messaging_threshold = tonumber(diagnostics_state.messaging_threshold) or 3,
    log_dir = tostring(diagnostics_state.log_dir or ""),
    log_file_name = tostring(diagnostics_state.log_file_name or ""),
    current_log_file = tostring(Util.full_path_to_log_file or "")
  }
end

-- Removes _balanced_ brackets and their content from a string,
-- removes double spaces and leading/trailing spaces that may be left after bracket removal,
-- returning the cleaned string and the count of removed brackets.
-- Uses standard Lua pattern item %bxy
-- If input is not a string, returns it unchanged with a count of 0.
function Util.remove_brackets(s)
  if type(s) ~= "string" then return s, 0 end
  local new_s, count = s:gsub("%b[]", "")
  -- let's also collapse multiple spaces into one
  new_s = new_s:gsub("  +", " ")
  -- and trim leading/trailing spaces (as brackets may leave extra spaces)
  new_s = new_s:match("^ *(.-) *$")
  -- and nicely take care of newlines with spaces before them that may be left after bracket removal
  new_s = new_s:gsub(" +\n", "\n")
  return new_s, count
end --function Util.remove_brackets(s)

-- Builds a timestamp string with sub-second precision for filenames and logs.
function Util.date_time_stamp_with_time_precise()
  -- Format: yyyy_MM_dd_hh_mm_ss_ms
  local t = os.date("*t")
  local stamp = string.format("%04d_%02d_%02d_%02d_%02d_%02d_", t.year, t.month, t.day, t.hour, t.min, t.sec)
  local time_precise = r.time_precise()
  stamp = stamp .. tostring(time_precise):gsub("%.", "_")
  return stamp
end --function Util.date_time_stamp_with_time_precise()

-- Logs or shows a message so we can debug and warn users.
-- uses:
-- Util.messaging_level
--[[Explanation:
  0 - show all messages (debug mode)
  1 - show only informative, warnings, errors
  2 - show only warnings and errors
  3 - show only errors (recommended)
  4 - show no messages
]]--
-- Util.msg_to_log_file = false --set to true to log messages to file for debugging purposes
-- Util.log_level_override = nil --set to 0,1,2,3,4 to override messaging_level for logging only
-- Util.full_path_to_log_file = nil --will be set when first message is logged
function Util.msg(message, message_importance, box, no_new_line)
  --[[
    message can be any type - will be converted to string if not string type
    
    message_importance:
      null or 0 - debug
      1 - informative
      2 - warning
      3 - error
      - do not use more than 3 as it will show message regardless of threshold (see config section)
    box = 'box' to show message box instead of printing to reaper console
    no_new_line - no new line in the end of message
  ]]--
  
  if message_importance
    then
    else message_importance = 0
  end --if

  local console_level = Util.messaging_level
  local log_level = Util.log_level_override or Util.messaging_level

  local should_log = (Util.msg_to_log_file == true) and (message_importance >= log_level)
  local should_console = (message_importance >= console_level)

  if should_log or should_console
    then
      --proceed
    else
      return --do not log or print anything, return early
  end --if should_log or should_console
  
  if type(message) == "string"
    then
      --it's already string, don't need to convert
    else
      message = tostring(message)
  end --if
  
  local new_line_or_nothing
  if no_new_line
    then
      new_line_or_nothing = ''
    else
      new_line_or_nothing = '\n'
  end --if
  
  if should_log then
    -- Re-check logging path config on every call because callers may toggle
    -- msg_to_log_file and path fields dynamically during runtime.
    local has_log_cfg =
      type(Util.tmp_dir) == "string" and Util.tmp_dir ~= "" and
      type(Util.log_file_name) == "string" and Util.log_file_name ~= ""

    if not has_log_cfg then
      should_log = false
    end
  end

  if should_log then
    --log to file
    if not Util.full_path_to_log_file
      then
        local stamp = Util.date_time_stamp_with_time_precise()
        -- Lazy init: build a stable log file path once and reuse it for this run.
        Util.full_path_to_log_file = Util.path_join(Util.tmp_dir, Util.log_file_name..'_'..stamp..'.txt')
    end --if not Util.full_path_to_log_file
    local log_file_path = Util.full_path_to_log_file
    local f, err = io.open(log_file_path, "a") --append mode
    if f
      then
        local time_stamp = Util.date_time_stamp_with_time_precise()
        f:write('['..time_stamp..']: '..message..'\n')
        f:close()
      else
        --failed to open log file for appending
        r.ShowMessageBox(
          'Failed to open log file for appending! Path: '..
          log_file_path..
          '; Err: '..
          tostring(err)..
          ' Logging will be turned off!',
          'Error',
          0
        )
        --disable further logging attempts
        Util.msg_to_log_file = false
        Util.log_level_override = nil
    end --if f
  end --if should_log

  if should_console then
    --print to console or show message box
    if box == 'box'
      then
        --show message box instead of printing to console
        r.ShowMessageBox(message, 'Error', 0)
        --integer reaper.ShowMessageBox(string msg, string title, integer type)
        --type 0=OK,1=OKCANCEL,2=ABORTRETRYIGNORE,3=YESNOCANCEL,4=YESNO,5=RETRYCANCEL :
        --ret 1=OK,2=CANCEL,3=ABORT,4=RETRY,5=IGNORE,6=YES,7=NO
      else
        --print to console
        if message == '' then message = ' ' end
        --because '' will clear console (see below citation from docs)
        r.ShowConsoleMsg(message..new_line_or_nothing)
        --[[
          reaper.ShowConsoleMsg(string msg)
          Show a message to the user (also useful for debugging).
          Send "\n" for newline, "" to clear the console.
          Prefix string with "!SHOW:" and text will be added to console without opening the window.
          See ClearConsole
        ]]--
    end --if box == 'box'
  end --if should_console
end --function Util.msg(message, message_importance, box, no_new_line)

function Util.sanitize_filename(s, fallback, max_len)
  fallback = fallback or "no_name"

  if s == nil then return fallback end
  if type(s) ~= "string" then s = tostring(s) end

  -- trim whitespace
  s = s:match("^%s*(.-)%s*$") or ""
  if s == "" then return fallback end

  -- replace unsafe characters with underscore
  -- (%w is locale-dependent-ish; in many Lua builds it's basically ASCII letters/digits/_)
  s = s:gsub("[^%w%-%._]", "_")

  -- collapse multiple underscores
  s = s:gsub("_+", "_")

  -- avoid "." or ".."
  if s == "." or s == ".." then return fallback end

  -- Windows: no trailing dots/spaces
  s = s:gsub("[%.%s]+$", "")
  if s == "" then return fallback end

  -- Windows reserved device names (even with extensions)
  do
    local upper = s:upper()
    local base = upper:match("^(.-)%.") or upper  -- part before first dot
    local reserved = {
      ["CON"]=true, ["PRN"]=true, ["AUX"]=true, ["NUL"]=true,
      ["COM1"]=true, ["COM2"]=true, ["COM3"]=true, ["COM4"]=true, ["COM5"]=true,
      ["COM6"]=true, ["COM7"]=true, ["COM8"]=true, ["COM9"]=true,
      ["LPT1"]=true, ["LPT2"]=true, ["LPT3"]=true, ["LPT4"]=true, ["LPT5"]=true,
      ["LPT6"]=true, ["LPT7"]=true, ["LPT8"]=true, ["LPT9"]=true
    }
    if reserved[base] then
      s = "_" .. s
    end
  end

  -- optional max length (common safe default: 255)
  if max_len then
    if #s > max_len then
      s = s:sub(1, max_len)
      -- re-apply trailing dot/space rule after truncation
      s = s:gsub("[%.%s]+$", "")
      if s == "" then return fallback end
    end
  end

  return s
end --function Util.sanitize_filename(s, fallback, max_len)

function Util.has_non_ascii(s)
  local text = tostring(s or "")
  for i = 1, #text do
    if string.byte(text, i) > 127 then return true end
  end
  return false
end

function Util.has_quoting_risk(s)
  local text = tostring(s or "")
  return (text:find('"', 1, true) ~= nil) or (text:find("\r") ~= nil) or (text:find("\n") ~= nil)
end

function Util.head32(s)
  local text = tostring(s or "")
  if #text > 32 then
    local cut = text:sub(1, 32)
    cut = cut .. "..."
    return cut
  end
  return text
end

function Util.clip_body_text(body, max_len)
  local s = tostring(body or "")
  local limit = tonumber(max_len) or 1024
  if #s <= limit then return s end
  local remaining = #s - limit
  return s:sub(1, limit) .. "\n... (" .. tostring(remaining) .. " more bytes)"
end

function Util.stringify_json_value(val)
  if val == nil then return nil end
  local t = type(val)
  if t == "string" then return val end
  if t == "number" or t == "boolean" then return tostring(val) end
  if t == "table" then
    local js = get_json_module()
    if js and type(js.encode) == "function" then
      local ok, encoded = pcall(js.encode, val)
      if ok then return encoded end
    end
  end
  return tostring(val)
end

function Util.clip_text(s, max_len)
  local text = tostring(s or "")
  local limit = tonumber(max_len) or 1024
  if #text <= limit then return text end
  local remaining = #text - limit
  return text:sub(1, limit) .. "\n... (" .. tostring(remaining) .. " more bytes)"
end



return Util

