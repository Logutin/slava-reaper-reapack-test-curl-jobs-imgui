-- @description Test Neurocast Auth (ReaImGui)
-- @version 1.0.0
-- @author Slava Logutin
-- @about Interactive ReaImGui test interface for Neurocast authentication endpoints (Login, Refresh token, Get User/Token).
-- @provides
--   [main] .
--   modules/neurocast_auth.lua > modules/neurocast_auth.lua
--   modules/Curl.lua > modules/Curl.lua
--   modules/Files.lua > modules/Files.lua
--   modules/Util.lua > modules/Util.lua
--   modules/json.lua > modules/json.lua
--   modules/base64_encode_decode.lua > modules/base64_encode_decode.lua

--========================================================
-- test_neurocast_auth.lua
-- Minimal auth tester built on top of run_curl_minimal_no_disk()
--========================================================

-- GLOBALS ------------------------------------------------
local messaging_level = 0
local window_title = 'Auth test 01'
local mac = package.config:sub(1,1) == '/'
local separator = mac and '/' or [[\]]
local function is_windows() return not mac end

-- DEPENDENCIES -------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.MB("Missing dependency: ReaImGui extension.\nDownload it via Reapack ReaTeam extension repository.", "Error", 0)
  return false
end

-- Module path resolution
local script_path = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local old_package_path = package.path
package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. script_path .. "modules/?.lua;" .. old_package_path

local ok_json, json_mod = pcall(require, "modules.json")
if not ok_json then
  ok_json, json_mod = pcall(require, "json")
end
local json = json_mod

-- UI SETUP -----------------------------------------------
local ctx = reaper.ImGui_CreateContext(window_title)
local FONT_SIZE = 18
local FONT = reaper.ImGui_CreateFont('monospace')
reaper.ImGui_Attach(ctx, FONT)
local SMALL_FONT_SIZE = 14
local SMALL_FONT = reaper.ImGui_CreateFont('monospace')
reaper.ImGui_Attach(ctx, SMALL_FONT)

-- UTILITIES ----------------------------------------------
local function msg(message, message_importance, box, no_new_line)
  if message_importance then else message_importance = 0 end
  if message_importance < messaging_level then return end
  if type(message) ~= "string" then message = tostring(message) end
  local new_line_or_nothing = no_new_line and '' or '\n'
  if box == 'box' then
    reaper.ShowMessageBox(message, 'Error', 0)
  else
    if message == '' then message = ' ' end
    reaper.ShowConsoleMsg(message..new_line_or_nothing)
  end
end

local function join_cmd(argv)
  return table.concat(argv, " ")
end

local function shell_quote(arg)
  if is_windows() then
    local s = tostring(arg)
    s = s:gsub([["]], [[\"]])
    local trail_bs = 0
    for i = #s, 1, -1 do
      if s:sub(i,i) == [[\]] then trail_bs = trail_bs + 1 else break end
    end
    if trail_bs > 0 then
      s = s .. string.rep([[\]], trail_bs)
    end
    return [["]] .. s .. [["]]
  else
    local s = tostring(arg)
    if s == "" then return "''" end
    return "'" .. s:gsub("'", [['"'"']]) .. "'"
  end
end

local CFG = {
  curl = mac and "/usr/bin/curl" or "curl",
  timeout_sec = 60,
  use_fail_with_body = true
}

local function run_curl_minimal_no_disk(req)
  assert(req and req.url, "run_curl_minimal_no_disk: req.url required")
  
  if req.form_fields then
    return nil, "run_curl_minimal_no_disk: form_fields not supported (no disk)", ""
  end
  if req.download_path then
    return nil, "run_curl_minimal_no_disk: download_path not supported (no disk)", ""
  end
  
  local data_arg = nil
  if req.method == "POST" and req.json_payload_tbl then
    local ok, payload = pcall(json.encode, req.json_payload_tbl)
    if not ok then
      return nil, "JSON encode failed: " .. tostring(payload), ""
    end
    data_arg = [[--data-binary ]] .. shell_quote(payload)
  elseif req.body_string then
    data_arg = [[--data-binary ]] .. shell_quote(req.body_string)
  end
  
  local hdr_argv = {}
  if req.headers then
    for k, v in pairs(req.headers) do
      hdr_argv[#hdr_argv + 1] = [[-H ]] .. shell_quote(k .. ": " .. v)
    end
  end
  
  local argv = {}
  argv[#argv + 1] = shell_quote(CFG.curl)
  argv[#argv + 1] = "-s"
  argv[#argv + 1] = "-i"
  if CFG.use_fail_with_body then
    argv[#argv + 1] = "--fail-with-body"
  end
  if req.follow_redirects then
    argv[#argv + 1] = "-L"
  end
  if data_arg then
    argv[#argv + 1] = data_arg
  end
  if #hdr_argv > 0 then
    argv[#argv + 1] = table.concat(hdr_argv, " ")
  end
  argv[#argv + 1] = shell_quote(req.url)
  
  local cmd = join_cmd(argv)
  local timeout = req.timeout_sec or CFG.timeout_sec
  
  local masked_cmd = cmd
  if req.headers then
    local tok = req.headers["Authorization"] or req.headers["authorization"]
    if tok and tok ~= "" then
      masked_cmd = masked_cmd:gsub(
        "(Authorization:%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+)[^\"'%s]+",
        "%1***"
      )
    end
  end
  
  local exec_output = reaper.ExecProcess(cmd, (timeout * 1000))
  if exec_output then
    msg('RAW curl output: '..tostring(exec_output), 0)
  end
  
  if not exec_output then
    return nil, "ExecProcess returned nil (command likely failed to start)", masked_cmd
  end
  local ret_line, out = exec_output:match("^([^\r\n]*)\r?\n(.*)$")
  if not ret_line then
    ret_line = exec_output
    out = ""
  end
  local err_txt = nil
  local code_num = tonumber(ret_line)
  if code_num and code_num ~= 0 then
    err_txt = ("ExecProcess exit code %d"):format(code_num)
  elseif not code_num then
    err_txt = "ExecProcess returned a non-numeric code:"..ret_line
  end
  return out, err_txt, masked_cmd
end

-- AUTH HELPERS -------------------------------------------
local AUTH = {
  login_url = "https://neurohub.click/api/auth/login",
  refresh_url = "https://neurohub.click/api/auth/refresh",
  auphonic_token_url = "https://neurohub.click/api/auphonic/token"
}

local S = {
  email = "",
  password = "",
  status = "",
  last_cmd = "",
  last_output = "",
  last_err = "",
  access_token = "",
  refresh_token = "",
  auphonic_token = ""
}

local function log_result(tag, output_txt, err_txt, masked_cmd)
  msg('==== '..tag..' ====')
  msg('CMD: '..tostring(masked_cmd or 'masking failed, so command will not be shown!'))
  if err_txt then msg('err: '..tostring(err_txt), 2) end
  if output_txt and output_txt ~= '' then
    msg('response: '..tostring(output_txt))
  else
    msg('response: <empty>')
  end
end

local function decode_tokens_from_output(output_txt)
  local access, refresh = "", ""
  if output_txt and output_txt ~= "" then
    local ok, decoded = pcall(json.decode, output_txt)
    if ok and type(decoded) == "table" then
      access = decoded.access_token or ""
      refresh = decoded.refresh_token or ""
    else
      msg('JSON decode failed: '..tostring(decoded), 2)
    end
  end
  return access, refresh
end

local function decode_auphonic_token_from_output(output_txt)
  if output_txt and output_txt ~= "" then
    local ok, decoded = pcall(json.decode, output_txt)
    if ok and type(decoded) == "table" then
      return decoded.auphonic_token or decoded.token or decoded.access_token or ""
    else
      msg('JSON decode failed (auphonic token): '..tostring(decoded), 2)
    end
  end
  return ""
end

local function call_login()
  if (not S.email) or S.email == "" then
    S.status = "Email is empty."
    msg(S.status, 2)
    return
  end
  if (not S.password) or S.password == "" then
    S.status = "Password is empty."
    msg(S.status, 2)
    return
  end
  
  local req = {
    method = "POST",
    url = AUTH.login_url,
    headers = {
      ["accept"] = "application/json",
      ["Content-Type"] = "application/json"
    },
    json_payload_tbl = {
      email = S.email,
      password = S.password
    },
    timeout_sec = CFG.timeout_sec,
    kind = "post"
  }
  local output_txt, err_txt, masked_cmd = run_curl_minimal_no_disk(req)
  S.last_cmd = masked_cmd or "masking failed, so command will not be shown!"
  S.last_output = output_txt or "no output from run_curl_minimal_no_disk!"
  S.last_err = err_txt
  S.access_token, S.refresh_token = decode_tokens_from_output(output_txt)
  if S.access_token ~= "" then
    S.status = "Login OK (tokens parsed)."
  elseif err_txt then
    S.status = err_txt
  else
    S.status = "Login done BUT! !! ==no tokens parsed==)."
  end
  log_result('LOGIN', output_txt, err_txt, masked_cmd)
end

local function call_refresh()
  if (not S.refresh_token) or S.refresh_token == "" then
    S.status = "No refresh_token stored. Run login first."
    msg(S.status, 2)
    return
  end
  local req = {
    method = "POST",
    url = AUTH.refresh_url,
    headers = {
      ["accept"] = "application/json",
      ["Content-Type"] = "application/json"
    },
    json_payload_tbl = {
      refresh_token = S.refresh_token
    },
    timeout_sec = CFG.timeout_sec,
    kind = "post"
  }
  local output_txt, err_txt, masked_cmd = run_curl_minimal_no_disk(req)
  S.last_cmd = masked_cmd or ""
  S.last_output = output_txt or ""
  S.last_err = err_txt
  S.access_token, S.refresh_token = decode_tokens_from_output(output_txt)
  if err_txt then
    S.status = err_txt
  else
    S.status = "Refresh call finished."
    if S.access_token ~= "" then
      S.status = S.status .. " New access_token parsed."
    end
  end
  log_result('REFRESH', output_txt, err_txt, masked_cmd)
end

local function call_auphonic_token()
  if (not S.access_token) or S.access_token == "" then
    S.status = "No access_token stored. Run login first."
    msg(S.status, 2)
    return
  end
  local req = {
    method = "GET",
    url = AUTH.auphonic_token_url,
    headers = {
      ["accept"] = "application/json",
      ["Authorization"] = "Bearer "..S.access_token
    },
    timeout_sec = CFG.timeout_sec,
    kind = "get"
  }
  local output_txt, err_txt, masked_cmd = run_curl_minimal_no_disk(req)
  S.last_cmd = masked_cmd or ""
  S.last_output = output_txt or ""
  S.last_err = err_txt
  S.auphonic_token = decode_auphonic_token_from_output(output_txt)
  if err_txt then
    S.status = err_txt
  else
    S.status = "Auphonic token call finished."
    if S.auphonic_token ~= "" then
      S.status = S.status .. " Auphonic token parsed."
    end
  end
  log_result('AUPHONIC TOKEN', output_txt, err_txt, masked_cmd)
end

-- UI LOOP -------------------------------------------------
local function GuiLoop()
  reaper.ImGui_PushFont(ctx, FONT, FONT_SIZE)
  local visible, open = reaper.ImGui_Begin(ctx, window_title, true)
  if visible then
    reaper.ImGui_Text(ctx, "Check auth on neurohub.click")
    reaper.ImGui_Separator(ctx)
    
    reaper.ImGui_Text(ctx, "Email:")
    reaper.ImGui_SetNextItemWidth(ctx, -10.0)
    local changed_email, new_email = reaper.ImGui_InputText(ctx, "##email", S.email or "")
    if changed_email then
      S.email = new_email
    end
    
    reaper.ImGui_Text(ctx, "Password:")
    reaper.ImGui_SetNextItemWidth(ctx, -10.0)
    local pass_flags = reaper.ImGui_InputTextFlags_Password()
    local changed_pass, new_pass = reaper.ImGui_InputText(ctx, "##password", S.password or "", pass_flags)
    if changed_pass then
      S.password = new_pass
    end
    
    if reaper.ImGui_Button(ctx, "Login") then
      call_login()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Refresh token") then
      call_refresh()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Get Auphonic token") then
      call_auphonic_token()
    end
    
    reaper.ImGui_Text(ctx, "Status: "..(S.status or ""))
    
    reaper.ImGui_PushFont(ctx, SMALL_FONT, SMALL_FONT_SIZE)
    reaper.ImGui_TextWrapped(ctx, "Last cmd: "..(S.last_cmd or ""))
    reaper.ImGui_TextWrapped(ctx, "Last output: "..(S.last_output or ""))
    reaper.ImGui_TextWrapped(ctx, "Last err: "..(S.last_err or ""))
    reaper.ImGui_TextWrapped(ctx, "Access token: "..((S.access_token ~= "" and S.access_token) or "(empty)"))
    reaper.ImGui_TextWrapped(ctx, "Refresh token: "..((S.refresh_token ~= "" and S.refresh_token) or "(empty)"))
    reaper.ImGui_TextWrapped(ctx, "Auphonic token: "..((S.auphonic_token ~= "" and S.auphonic_token) or "(empty)"))
    reaper.ImGui_PopFont(ctx)
    
    reaper.ImGui_End(ctx)
  else
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopFont(ctx)
  
  if open then
    reaper.defer(GuiLoop)
  end
end

reaper.defer(GuiLoop)
