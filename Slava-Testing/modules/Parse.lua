-- @noindex
-- Parser helpers module for ReaScript projects.
-- This module will grow over time as more input formats are supported.
-- Public entry points:
-- Parse.formats
-- Parse.parse_timecode(timecode_string, format_id, opts)
-- Parse.extract_inline_timecode_fragments(base_timecode_text, dialogue_text, format_id, opts)
-- Parse.process_script_cast(script_rows)
--
-- Character-name processing note:
-- Parse.process_script_cast now uses shared modules.Utf8Tools simple Unicode
-- lowercase normalization for grouping keys. UTF-8 names are also handled
-- safely for trimming, codepoint length checks, and edit distance.
--
-- Current boundary:
-- modules.Utf8Tools owns reusable UTF-8 lowercase behavior.
-- Parse continues to own script-specific grouping policy, empty-name handling,
-- sorting, and merge-candidate logic. Full casefolding remains future work.

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local Parse = {}
local Utf8Tools = require("modules.Utf8Tools")

-- MODULE SETTINGS
Parse.maximum_allowed_typo_distance = 2 -- consider 3, 4...
Parse.empty_character_name_config = {
  [1] = "fail_fast",
  [2] = "empty_is_valid_character_name",
  [3] = "copy_from_previous_row_on_empty",
  [4] = "empty_resolves_to_NO_CHARACTER_NAME"
}
Parse.empty_character_name_mode = 3
Parse.formats = {
  {
    id = 1,
    description = "Basic Cyrillica Studio format",
    explanation = "[(h)(h):(m)m:ss], input separators may be:[{;},{:},{,},{.}]"
  },
  {
    id = 2,
    description = "SubRip/WebVTT milliseconds",
    explanation = "HH:MM:SS,mmm, HH:MM:SS.mmm, or MM:SS.mmm fractional-second timecode"
  },
  {
    id = 3,
    description = "SMPTE non-drop frame",
    explanation = "HH:MM:SS:FF frame timecode; Source FPS is required"
  },
  {
    id = 4,
    description = "SMPTE drop frame",
    explanation = "HH:MM:SS;FF drop-frame timecode; legacy HH:MM:SS.FF also parses when selected manually; Source FPS is required"
  }
}

local GENERIC_BAD_INPUT = "Bad input, expected m:ss or h:m:ss using digits and separators ; : , ."
local EMPTY_CHARACTER_NAME_PLACEHOLDER = "NO_CHARACTER_NAME"
local EDGE_UTF8_WHITESPACE = {
  "\194\160", -- U+00A0 NO-BREAK SPACE
  "\225\154\128", -- U+1680 OGHAM SPACE MARK
  "\226\128\128", -- U+2000 EN QUAD
  "\226\128\129", -- U+2001 EM QUAD
  "\226\128\130", -- U+2002 EN SPACE
  "\226\128\131", -- U+2003 EM SPACE
  "\226\128\132", -- U+2004 THREE-PER-EM SPACE
  "\226\128\133", -- U+2005 FOUR-PER-EM SPACE
  "\226\128\134", -- U+2006 SIX-PER-EM SPACE
  "\226\128\135", -- U+2007 FIGURE SPACE
  "\226\128\136", -- U+2008 PUNCTUATION SPACE
  "\226\128\137", -- U+2009 THIN SPACE
  "\226\128\138", -- U+200A HAIR SPACE
  "\226\128\168", -- U+2028 LINE SEPARATOR
  "\226\128\169", -- U+2029 PARAGRAPH SEPARATOR
  "\226\128\175", -- U+202F NARROW NO-BREAK SPACE
  "\226\129\159", -- U+205F MEDIUM MATHEMATICAL SPACE
  "\227\128\128", -- U+3000 IDEOGRAPHIC SPACE
  "\239\187\191" -- U+FEFF ZERO WIDTH NO-BREAK SPACE / BOM
}

local function supported_format_ids_string()
  local ids = {}
  for i = 1, #Parse.formats do
    ids[#ids + 1] = tostring(Parse.formats[i].id)
  end
  return table.concat(ids, ", ")
end

local function unsupported_format_error(format_id)
  return "Unsupported format_id: " .. tostring(format_id) .. ". Supported format ids: " .. supported_format_ids_string()
end

local function timecode_format_exists(format_num)
  for i = 1, #Parse.formats do
    if Parse.formats[i].id == format_num then
      return true
    end
  end
  return false
end

local function validate_supported_timecode_format_id(format_id)
  local format_num = tonumber(format_id)
  if
    format_num == nil or
    math.floor(format_num) ~= format_num or
    not timecode_format_exists(format_num)
  then
    return nil, unsupported_format_error(format_id)
  end
  return format_num, nil
end

local function trim_edge_whitespace(text)
  local trimmed = tostring(text or "")
  local changed = true

  while changed do
    local previous = trimmed
    trimmed = trimmed:match("^%s*(.-)%s*$") or ""

    for i = 1, #EDGE_UTF8_WHITESPACE do
      local token = EDGE_UTF8_WHITESPACE[i]
      while trimmed:sub(1, #token) == token do
        trimmed = trimmed:sub(#token + 1)
      end
      while #trimmed >= #token and trimmed:sub(-#token) == token do
        trimmed = trimmed:sub(1, #trimmed - #token)
      end
    end

    changed = (trimmed ~= previous)
  end

  return trimmed
end

local function normalize_input(text)
  local trimmed = trim_edge_whitespace(text)
  return trimmed:gsub("[;:,.]", ":")
end

local function split_colon_fields(text)
  local fields = {}
  for field in tostring(text or ""):gmatch("([^:]+)") do
    fields[#fields + 1] = field
  end
  return fields
end

local function is_ascii_digit(byte_value)
  return byte_value ~= nil and byte_value >= 48 and byte_value <= 57
end

local function is_ascii_space(byte_value)
  if byte_value == nil then
    return false
  end
  return
    byte_value == 9 or -- \t
    byte_value == 10 or -- \n
    byte_value == 11 or -- \v
    byte_value == 12 or -- \f
    byte_value == 13 or -- \r
    byte_value == 32 -- space
end

local function is_timecode_candidate_char(byte_value)
  return
    is_ascii_digit(byte_value) or
    byte_value == 44 or -- ,
    byte_value == 46 or -- .
    byte_value == 58 or -- :
    byte_value == 59 -- ;
end

local function append_inline_fragment(fragments, timecode_text, dialogue_text, extracted_from_inline)
  fragments[#fragments + 1] = {
    timecode = tostring(timecode_text or ""),
    dialogue = trim_edge_whitespace(dialogue_text),
    extracted_from_inline = extracted_from_inline == true
  }
end

local function find_next_parenthesized_inline(dialogue_text, search_from, format_id, opts)
  local text = tostring(dialogue_text or "")
  local text_length = #text
  local index = math.max(1, tonumber(search_from) or 1)

  while index <= text_length do
    local open_pos = text:find("%(", index)
    if open_pos == nil then
      return nil
    end

    local cursor = open_pos + 1
    while cursor <= text_length and is_ascii_space(text:byte(cursor)) do
      cursor = cursor + 1
    end

    local token_start = cursor
    while cursor <= text_length and is_timecode_candidate_char(text:byte(cursor)) do
      cursor = cursor + 1
    end

    local token_end = cursor - 1
    while cursor <= text_length and is_ascii_space(text:byte(cursor)) do
      cursor = cursor + 1
    end

    if token_start <= token_end and text:sub(cursor, cursor) == ")" then
      local token_text = text:sub(token_start, token_end)
      local normalized = Parse.parse_timecode(token_text, format_id, opts)
      if normalized ~= nil then
        return {
          match_start = open_pos,
          match_end = cursor,
          token_text = token_text,
          wrapper = "parenthesized"
        }
      end
    end

    index = open_pos + 1
  end

  return nil
end

local function find_next_spaced_inline(dialogue_text, search_from, format_id, opts)
  local text = tostring(dialogue_text or "")
  local text_length = #text
  local index = math.max(2, tonumber(search_from) or 2)

  while index <= text_length do
    local previous_byte = text:byte(index - 1)
    local current_byte = text:byte(index)
    if is_ascii_space(previous_byte) and is_ascii_digit(current_byte) then
      local cursor = index
      while cursor <= text_length and is_timecode_candidate_char(text:byte(cursor)) do
        cursor = cursor + 1
      end

      local token_end = cursor - 1
      local trailing_byte = text:byte(cursor)
      if token_end >= index and is_ascii_space(trailing_byte) then
        local token_text = text:sub(index, token_end)
        local normalized = Parse.parse_timecode(token_text, format_id, opts)
        if normalized ~= nil then
          return {
            match_start = index,
            match_end = token_end,
            token_text = token_text,
            wrapper = "spaced"
          }
        end
      end
    end

    index = index + 1
  end

  return nil
end

local function find_next_inline_timecode(dialogue_text, search_from, format_id, opts)
  local spaced = find_next_spaced_inline(dialogue_text, search_from, format_id, opts)
  local parenthesized = find_next_parenthesized_inline(dialogue_text, search_from, format_id, opts)

  if spaced == nil then
    return parenthesized
  end
  if parenthesized == nil then
    return spaced
  end

  if spaced.match_start < parenthesized.match_start then
    return spaced
  end
  return parenthesized
end

local function utf8_codepoints(text)
  local ok, result = pcall(function()
    local out = {}
    for _, codepoint in utf8.codes(text) do
      out[#out + 1] = codepoint
    end
    return out
  end)

  if not ok then
    return nil, tostring(result)
  end

  return result, nil
end

local function utf8_length(text)
  local length, err_pos = utf8.len(text)
  if length == nil then
    return nil, "invalid UTF-8 sequence at byte " .. tostring(err_pos)
  end
  return length, nil
end

-- Fuzzy matching works on UTF-8 codepoints.
-- Lowercase normalization now comes from shared Utf8Tools logic, while the
-- distance calculation remains codepoint-aware and Parse-specific.
local function utf8_levenshtein_distance(a_codes, b_codes, max_distance)
  local len_a = #a_codes
  local len_b = #b_codes

  if max_distance ~= nil and math.abs(len_a - len_b) > max_distance then
    return max_distance + 1
  end

  if len_a == 0 then
    return len_b
  end

  if len_b == 0 then
    return len_a
  end

  if len_a > len_b then
    a_codes, b_codes = b_codes, a_codes
    len_a, len_b = len_b, len_a
  end

  local previous = {}
  for j = 0, len_b do
    previous[j] = j
  end

  for i = 1, len_a do
    local current = { [0] = i }
    local row_min = current[0]

    for j = 1, len_b do
      local cost = (a_codes[i] == b_codes[j]) and 0 or 1
      local insertion = current[j - 1] + 1
      local deletion = previous[j] + 1
      local substitution = previous[j - 1] + cost
      local value = math.min(insertion, deletion, substitution)

      current[j] = value
      if value < row_min then
        row_min = value
      end
    end

    if max_distance ~= nil and row_min > max_distance then
      return max_distance + 1
    end

    previous = current
  end

  return previous[len_b]
end

local function validate_dense_array(value, label)
  if type(value) ~= "table" then
    return nil, label .. " must be a dense array-like table"
  end

  local count = 0
  local max_index = 0

  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      return nil, label .. " must be a dense array-like table"
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  for i = 1, max_index do
    if value[i] == nil then
      return nil, label .. " must be a dense array-like table"
    end
  end

  if count ~= max_index then
    return nil, label .. " must be a dense array-like table"
  end

  return max_index, nil
end

local function add_tally(target, key)
  target[key] = (target[key] or 0) + 1
end

local function add_casing_vote(group, casing_name, row_index)
  if group.casing_vote_counts[casing_name] == nil then
    group.casing_vote_counts[casing_name] = 0
    group.casing_vote_first_seen[casing_name] = row_index
  end
  group.casing_vote_counts[casing_name] = group.casing_vote_counts[casing_name] + 1
end

local function select_canonical_name(group)
  if group.fixed_canonical_name ~= nil then
    return group.fixed_canonical_name
  end

  local best_name = nil
  local best_count = -1
  local best_first_seen = math.huge

  for casing_name, vote_count in pairs(group.casing_vote_counts) do
    local first_seen = group.casing_vote_first_seen[casing_name] or math.huge
    if vote_count > best_count or (vote_count == best_count and first_seen < best_first_seen) then
      best_name = casing_name
      best_count = vote_count
      best_first_seen = first_seen
    end
  end

  return best_name or ""
end

local function resolve_name_for_row(row, row_index, previous_group_key)
  local raw_name = row.character_name
  local trimmed_name = trim_edge_whitespace(raw_name)
  local mode = Parse.empty_character_name_mode

  if Parse.empty_character_name_config[mode] == nil then
    return nil, nil, nil, "Invalid Parse.empty_character_name_mode: " .. tostring(mode)
  end

  if trimmed_name ~= "" then
    local grouping_key, lower_err = Utf8Tools.lower(trimmed_name)
    if grouping_key == nil then
      return nil, nil, nil, "Row " .. tostring(row_index) .. ": character_name contains " .. tostring(lower_err)
    end
    return grouping_key, trimmed_name, nil, nil
  end

  if mode == 1 then
    return nil, nil, nil, "Row " .. tostring(row_index) .. ": character_name is empty after trimming"
  end

  if mode == 2 then
    return "", "", nil, nil
  end

  if mode == 3 then
    if previous_group_key == nil then
      return nil, nil, nil, "Row " .. tostring(row_index) .. ": character_name is empty after trimming and there is no previous character to copy"
    end
    return previous_group_key, nil, nil, nil
  end

  return EMPTY_CHARACTER_NAME_PLACEHOLDER, nil, EMPTY_CHARACTER_NAME_PLACEHOLDER, nil
end

local function parse_basic_cyrillica_studio_timecode(timecode_string)
  local normalized = normalize_input(timecode_string)
  if normalized == "" then
    return nil, nil, GENERIC_BAD_INPUT
  end

  if normalized:find("::", 1, true) ~= nil then
    return nil, nil, GENERIC_BAD_INPUT
  end

  local trailing_sep = normalized:sub(-1)
  if trailing_sep == ":" then
    return nil, nil, GENERIC_BAD_INPUT
  end

  local fields = split_colon_fields(normalized)
  if #fields ~= 2 and #fields ~= 3 then
    return nil, nil, GENERIC_BAD_INPUT
  end

  local hours_text = "0"
  local minutes_text = nil
  local seconds_text = nil

  if #fields == 2 then
    minutes_text = fields[1]
    seconds_text = fields[2]
  else
    hours_text = fields[1]
    minutes_text = fields[2]
    seconds_text = fields[3]
  end

  if not hours_text:match("^%d+$") or not minutes_text:match("^%d+$") or not seconds_text:match("^%d+$") then
    return nil, nil, GENERIC_BAD_INPUT
  end

  if #seconds_text ~= 2 then
    return nil, nil, "only two-digit seconds supported"
  end

  if #minutes_text < 1 or #minutes_text > 2 then
    return nil, nil, GENERIC_BAD_INPUT
  end

  if #hours_text < 1 then
    return nil, nil, GENERIC_BAD_INPUT
  end

  local hours = tonumber(hours_text)
  local minutes = tonumber(minutes_text)
  local seconds = tonumber(seconds_text)

  if #hours_text > 2 then
    if hours > 99 then
      return nil, nil, "Bad input, on hours field we got " .. tostring(hours) .. ", this format supports only 00-99 hours!"
    end
    return nil, nil, GENERIC_BAD_INPUT
  end

  if hours > 99 then
    return nil, nil, "Bad input, on hours field we got " .. tostring(hours) .. ", this format supports only 00-99 hours!"
  end

  if minutes > 59 then
    return nil, nil, "Bad input, on minutes field we got " .. tostring(minutes) .. ", we can't have more than 59 minutes in timecode!"
  end

  if seconds > 59 then
    return nil, nil, "Bad input, on seconds field we got " .. tostring(seconds) .. ", we can't have more than 59 seconds in timecode!"
  end

  local normalized_timecode = string.format("%02d:%02d:%02d:00", hours, minutes, seconds)
  local raw_seconds = (hours * 3600) + (minutes * 60) + seconds
  return normalized_timecode, raw_seconds, "Success"
end

local function normalize_fractional_second_timecode(hours, minutes, seconds, fraction_seconds)
  local raw_seconds = (hours * 3600) + (minutes * 60) + seconds + fraction_seconds
  local whole_seconds = math.floor(raw_seconds)
  local millis = math.floor(((raw_seconds - whole_seconds) * 1000) + 0.5)
  if millis >= 1000 then
    whole_seconds = whole_seconds + 1
    millis = 0
  end
  local normalized_hours = math.floor(whole_seconds / 3600)
  local normalized_minutes = math.floor((whole_seconds % 3600) / 60)
  local normalized_seconds = whole_seconds % 60
  return string.format("%02d:%02d:%02d.%03d", normalized_hours, normalized_minutes, normalized_seconds, millis), raw_seconds
end

local function parse_fractional_seconds_timecode(timecode_string)
  local trimmed = trim_edge_whitespace(timecode_string)
  local hours_text, minutes_text, seconds_text, fraction_separator, fraction_text =
    trimmed:match("^(%d%d):(%d%d):(%d%d)([,.])(%d%d?%d?)$")

  if not hours_text then
    minutes_text, seconds_text, fraction_text = trimmed:match("^(%d%d):(%d%d)%.(%d+)$")
    hours_text = minutes_text and "00" or nil
    fraction_separator = "."
  end

  if not hours_text then
    hours_text, minutes_text, seconds_text, fraction_text = trimmed:match("^(%d%d):(%d%d):(%d%d)%.(%d+)$")
    fraction_separator = hours_text and "." or nil
  end

  if not hours_text then
    return nil, nil, "Bad input, expected HH:MM:SS,mmm, HH:MM:SS.mmm, or MM:SS.mmm"
  end

  local hours = tonumber(hours_text)
  local minutes = tonumber(minutes_text)
  local seconds = tonumber(seconds_text)
  local fraction_seconds = 0

  if hours > 99 then
    return nil, nil, "Bad input, on hours field we got " .. tostring(hours) .. ", this format supports only 00-99 hours!"
  end
  if minutes > 59 then
    return nil, nil, "Bad input, on minutes field we got " .. tostring(minutes) .. ", we can't have more than 59 minutes in timecode!"
  end
  if seconds > 59 then
    return nil, nil, "Bad input, on seconds field we got " .. tostring(seconds) .. ", we can't have more than 59 seconds in timecode!"
  end

  if fraction_separator == "," then
    fraction_seconds = (tonumber(fraction_text) or 0) / 1000.0
  else
    fraction_seconds = tonumber("0." .. tostring(fraction_text)) or 0
  end

  local normalized_timecode, raw_seconds = normalize_fractional_second_timecode(hours, minutes, seconds, fraction_seconds)
  return normalized_timecode, raw_seconds, "Success"
end

local function nominal_frame_count_for_fps(source_fps)
  local fps = tonumber(source_fps)
  if fps == nil or fps <= 0 then
    return nil
  end
  return math.max(1, math.floor(fps + 0.5))
end

local function fps_drop_frame_count(source_fps)
  local nominal_frame_count = nominal_frame_count_for_fps(source_fps)
  if nominal_frame_count == nil then
    return nil
  end

  local ntsc_fps = nominal_frame_count * 1000 / 1001
  if math.abs((tonumber(source_fps) or 0) - ntsc_fps) > 0.02 then
    return nil
  end
  if nominal_frame_count % 30 ~= 0 then
    return nil
  end
  return math.floor((nominal_frame_count * 0.0666666667) + 0.5)
end

local function frame_width_for(nominal_frame_count, frames_text)
  local input_width = #(tostring(frames_text or ""))
  if nominal_frame_count ~= nil and nominal_frame_count >= 100 then
    return math.max(3, input_width)
  end
  return math.max(2, input_width)
end

local function parse_hh_mm_ss_frames_timecode(timecode_string, opts, drop_frame)
  local options = type(opts) == "table" and opts or {}
  local source_fps = tonumber(options.source_fps)
  if source_fps == nil or source_fps <= 0 then
    return nil, nil, drop_frame and "Source FPS is required for HH:MM:SS;FF" or "Source FPS is required for HH:MM:SS:FF"
  end

  local trimmed = trim_edge_whitespace(timecode_string)
  local frame_separator = drop_frame and "[;%.]" or ":"
  local hours_text, minutes_text, seconds_text, frames_text =
    trimmed:match("^(%d%d):(%d%d):(%d%d)" .. frame_separator .. "(%d%d?%d?)$")

  if not hours_text then
    return nil, nil, drop_frame and "Bad input, expected HH:MM:SS;FF" or "Bad input, expected HH:MM:SS:FF"
  end

  local hours = tonumber(hours_text)
  local minutes = tonumber(minutes_text)
  local seconds = tonumber(seconds_text)
  local frames = tonumber(frames_text)

  if hours > 99 then
    return nil, nil, "Bad input, on hours field we got " .. tostring(hours) .. ", this format supports only 00-99 hours!"
  end
  if minutes > 59 then
    return nil, nil, "Bad input, on minutes field we got " .. tostring(minutes) .. ", we can't have more than 59 minutes in timecode!"
  end
  if seconds > 59 then
    return nil, nil, "Bad input, on seconds field we got " .. tostring(seconds) .. ", we can't have more than 59 seconds in timecode!"
  end

  local nominal_frame_count = nominal_frame_count_for_fps(source_fps)
  if nominal_frame_count == nil then
    return nil, nil, drop_frame and "Source FPS is required for HH:MM:SS;FF" or "Source FPS is required for HH:MM:SS:FF"
  end
  if frames >= nominal_frame_count then
    return nil, nil, "Bad input, on frames field we got " .. tostring(frames) .. ", this source FPS supports frames 00-" .. string.format("%0" .. tostring(frame_width_for(nominal_frame_count, frames_text)) .. "d", nominal_frame_count - 1)
  end

  local separator = drop_frame and ";" or ":"
  local normalized_timecode = string.format(
    "%02d:%02d:%02d%s%0" .. tostring(frame_width_for(nominal_frame_count, frames_text)) .. "d",
    hours,
    minutes,
    seconds,
    separator,
    frames
  )
  local total_nominal_frames = (((hours * 3600) + (minutes * 60) + seconds) * nominal_frame_count) + frames
  if drop_frame == true then
    local drop_frames = fps_drop_frame_count(source_fps)
    if drop_frames == nil then
      return nil, nil, "Drop-frame timecode requires an NTSC-rate Source FPS such as 29.97 or 59.94"
    end
    if (minutes % 10) ~= 0 and seconds == 0 and frames < drop_frames then
      return nil, nil, "Bad input, drop-frame timecode skips frames 00-" .. string.format("%0" .. tostring(frame_width_for(nominal_frame_count, frames_text)) .. "d", drop_frames - 1) .. " at this minute"
    end
    local total_minutes = (hours * 60) + minutes
    total_nominal_frames = total_nominal_frames - (drop_frames * (total_minutes - math.floor(total_minutes / 10)))
  end
  local raw_seconds = total_nominal_frames / source_fps
  return normalized_timecode, raw_seconds, "Success"
end

function Parse.parse_timecode(timecode_string, format_id, opts)
  local format_num, format_err = validate_supported_timecode_format_id(format_id)
  if format_num == nil then
    return nil, nil, format_err
  end
  if format_num == 2 then
    return parse_fractional_seconds_timecode(timecode_string)
  end
  if format_num == 3 then
    return parse_hh_mm_ss_frames_timecode(timecode_string, opts, false)
  end
  if format_num == 4 then
    return parse_hh_mm_ss_frames_timecode(timecode_string, opts, true)
  end
  return parse_basic_cyrillica_studio_timecode(timecode_string)
end

function Parse.extract_inline_timecode_fragments(base_timecode_text, dialogue_text, format_id, opts)
  if type(base_timecode_text) ~= "string" then
    return nil, nil, "base_timecode_text must be a string"
  end

  if type(dialogue_text) ~= "string" then
    return nil, nil, "dialogue_text must be a string"
  end

  local format_num, format_err = validate_supported_timecode_format_id(format_id)
  if format_num == nil then
    return nil, nil, format_err
  end

  local fragments = {}
  local inline_count = 0
  local current_timecode = base_timecode_text
  local scan_from = 1

  while true do
    local match = find_next_inline_timecode(dialogue_text, scan_from, format_num, opts)
    if match == nil then
      break
    end

    append_inline_fragment(
      fragments,
      current_timecode,
      dialogue_text:sub(scan_from, match.match_start - 1),
      inline_count > 0
    )
    current_timecode = match.token_text
    inline_count = inline_count + 1
    scan_from = match.match_end + 1
  end

  append_inline_fragment(
    fragments,
    current_timecode,
    dialogue_text:sub(scan_from),
    inline_count > 0
  )

  return fragments, inline_count, "Success"
end

function Parse.process_script_cast(script_rows)
  local row_count, top_level_err = validate_dense_array(script_rows, "script_rows")
  if row_count == nil then
    return nil, nil, top_level_err
  end

  local groups_by_key = {}
  local ordered_groups = {}
  local previous_group_key = nil

  for row_index = 1, row_count do
    local row = script_rows[row_index]
    if type(row) ~= "table" then
      return nil, nil, "Row " .. tostring(row_index) .. ": expected table"
    end

    if type(row.timecode) ~= "string" then
      return nil, nil, "Row " .. tostring(row_index) .. ": timecode must be a string"
    end

    if type(row.character_name) ~= "string" then
      return nil, nil, "Row " .. tostring(row_index) .. ": character_name must be a string"
    end

    if type(row.character_line) ~= "string" then
      return nil, nil, "Row " .. tostring(row_index) .. ": character_line must be a string"
    end

    local grouping_key, casing_name, fixed_canonical_name, resolve_err = resolve_name_for_row(row, row_index, previous_group_key)
    if resolve_err ~= nil then
      return nil, nil, resolve_err
    end

    local utf8_key_length, utf8_err = utf8_length(grouping_key)
    if utf8_key_length == nil then
      return nil, nil, "Row " .. tostring(row_index) .. ": character_name contains " .. tostring(utf8_err)
    end

    local group = groups_by_key[grouping_key]
    if group == nil then
      group = {
        grouping_key = grouping_key,
        utf8_key_length = utf8_key_length,
        count = 0,
        raw_names_captured = {},
        timecodes_lines_from_script = {},
        casing_vote_counts = {},
        casing_vote_first_seen = {},
        first_seen_row_index = row_index,
        fixed_canonical_name = fixed_canonical_name
      }
      groups_by_key[grouping_key] = group
      ordered_groups[#ordered_groups + 1] = group
    elseif group.fixed_canonical_name == nil and fixed_canonical_name ~= nil then
      group.fixed_canonical_name = fixed_canonical_name
    end

    group.count = group.count + 1
    add_tally(group.raw_names_captured, row.character_name)
    group.timecodes_lines_from_script[#group.timecodes_lines_from_script + 1] = {
      row.timecode,
      row.character_line
    }

    if casing_name ~= nil then
      add_casing_vote(group, casing_name, row_index)
    end

    previous_group_key = grouping_key
  end

  local characters = {}
  for i = 1, #ordered_groups do
    local group = ordered_groups[i]
    characters[#characters + 1] = {
      id = 0,
      name = select_canonical_name(group),
      count = group.count,
      raw_names_captured = group.raw_names_captured,
      timecodes_lines_from_script = group.timecodes_lines_from_script,
      _grouping_key = group.grouping_key,
      _utf8_key_length = group.utf8_key_length,
      _first_seen_row_index = group.first_seen_row_index
    }
  end

  table.sort(characters, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end

    if a._first_seen_row_index ~= b._first_seen_row_index then
      return a._first_seen_row_index < b._first_seen_row_index
    end

    return a._grouping_key < b._grouping_key
  end)

  for i = 1, #characters do
    characters[i].id = i
  end

  local merge_candidates = {}
  local max_distance = tonumber(Parse.maximum_allowed_typo_distance)
  if max_distance == nil or max_distance < 0 or math.floor(max_distance) ~= max_distance then
    return nil, nil, "Invalid Parse.maximum_allowed_typo_distance: " .. tostring(Parse.maximum_allowed_typo_distance)
  end

  for i = 1, #characters - 1 do
    local canonical = characters[i]
    local canonical_codes, canonical_codes_err = utf8_codepoints(canonical._grouping_key)
    if canonical_codes == nil then
      return nil, nil, "Character '" .. tostring(canonical.name) .. "' has invalid UTF-8: " .. tostring(canonical_codes_err)
    end

    for j = i + 1, #characters do
      local typo = characters[j]
      local length_delta = math.abs(canonical._utf8_key_length - typo._utf8_key_length)
      if length_delta <= max_distance then
        local typo_codes, typo_codes_err = utf8_codepoints(typo._grouping_key)
        if typo_codes == nil then
          return nil, nil, "Character '" .. tostring(typo.name) .. "' has invalid UTF-8: " .. tostring(typo_codes_err)
        end

        local distance = utf8_levenshtein_distance(canonical_codes, typo_codes, max_distance)
        if distance <= max_distance then
          merge_candidates[#merge_candidates + 1] = {
            canonical_id = canonical.id,
            typo_id = typo.id,
            distance = distance
          }
        end
      end
    end
  end

  for i = 1, #characters do
    characters[i]._grouping_key = nil
    characters[i]._utf8_key_length = nil
    characters[i]._first_seen_row_index = nil
  end

  return characters, merge_candidates, "Success"
end

return Parse

