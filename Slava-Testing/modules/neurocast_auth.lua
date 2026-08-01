-- @noindex
-- Neurocast auth helper module built on top of Curl transport.
-- Endpoints in scope:
--   POST /api/auth/login
--   POST /api/auth/refresh
--   POST /api/auth/logout
--   POST /api/auth/logout-all-devices
--   GET  /api/users/{id}
--
-- Public entry point:
--   NeurocastAuth.create_client(opts)
--
-- Required opts:
--   opts.base_url (string) - API host, currently: https://studio.neurocast.tech
--
-- Optional opts:
--   opts.curl_submit_fn(req, on_done, submit_opts) - defaults to modules.Curl.curl_submit
--   opts.ext_section - extstate section, default "lamms"
--   opts.ext_refresh_key - extstate key for refresh token, default "art1"
--   opts.remember_refresh - persist refresh on success (default true)

local NeurocastAuth = {}

-- Refresh access tokens after 75% of their JWT lifetime has elapsed. This is
-- intentionally derived from iat/exp instead of assuming a fixed backend TTL.
NeurocastAuth.DEFAULT_PROACTIVE_REFRESH_FRACTION = 0.75

function NeurocastAuth.is_invalid_refresh_http_status(http_code)
  local code = tonumber(http_code)
  return code == 401 or code == 403 or code == 404
end

local ok_json, json = pcall(require, "modules.json")
if not ok_json or type(json) ~= "table" or type(json.decode) ~= "function" then
  error("neurocast_auth: JSON module not available (required 'modules.json'): " .. tostring(json))
end

local ok_base64, base64_codec = pcall(require, "modules.base64_encode_decode")
if not ok_base64 or type(base64_codec) ~= "table" or type(base64_codec.decode_url) ~= "function" then
  error("neurocast_auth: base64 module not available (required 'modules.base64_encode_decode'): " .. tostring(base64_codec))
end

local ok_curl, Curl = pcall(require, "modules.Curl")
if not ok_curl or type(Curl) ~= "table" or type(Curl.curl_submit) ~= "function" then
  error("neurocast_auth: Curl module not available (required 'modules.Curl'): " .. tostring(Curl))
end

local ok_util, Util = pcall(require, "modules.Util")
if not ok_util or type(Util) ~= "table" then
  error("neurocast_auth: Util module not available (required 'modules.Util'): " .. tostring(Util))
end

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function looks_like_email(s)
  local text = trim(s)
  if text == "" then return false end
  return text:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") ~= nil
end

local function join_url(base_url, path)
  local b = trim(base_url)
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

local function shallow_copy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = v
  end
  return out
end

local function decode_json_object(body_txt)
  if type(body_txt) ~= "string" or body_txt == "" then
    return nil, "empty body"
  end
  local ok, decoded = pcall(json.decode, body_txt)
  if not ok then
    return nil, "JSON decode failed: " .. tostring(decoded)
  end
  if type(decoded) ~= "table" then
    return nil, "decoded JSON is not an object"
  end
  return decoded
end

local function parse_api_error_from_obj(decoded)
  if type(decoded) ~= "table" then return nil end

  local status_code = decoded.statusCode or decoded.status or decoded.code
  local primary_err = decoded.error or decoded.title
  local message_txt = decoded.message or decoded.detail
  local pieces = {}

  if status_code ~= nil then table.insert(pieces, tostring(status_code)) end
  if primary_err ~= nil and tostring(primary_err) ~= "" then table.insert(pieces, tostring(primary_err)) end
  if message_txt ~= nil and tostring(message_txt) ~= "" then table.insert(pieces, tostring(message_txt)) end

  local api_error = nil
  if #pieces > 0 then
    api_error = table.concat(pieces, " - ")
  end

  local extras = {}
  if decoded.path ~= nil and tostring(decoded.path) ~= "" then
    table.insert(extras, "path: " .. tostring(decoded.path))
  end
  if decoded.correlationId ~= nil and tostring(decoded.correlationId) ~= "" then
    table.insert(extras, "correlationId: " .. tostring(decoded.correlationId))
  end
  if #extras > 0 then
    local extras_txt = table.concat(extras, ", ")
    if api_error and api_error ~= "" then
      api_error = api_error .. " (" .. extras_txt .. ")"
    else
      api_error = extras_txt
    end
  end

  if api_error == "" then return nil end
  return api_error
end

local function parse_api_error_from_body(body_txt)
  local decoded = decode_json_object(body_txt)
  if not decoded then return nil end
  return parse_api_error_from_obj(decoded)
end

local function make_failure_payload(endpoint, error_txt, http_code, api_error)
  return {
    ok = false,
    endpoint = tostring(endpoint or ""),
    http_code = http_code,
    error = tostring(error_txt or "request failed"),
    api_error = api_error
  }
end

local function safe_callback(on_done, payload)
  if type(on_done) ~= "function" then return end
  pcall(on_done, payload)
end

-- Coordinates one shared access-token refresh for any number of requests that
-- discover the same expired token at roughly the same time. Each waiter is
-- resumed only after the shared refresh completes.
function NeurocastAuth.create_refresh_gate()
  local in_flight = false
  local waiters = {}
  local gate = {}

  local function finish(ok, payload)
    if not in_flight then return false end
    local pending = waiters
    waiters = {}
    in_flight = false
    for _, waiter in ipairs(pending) do
      if ok == true then
        safe_callback(waiter.on_success, payload)
      else
        safe_callback(waiter.on_failure, payload)
      end
    end
    return true
  end

  function gate.request(start_refresh, on_success, on_failure)
    if type(start_refresh) ~= "function" then
      return nil, "start_refresh callback is required"
    end
    waiters[#waiters + 1] = {
      on_success = on_success,
      on_failure = on_failure
    }
    if in_flight then
      return true, "queued"
    end

    in_flight = true
    local ok_call, started, start_err = pcall(start_refresh, function(ok, payload)
      finish(ok == true, payload)
    end)
    if not ok_call then
      local err_txt = tostring(started or "refresh callback failed")
      finish(false, { ok = false, error = err_txt })
      return true, "completed"
    end
    if started == false or started == nil then
      local err_txt = tostring(start_err or "refresh request could not be started")
      if in_flight then
        finish(false, { ok = false, error = err_txt })
      end
      return true, "completed"
    end
    return true, "started"
  end

  function gate.is_in_flight()
    return in_flight
  end

  function gate.waiter_count()
    return #waiters
  end

  return gate
end

local function make_json_headers()
  return {
    accept = "application/json",
    ["Content-Type"] = "application/json"
  }
end

local function with_bearer(headers, access_token)
  local out = shallow_copy(headers)
  out.Authorization = "Bearer " .. tostring(access_token or "")
  return out
end

local function validate_nonempty_string(value, field_name, trim_value)
  if type(value) ~= "string" then
    return nil, field_name .. " must be a string"
  end
  local text = trim_value and trim(value) or value
  if text == "" then
    return nil, field_name .. " must be a non-empty string"
  end
  return text
end

local function url_encode_path_segment(text)
  return (tostring(text or ""):gsub("[^%w%-._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function decode_jwt_payload_claims(access_token)
  local token = trim(access_token)
  if token == "" then
    return nil, "access_token must be a non-empty string"
  end

  local _, payload_segment = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
  if type(payload_segment) ~= "string" or payload_segment == "" then
    return nil, "access_token is not a valid JWT"
  end

  local payload_json, decode_err = base64_codec.decode_url(payload_segment)
  if type(payload_json) ~= "string" then
    return nil, "JWT payload decode failed: " .. tostring(decode_err or "unknown error")
  end

  local claims, claims_err = decode_json_object(payload_json)
  if not claims then
    return nil, "JWT payload JSON parse failed: " .. tostring(claims_err or "unknown error")
  end

  return claims
end

local function pick_user_id_from_claims(claims)
  if type(claims) ~= "table" then
    return nil, "claims must be a table", nil
  end

  local keys = { "sub", "id", "userId", "uid" }
  for i = 1, #keys do
    local key = keys[i]
    local value = claims[key]
    if value ~= nil then
      local as_string = nil
      if type(value) == "string" then
        as_string = trim(value)
      elseif type(value) == "number" then
        as_string = tostring(value)
      end
      if type(as_string) == "string" and as_string ~= "" then
        return as_string, nil, key
      end
    end
  end

  return nil, "JWT payload has no supported user id claim (sub/id/userId/uid)", nil
end

function NeurocastAuth.create_client(opts)
  assert(type(opts) == "table", "NeurocastAuth.create_client(opts): opts table is required")

  local base_url = validate_nonempty_string(opts.base_url, "opts.base_url", true)
  assert(base_url, "NeurocastAuth.create_client(opts): opts.base_url must be a non-empty string")

  local ext_section = tostring(opts.ext_section or "lamms")
  local ext_refresh_key = tostring(opts.ext_refresh_key or "art1")
  local remember_refresh = (opts.remember_refresh ~= false)

  local curl_submit_fn = type(opts.curl_submit_fn) == "function" and opts.curl_submit_fn or Curl.curl_submit

  local state = {
    access_token = "",
    refresh_token = ""
  }

  local client = {}

  local function parse_submit_error(result, endpoint)
    local http_code = result and result.http_code or nil
    local err_txt = (result and result.err) or "request failed"
    local api_error = parse_api_error_from_body(result and result.body or nil)
    return make_failure_payload(endpoint, err_txt, http_code, api_error)
  end

  local function apply_token_persistence(refresh_token)
    if remember_refresh then
      client.persist_refresh_token(refresh_token)
    else
      client.forget_refresh_token()
    end
  end

  local function submit_wrapped(endpoint, req, parse_success_fn, on_success, on_done, submit_opts)
    if type(curl_submit_fn) ~= "function" then
      local err_txt = "curl submit function is not available"
      local payload = make_failure_payload(endpoint, err_txt, nil, nil)
      safe_callback(on_done, payload)
      return nil, err_txt
    end

    local merged_opts = shallow_copy(submit_opts or {})
    merged_opts.read_body = true

    local job, submit_err = curl_submit_fn(req, function(result, _job)
      if not result or result.ok ~= true then
        safe_callback(on_done, parse_submit_error(result, endpoint))
        return
      end

      local parsed, parse_err, api_error = parse_success_fn(result.body)
      if not parsed then
        local payload = make_failure_payload(endpoint, parse_err or "response parse failed", result.http_code, api_error)
        safe_callback(on_done, payload)
        return
      end

      local payload = on_success(parsed, result.http_code)
      safe_callback(on_done, payload)
    end, merged_opts)

    if not job then
      local payload = make_failure_payload(endpoint, submit_err or "submit failed", nil, nil)
      safe_callback(on_done, payload)
      return nil, submit_err
    end
    return job
  end

  function client.get_tokens()
    return {
      access_token = state.access_token,
      refresh_token = state.refresh_token
    }
  end

  function client.set_tokens(access_token, refresh_token)
    state.access_token = tostring(access_token or "")
    state.refresh_token = tostring(refresh_token or "")
    return true
  end

  function client.clear_runtime_tokens()
    state.access_token = ""
    state.refresh_token = ""
    return true
  end

  function client.persist_refresh_token(token)
    local refresh = validate_nonempty_string(token, "refresh_token", true)
    if not refresh then
      return nil, "refresh_token must be a non-empty string"
    end

    if type(Util.extstate_set_camo) ~= "function" then
      return nil, "Util.extstate_set_camo is not available"
    end

    local ok_set, set_err = Util.extstate_set_camo(ext_section, ext_refresh_key, refresh, true)
    if not ok_set then
      return nil, set_err or "cannot persist refresh token"
    end
    return true
  end

  function client.load_refresh_token()
    if type(Util.extstate_get_camo) ~= "function" then
      return nil, "Util.extstate_get_camo is not available"
    end

    local token, get_err = Util.extstate_get_camo(ext_section, ext_refresh_key)
    if get_err then
      return nil, get_err
    end
    if token == nil then
      return nil
    end

    token = tostring(token or "")
    if token == "" then
      client.forget_refresh_token()
      return nil
    end

    state.refresh_token = token
    return token
  end

  function client.forget_refresh_token()
    if type(Util.extstate_delete) ~= "function" then
      return nil, "Util.extstate_delete is not available"
    end

    local ok_del, del_err = Util.extstate_delete(ext_section, ext_refresh_key, true)
    if not ok_del then
      return nil, del_err or "cannot delete refresh token"
    end
    return true
  end

  function client.build_login_request(email, password)
    local email_txt, email_err = validate_nonempty_string(email, "email", true)
    if not email_txt then return nil, email_err end
    if not looks_like_email(email_txt) then
      return nil, "email format looks invalid"
    end

    local password_txt, password_err = validate_nonempty_string(password, "password", false)
    if not password_txt then return nil, password_err end

    return {
      label = "auth_login",
      kind = "neurocast_auth",
      method = "POST",
      url = join_url(base_url, "/api/auth/login"),
      headers = make_json_headers(),
      json_payload_tbl = {
        email = email_txt,
        password = password_txt
      }
    }
  end

  function client.build_refresh_request(refresh_token)
    local refresh, refresh_err = validate_nonempty_string(refresh_token, "refresh_token", true)
    if not refresh then return nil, refresh_err end

    return {
      label = "auth_refresh",
      kind = "neurocast_auth",
      method = "POST",
      url = join_url(base_url, "/api/auth/refresh"),
      headers = make_json_headers(),
      json_payload_tbl = {
        refresh_token = refresh
      }
    }
  end

  function client.build_logout_request(access_token, refresh_token)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local refresh, refresh_err = validate_nonempty_string(refresh_token, "refresh_token", true)
    if not refresh then return nil, refresh_err end

    return {
      label = "auth_logout",
      kind = "neurocast_auth",
      method = "POST",
      url = join_url(base_url, "/api/auth/logout"),
      headers = with_bearer(make_json_headers(), access),
      json_payload_tbl = {
        refresh_token = refresh
      }
    }
  end

  function client.build_logout_all_devices_request(access_token)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end

    return {
      label = "auth_logout_all_devices",
      kind = "neurocast_auth",
      method = "POST",
      url = join_url(base_url, "/api/auth/logout-all-devices"),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.build_get_user_by_id_request(access_token, user_id)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    local resolved_user_id, user_id_err = validate_nonempty_string(user_id, "user_id", true)
    if not resolved_user_id then return nil, user_id_err end

    return {
      label = "users_show",
      kind = "neurocast_auth",
      method = "GET",
      url = join_url(base_url, "/api/users/" .. url_encode_path_segment(resolved_user_id)),
      headers = with_bearer(make_json_headers(), access)
    }
  end

  function client.decode_access_token_claims(access_token)
    local access, access_err = validate_nonempty_string(access_token, "access_token", true)
    if not access then return nil, access_err end
    return decode_jwt_payload_claims(access)
  end

  function client.access_token_refresh_status(access_token, opts_tbl)
    local access = access_token
    if access == nil then access = state.access_token end
    local claims, claims_err = client.decode_access_token_claims(access)
    if not claims then return nil, claims_err end

    local issued_at = tonumber(claims.iat)
    local expires_at = tonumber(claims.exp)
    if not issued_at or not expires_at or expires_at <= issued_at then
      return nil, "access token JWT must contain valid iat/exp claims"
    end

    local options = type(opts_tbl) == "table" and opts_tbl or {}
    local fraction = tonumber(options.refresh_fraction) or
      NeurocastAuth.DEFAULT_PROACTIVE_REFRESH_FRACTION
    if fraction <= 0 or fraction >= 1 then
      return nil, "refresh_fraction must be greater than 0 and less than 1"
    end

    local now_epoch = tonumber(options.now_epoch) or os.time()
    local lifetime = expires_at - issued_at
    local refresh_at = issued_at + (lifetime * fraction)
    return {
      issued_at = issued_at,
      expires_at = expires_at,
      lifetime_seconds = lifetime,
      refresh_fraction = fraction,
      refresh_at = refresh_at,
      elapsed_seconds = now_epoch - issued_at,
      remaining_seconds = expires_at - now_epoch,
      refresh_due = now_epoch >= refresh_at,
      expired = now_epoch >= expires_at
    }
  end

  function client.extract_user_id_from_access_token(access_token)
    local claims, claims_err = client.decode_access_token_claims(access_token)
    if not claims then
      return nil, claims_err, nil, nil
    end

    local user_id, user_id_err, claim_name = pick_user_id_from_claims(claims)
    if not user_id then
      return nil, user_id_err, claims, nil
    end

    return user_id, nil, claims, claim_name
  end

  function client.parse_token_body(body_txt)
    local decoded, decode_err = decode_json_object(body_txt)
    if not decoded then
      return nil, decode_err, nil
    end

    local access_token = tostring(decoded.access_token or "")
    local refresh_token = tostring(decoded.refresh_token or "")
    if access_token == "" or refresh_token == "" then
      local api_error = parse_api_error_from_obj(decoded)
      return nil, "response missing access_token/refresh_token", api_error
    end

    return {
      access_token = access_token,
      refresh_token = refresh_token
    }
  end

  function client.parse_user_body(body_txt)
    local decoded, decode_err = decode_json_object(body_txt)
    if not decoded then
      return nil, decode_err, nil
    end
    return decoded
  end

  function client.parse_logout_body(body_txt)
    if body_txt == nil or body_txt == "" then
      return { message = "" }
    end

    local decoded, decode_err = decode_json_object(body_txt)
    if not decoded then
      return nil, decode_err, nil
    end

    local message = decoded.message or decoded.detail or decoded.statusMessage or ""
    return {
      message = tostring(message or "")
    }
  end

  function client.submit_login(email, password, on_done, submit_opts)
    local req, req_err = client.build_login_request(email, password)
    if not req then
      local payload = make_failure_payload("login", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "login",
      req,
      client.parse_token_body,
      function(parsed, http_code)
        client.set_tokens(parsed.access_token, parsed.refresh_token)
        apply_token_persistence(parsed.refresh_token)
        return {
          ok = true,
          endpoint = "login",
          http_code = http_code,
          access_token = parsed.access_token,
          refresh_token = parsed.refresh_token
        }
      end,
      on_done,
      submit_opts
    )
  end

  function client.submit_refresh(on_done, submit_opts)
    local refresh_token = state.refresh_token
    if refresh_token == "" then
      local loaded = client.load_refresh_token()
      if type(loaded) == "string" and loaded ~= "" then
        refresh_token = loaded
      end
    end

    local req, req_err = client.build_refresh_request(refresh_token)
    if not req then
      local payload = make_failure_payload("refresh", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "refresh",
      req,
      client.parse_token_body,
      function(parsed, http_code)
        client.set_tokens(parsed.access_token, parsed.refresh_token)
        apply_token_persistence(parsed.refresh_token)
        return {
          ok = true,
          endpoint = "refresh",
          http_code = http_code,
          access_token = parsed.access_token,
          refresh_token = parsed.refresh_token
        }
      end,
      on_done,
      submit_opts
    )
  end

  function client.submit_logout(on_done, submit_opts)
    local access_token = state.access_token
    local refresh_token = state.refresh_token
    if refresh_token == "" then
      local loaded = client.load_refresh_token()
      if type(loaded) == "string" and loaded ~= "" then
        refresh_token = loaded
      end
    end

    local req, req_err = client.build_logout_request(access_token, refresh_token)
    if not req then
      local payload = make_failure_payload("logout", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "logout",
      req,
      client.parse_logout_body,
      function(parsed, http_code)
        client.clear_runtime_tokens()
        client.forget_refresh_token()
        return {
          ok = true,
          endpoint = "logout",
          http_code = http_code,
          message = parsed.message
        }
      end,
      on_done,
      submit_opts
    )
  end

  function client.submit_logout_all_devices(on_done, submit_opts)
    local access_token = state.access_token
    local req, req_err = client.build_logout_all_devices_request(access_token)
    if not req then
      local payload = make_failure_payload("logout_all_devices", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "logout_all_devices",
      req,
      client.parse_logout_body,
      function(parsed, http_code)
        client.clear_runtime_tokens()
        client.forget_refresh_token()
        return {
          ok = true,
          endpoint = "logout_all_devices",
          http_code = http_code,
          message = parsed.message
        }
      end,
      on_done,
      submit_opts
    )
  end

  function client.submit_get_user_by_id(user_id, on_done, submit_opts)
    local access_token = state.access_token
    local resolved_user_id, user_id_err = validate_nonempty_string(user_id, "user_id", true)
    if not resolved_user_id then
      local payload = make_failure_payload("get_user_by_id", user_id_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, user_id_err
    end

    local req, req_err = client.build_get_user_by_id_request(access_token, resolved_user_id)
    if not req then
      local payload = make_failure_payload("get_user_by_id", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "get_user_by_id",
      req,
      client.parse_user_body,
      function(parsed, http_code)
        return {
          ok = true,
          endpoint = "get_user_by_id",
          http_code = http_code,
          user_id = resolved_user_id,
          user = parsed
        }
      end,
      on_done,
      submit_opts
    )
  end

  function client.submit_get_current_user(on_done, submit_opts)
    local access_token = state.access_token
    local user_id, user_id_err, claims, claim_name = client.extract_user_id_from_access_token(access_token)
    if not user_id then
      local payload = make_failure_payload("get_current_user", user_id_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, user_id_err
    end

    local req, req_err = client.build_get_user_by_id_request(access_token, user_id)
    if not req then
      local payload = make_failure_payload("get_current_user", req_err, nil, nil)
      safe_callback(on_done, payload)
      return nil, req_err
    end

    return submit_wrapped(
      "get_current_user",
      req,
      client.parse_user_body,
      function(parsed, http_code)
        return {
          ok = true,
          endpoint = "get_current_user",
          http_code = http_code,
          user_id = user_id,
          user_id_claim = claim_name,
          claims = claims,
          user = parsed
        }
      end,
      on_done,
      submit_opts
    )
  end

  return client
end

return NeurocastAuth

