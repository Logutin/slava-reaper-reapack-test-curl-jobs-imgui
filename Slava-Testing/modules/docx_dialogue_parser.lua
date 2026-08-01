-- @noindex
-- DOCX dialogue parser facade for table and paragraph-based script layouts.
-- Public entry point:
-- DocxDialogueParser.parse_docx_dialogue_xml(path_to_valid_docx_xml, opts)

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local Files = require("modules.Files")
local Util = require("modules.Util")
local LegacyTableParser = require("modules.docx_xml_parser")

local DocxDialogueParser = {}

local VALID_SOURCE_MODES = {
  auto = true,
  table_last = true,
  paragraph_start_end = true,
  paragraph_line_stream = true
}

local DEFAULT_SOURCE_MODE = "auto"
local TABLE_TIMECODE_FORMAT_ID = 1
local PLAIN_TIMECODE_FORMAT_ID = 1
local MILLISECOND_TIMECODE_FORMAT_ID = 2
local FRAME_TIMECODE_FORMAT_ID = 3
local DROP_FRAME_TIMECODE_FORMAT_ID = 4
local EMPTY_CHARACTER_REASON_LINE_STREAM = "single_line_after_timecode"
local EMPTY_CHARACTER_REASON_LINE_STREAM_BLANK = "blank_character_line_after_timecode"
local EMPTY_CHARACTER_REASON_LINE_STREAM_EMPTY_RECORD = "no_text_after_timecode"
local EMPTY_DIALOGUE_REASON_LINE_STREAM = "missing_dialogue_after_timecode"
local EMPTY_CHARACTER_REASON_START_END = "single_line_after_start_end_timecodes"
local LINE_STREAM_WARNING_EXAMPLE_LIMIT = 5

local function t(text)
  return tostring(text or "")
end

local function make_result(message, requested_mode, detected_mode, supports_header, suggested_format_id)
  return {
    message = tostring(message or ""),
    number_of_columns = 0,
    number_of_rows = 0,
    rows = {},
    source_mode_requested = tostring(requested_mode or DEFAULT_SOURCE_MODE),
    source_mode_detected = tostring(detected_mode or ""),
    supports_header = supports_header == true,
    suggested_timecode_format_id = suggested_format_id,
    suggested_header_enabled = false,
    suggested_mapping = nil,
    row_metadata_by_index = {},
    warnings = {},
    warning_count = 0,
    empty_character_row_count = 0,
    empty_dialogue_row_count = 0
  }
end

local function normalize_source_mode(value)
  local mode = tostring(value or DEFAULT_SOURCE_MODE)
  if VALID_SOURCE_MODES[mode] then
    return mode
  end
  return DEFAULT_SOURCE_MODE
end

local function parse_tag_descriptor(tag_body)
  local text = tostring(tag_body or "")
  local first = text:sub(1, 1)
  if first == "?" or first == "!" then
    return nil, false, false
  end

  local trimmed = text:match("^%s*(.-)%s*$") or ""
  local is_closing = false
  if trimmed:sub(1, 1) == "/" then
    is_closing = true
    trimmed = trimmed:sub(2):match("^%s*(.-)%s*$") or ""
  end

  local is_self_closing = false
  if trimmed:sub(-1) == "/" then
    is_self_closing = true
    trimmed = trimmed:sub(1, -2):match("^%s*(.-)%s*$") or ""
  end

  local name = trimmed:match("^([%w_:%-%.]+)")
  return name, is_closing, is_self_closing
end

local function xml_decode_text(text)
  local value = tostring(text or "")
  value = value:gsub("&lt;", "<")
  value = value:gsub("&gt;", ">")
  value = value:gsub("&quot;", '"')
  value = value:gsub("&apos;", "'")
  value = value:gsub("&amp;", "&")
  return value
end

local function append_part(parts, text)
  if parts == nil then return end
  parts[#parts + 1] = tostring(text or "")
end

local function collect_paragraph_texts(xml_text)
  local paragraphs = {}
  local current_parts = nil
  local in_text = false
  local cursor = 1

  for tag_start, tag_body, next_pos in tostring(xml_text or ""):gmatch("()<([^>]+)>()") do
    if in_text and current_parts ~= nil and tag_start > cursor then
      append_part(current_parts, xml_decode_text(xml_text:sub(cursor, tag_start - 1)))
    end

    local name, is_closing, is_self_closing = parse_tag_descriptor(tag_body)

    if name == "w:p" then
      if is_closing then
        if current_parts ~= nil then
          paragraphs[#paragraphs + 1] = table.concat(current_parts)
        end
        current_parts = nil
        in_text = false
      elseif not is_self_closing then
        current_parts = {}
        in_text = false
      end
    elseif current_parts ~= nil then
      if name == "w:t" then
        if is_closing then
          in_text = false
        elseif not is_self_closing then
          in_text = true
        end
      elseif name == "w:tab" then
        if not is_closing then
          append_part(current_parts, " ")
        end
      elseif name == "w:br" or name == "w:cr" then
        if not is_closing then
          append_part(current_parts, "\n")
        end
      end
    end

    cursor = next_pos
  end

  return paragraphs
end

local function split_nonempty_lines(text)
  local out = {}
  local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = Util.trim(line)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

local function split_paragraph_lines(text, preserve_empty)
  local out = {}
  local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = Util.trim(line)
    if preserve_empty == true or trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

local function nonempty_lines_from_paragraphs(xml_text)
  local paragraphs = collect_paragraph_texts(xml_text)
  local out = {}
  for paragraph_index = 1, #paragraphs do
    local lines = split_nonempty_lines(paragraphs[paragraph_index])
    for line_index = 1, #lines do
      out[#out + 1] = {
        text = lines[line_index],
        paragraph_index = paragraph_index
      }
    end
  end
  return out
end

local function paragraph_lines_from_paragraphs(xml_text, preserve_empty)
  local paragraphs = collect_paragraph_texts(xml_text)
  local out = {}
  for paragraph_index = 1, #paragraphs do
    local lines = split_paragraph_lines(paragraphs[paragraph_index], preserve_empty == true)
    for line_index = 1, #lines do
      out[#out + 1] = {
        text = lines[line_index],
        paragraph_index = paragraph_index
      }
    end
  end
  return out
end

local function time_parts_are_valid(hours, minutes, seconds)
  return hours ~= nil and hours <= 99 and minutes ~= nil and minutes <= 59 and seconds ~= nil and seconds <= 59
end

local function is_millisecond_timecode(text)
  local value = tostring(text or "")
  local hh, mm, ss, _sep, fraction = value:match("^(%d%d):(%d%d):(%d%d)([,.])(%d%d?%d?)$")
  if not hh then
    hh, mm, ss, fraction = value:match("^(%d%d):(%d%d):(%d%d)%.(%d+)$")
  end
  if not hh then
    mm, ss, fraction = value:match("^(%d%d):(%d%d)%.(%d+)$")
    hh = mm and "00" or nil
  end
  if not hh then return false end
  local hours = tonumber(hh)
  local minutes = tonumber(mm)
  local seconds = tonumber(ss)
  return time_parts_are_valid(hours, minutes, seconds) and tonumber(fraction) ~= nil
end

local function is_plain_hms_timecode(text)
  local hh, mm, ss = tostring(text or ""):match("^(%d%d?):(%d%d):(%d%d)$")
  if not hh then return false end
  local hours = tonumber(hh)
  local minutes = tonumber(mm)
  local seconds = tonumber(ss)
  return time_parts_are_valid(hours, minutes, seconds)
end

local function is_plain_mm_ss_timecode(text)
  local mm, ss = tostring(text or ""):match("^(%d%d?):(%d%d)$")
  if not mm then return false end
  local minutes = tonumber(mm)
  local seconds = tonumber(ss)
  return minutes ~= nil and minutes <= 99 and seconds ~= nil and seconds <= 59
end

local function is_frame_timecode(text)
  local hh, mm, ss, ff = tostring(text or ""):match("^(%d%d):(%d%d):(%d%d):(%d%d?%d?)$")
  if not hh then return false end
  local hours = tonumber(hh)
  local minutes = tonumber(mm)
  local seconds = tonumber(ss)
  local frames = tonumber(ff)
  return time_parts_are_valid(hours, minutes, seconds) and frames ~= nil
end

local function is_drop_frame_timecode(text)
  local hh, mm, ss, ff = tostring(text or ""):match("^(%d%d):(%d%d):(%d%d);(%d%d?%d?)$")
  if not hh then return false end
  local hours = tonumber(hh)
  local minutes = tonumber(mm)
  local seconds = tonumber(ss)
  local frames = tonumber(ff)
  return time_parts_are_valid(hours, minutes, seconds) and frames ~= nil
end

local function detected_timecode_format_id(text)
  if is_drop_frame_timecode(text) then
    return DROP_FRAME_TIMECODE_FORMAT_ID
  end
  if is_frame_timecode(text) then
    return FRAME_TIMECODE_FORMAT_ID
  end
  if is_millisecond_timecode(text) then
    return MILLISECOND_TIMECODE_FORMAT_ID
  end
  if is_plain_hms_timecode(text) then
    return PLAIN_TIMECODE_FORMAT_ID
  end
  return nil
end

local function detected_line_stream_timecode_format_id(text)
  local format_id = detected_timecode_format_id(text)
  if format_id ~= nil then
    return format_id
  end
  if is_plain_mm_ss_timecode(text) then
    return PLAIN_TIMECODE_FORMAT_ID
  end
  return nil
end

local function is_line_stream_timecode(text)
  return detected_line_stream_timecode_format_id(text) ~= nil
end

local function suggested_format_from_counts(counts)
  local ordered_format_ids = {
    DROP_FRAME_TIMECODE_FORMAT_ID,
    FRAME_TIMECODE_FORMAT_ID,
    MILLISECOND_TIMECODE_FORMAT_ID,
    PLAIN_TIMECODE_FORMAT_ID
  }
  local best_format_id = PLAIN_TIMECODE_FORMAT_ID
  local best_count = 0
  for i = 1, #ordered_format_ids do
    local format_id = ordered_format_ids[i]
    local count = counts and tonumber(counts[format_id]) or 0
    if count ~= nil and count > best_count then
      best_format_id = format_id
      best_count = count
    end
  end
  return best_format_id
end

local function split_table_timecode_range(text)
  local value = Util.trim(tostring(text or ""))
  local start_tc, end_tc = value:match("^(.+)%s*%-%s*(.+)$")
  if not start_tc then
    return nil, nil, nil
  end

  start_tc = Util.trim(start_tc)
  end_tc = Util.trim(end_tc)
  local start_format_id = detected_timecode_format_id(start_tc)
  local end_format_id = detected_timecode_format_id(end_tc)
  if start_tc and end_tc and start_format_id ~= nil and start_format_id == end_format_id then
    return start_tc, end_tc, start_format_id
  end
  return nil, nil, nil
end

local function normalize_header_text(text)
  local value = Util.trim(tostring(text or "")):lower()
  value = value:gsub("\194\160", " ")
  value = value:gsub("%s+", " ")
  return value
end

local function row_is_empty(row)
  for i = 1, #(row or {}) do
    if Util.trim(tostring(row[i] or "")) ~= "" then
      return false
    end
  end
  return true
end

local function detect_table_header_mapping(header_row)
  local mapping = {
    header_enabled = false,
    timecode_col = nil,
    end_timecode_col = nil,
    character_name_col = nil,
    dialogue_col = nil
  }

  for col = 1, #(header_row or {}) do
    local header = normalize_header_text(header_row[col])
    if header == "timecode" or header == "timestamp" or header == "tc in" then
      mapping.timecode_col = mapping.timecode_col or col
      mapping.header_enabled = true
    elseif header == "tc out" then
      mapping.end_timecode_col = mapping.end_timecode_col or col
      mapping.header_enabled = true
    elseif header == "character" or header == "personaje" then
      mapping.character_name_col = mapping.character_name_col or col
      mapping.header_enabled = true
    elseif
      header == "translation" or
      header == "brazilian portuguese" or
      header == "português (brasil)" or
      header == "portuguese (brasil)" or
      header == "português" or
      header == "portuguese"
    then
      mapping.dialogue_col = col
      mapping.header_enabled = true
    elseif (header == "dialogue" or header == "english") and mapping.dialogue_col == nil then
      mapping.dialogue_col = col
      mapping.header_enabled = true
    end
  end

  if mapping.header_enabled ~= true then
    return nil
  end

  mapping.timecode_col = mapping.timecode_col or 1
  mapping.character_name_col = mapping.character_name_col or 2
  mapping.dialogue_col = mapping.dialogue_col or math.min(3, #(header_row or {}))
  return mapping
end

local function xml_has_table(xml_text)
  return tostring(xml_text or ""):find("<w:tbl", 1, true) ~= nil
end

local function rows_to_result(rows, metadata, requested_mode, detected_mode, suggested_format_id, warnings)
  local result = make_result("_Success_", requested_mode, detected_mode, false, suggested_format_id)
  result.number_of_columns = 3
  result.number_of_rows = #rows
  result.rows = rows
  result.row_metadata_by_index = metadata or {}
  result.warnings = warnings or {}
  result.warning_count = #result.warnings
  result.empty_character_row_count = 0
  result.empty_dialogue_row_count = 0
  for i = 1, #result.row_metadata_by_index do
    local row_metadata = result.row_metadata_by_index[i]
    if row_metadata and row_metadata.empty_character_detected == true then
      result.empty_character_row_count = result.empty_character_row_count + 1
    end
    if row_metadata and row_metadata.empty_dialogue_detected == true then
      result.empty_dialogue_row_count = result.empty_dialogue_row_count + 1
    end
  end
  return result
end

local function append_warning(warnings, message)
  local text = Util.trim(message)
  if text ~= "" then
    warnings[#warnings + 1] = text
  end
end

local function make_empty_character_warning(row_number, start_timecode)
  return string.format(
    "DOCX parser row %s at %s has an empty character name because only one text line belongs to the record. Review Empty character handling before Process Cast.",
    tostring(row_number),
    tostring(start_timecode or "")
  )
end

local function append_line_stream_issue(issues, kind, row_number, line_index, start_timecode)
  issues[#issues + 1] = {
    kind = tostring(kind or ""),
    row_number = row_number,
    line_index = line_index,
    start_timecode = tostring(start_timecode or "")
  }
end

local function line_stream_issue_label(kind)
  if kind == "empty_character_and_dialogue" then
    return "empty character and dialogue"
  end
  if kind == "empty_character" then
    return "empty character"
  end
  if kind == "empty_dialogue" then
    return "empty dialogue"
  end
  if kind == "skipped_preamble" then
    return "text before the first timecode"
  end
  return tostring(kind or "issue")
end

local function make_line_stream_aggregate_warning(issue_counts, issue_examples)
  local parts = {}
  if (issue_counts.empty_character_and_dialogue or 0) > 0 then
    parts[#parts + 1] = tostring(issue_counts.empty_character_and_dialogue) .. " row(s) with empty character and dialogue"
  end
  if (issue_counts.empty_character or 0) > 0 then
    parts[#parts + 1] = tostring(issue_counts.empty_character) .. " row(s) with empty character"
  end
  if (issue_counts.empty_dialogue or 0) > 0 then
    parts[#parts + 1] = tostring(issue_counts.empty_dialogue) .. " row(s) with empty dialogue"
  end
  if (issue_counts.skipped_preamble or 0) > 0 then
    parts[#parts + 1] = tostring(issue_counts.skipped_preamble) .. " non-timecode line(s) before the first timecode"
  end

  local examples = {}
  for i = 1, math.min(#(issue_examples or {}), LINE_STREAM_WARNING_EXAMPLE_LIMIT) do
    local issue = issue_examples[i]
    if issue.kind == "skipped_preamble" then
      examples[#examples + 1] = string.format(
        "%s near source line %s",
        line_stream_issue_label(issue.kind),
        tostring(issue.line_index or "?")
      )
    else
      examples[#examples + 1] = string.format(
        "%s at row %s, line %s, timecode %s",
        line_stream_issue_label(issue.kind),
        tostring(issue.row_number or "?"),
        tostring(issue.line_index or "?"),
        tostring(issue.start_timecode or "")
      )
    end
  end

  local warning = "DOCX line-stream parser accepted malformed section(s): " .. table.concat(parts, "; ") .. "."
  if #examples > 0 then
    warning = warning .. " Examples: " .. table.concat(examples, "; ") .. "."
  end
  warning = warning .. " Empty fields were imported as blank values; review the DOCX around the listed timecode(s)."
  return warning
end

local function make_skipped_preamble_warning(skipped_count)
  return string.format(
    "DOCX parser skipped %s non-empty line(s) before the first start/end timecode record. Review the DOCX header or preamble if parsed rows look offset.",
    tostring(skipped_count or 0)
  )
end

local function make_skipped_empty_table_rows_warning(skipped_count)
  return string.format(
    t("DOCX table parser skipped %s fully empty row(s)."),
    tostring(skipped_count or 0)
  )
end

local function join_text_lines(lines, start_index)
  local parts = {}
  for i = start_index, #(lines or {}) do
    parts[#parts + 1] = tostring(lines[i] and lines[i].text or "")
  end
  return table.concat(parts, "\n")
end

local function compact_nonempty_text_lines(lines)
  local out = {}
  for i = 1, #(lines or {}) do
    if Util.trim(tostring(lines[i] and lines[i].text or "")) ~= "" then
      out[#out + 1] = lines[i]
    end
  end
  return out
end

local function find_first_millisecond_start_end_pair(lines)
  for i = 1, math.max(0, #lines - 1) do
    local current_text = lines[i] and lines[i].text or ""
    local next_text = lines[i + 1] and lines[i + 1].text or ""
    if is_millisecond_timecode(current_text) and is_millisecond_timecode(next_text) then
      return i
    end
  end
  return nil
end

local function first_timecode_line_index(lines)
  for i = 1, #(lines or {}) do
    if detected_line_stream_timecode_format_id(lines[i] and lines[i].text or "") ~= nil then
      return i
    end
  end
  return nil
end

local function analyze_line_stream_shape(lines)
  local analysis = {
    timecode_count = 0,
    zero_text_count = 0,
    one_text_count = 0,
    two_or_more_text_count = 0,
    first_timecode_index = nil,
    clearly_line_stream = false
  }

  local first_index = first_timecode_line_index(lines)
  analysis.first_timecode_index = first_index
  if first_index == nil then
    return analysis
  end

  local index = first_index
  while index <= #lines do
    local format_id = detected_line_stream_timecode_format_id(lines[index] and lines[index].text or "")
    if format_id == nil then
      index = index + 1
    else
      analysis.timecode_count = analysis.timecode_count + 1
      local text_count = 0
      local cursor = index + 1
      while cursor <= #lines and detected_line_stream_timecode_format_id(lines[cursor] and lines[cursor].text or "") == nil do
        if Util.trim(tostring(lines[cursor] and lines[cursor].text or "")) ~= "" then
          text_count = text_count + 1
        end
        cursor = cursor + 1
      end
      if text_count == 0 then
        analysis.zero_text_count = analysis.zero_text_count + 1
      elseif text_count == 1 then
        analysis.one_text_count = analysis.one_text_count + 1
      else
        analysis.two_or_more_text_count = analysis.two_or_more_text_count + 1
      end
      index = cursor
    end
  end

  local max_zero_text_for_clear_line_stream = math.max(3, math.floor(analysis.timecode_count * 0.20))
  analysis.clearly_line_stream =
    analysis.timecode_count >= 3 and
    analysis.two_or_more_text_count > 0 and
    analysis.zero_text_count <= max_zero_text_for_clear_line_stream
  return analysis
end

local function parse_paragraph_start_end_from_lines(lines, requested_mode)
  local rows = {}
  local metadata = {}
  local warnings = {}
  if #lines == 0 then
    return nil, "paragraph_start_end: no non-empty lines found"
  end

  local index = find_first_millisecond_start_end_pair(lines)
  if index == nil then
    return nil, "paragraph_start_end: no millisecond start/end timecode pair found"
  end
  if index > 1 then
    append_warning(warnings, make_skipped_preamble_warning(index - 1))
  end

  while index <= #lines do
    local start_line = lines[index]
    local end_line = lines[index + 1]
    local start_timecode = start_line and start_line.text or ""
    local end_timecode = end_line and end_line.text or ""

    if not is_millisecond_timecode(start_timecode) then
      return nil, "paragraph_start_end: expected millisecond start timecode at line " .. tostring(index)
    end
    if not is_millisecond_timecode(end_timecode) then
      return nil, "paragraph_start_end: expected millisecond end timecode at line " .. tostring(index + 1)
    end

    local text_lines = {}
    local cursor = index + 2
    while cursor <= #lines do
      local current_text = lines[cursor] and lines[cursor].text or ""
      local next_text = lines[cursor + 1] and lines[cursor + 1].text or ""
      if is_millisecond_timecode(current_text) and is_millisecond_timecode(next_text) then
        break
      end
      text_lines[#text_lines + 1] = lines[cursor]
      cursor = cursor + 1
    end

    if #text_lines == 0 then
      return nil, "paragraph_start_end: expected character/dialogue text after end timecode at line " .. tostring(index + 1)
    end

    local row_number = #rows + 1
    local speaker = ""
    local dialogue = ""
    local empty_character_detected = false
    local empty_character_reason = ""
    if #text_lines == 1 then
      dialogue = tostring(text_lines[1].text or "")
      empty_character_detected = true
      empty_character_reason = EMPTY_CHARACTER_REASON_START_END
      append_warning(warnings, make_empty_character_warning(row_number, start_timecode))
    else
      speaker = tostring(text_lines[1].text or "")
      dialogue = join_text_lines(text_lines, 2)
    end

    rows[row_number] = {
      start_timecode,
      tostring(speaker or ""),
      tostring(dialogue or "")
    }
    metadata[row_number] = {
      source_line_index = index,
      source_paragraph_index = start_line and start_line.paragraph_index or nil,
      start_timecode = start_timecode,
      end_timecode = end_timecode,
      text_line_count = #text_lines,
      empty_character_detected = empty_character_detected,
      empty_character_reason = empty_character_reason
    }

    index = cursor
  end

  return rows_to_result(rows, metadata, requested_mode, "paragraph_start_end", MILLISECOND_TIMECODE_FORMAT_ID, warnings)
end

local function parse_paragraph_line_stream_from_lines(lines, requested_mode)
  local rows = {}
  local metadata = {}
  local warnings = {}
  local issue_counts = {}
  local issue_examples = {}
  local index = first_timecode_line_index(lines)
  local format_counts = {}
  local skipped_preamble_count = 0

  if index == nil then
    return nil, "paragraph_line_stream: no recognizable timecodes found"
  end

  for i = 1, index - 1 do
    if Util.trim(tostring(lines[i] and lines[i].text or "")) ~= "" then
      skipped_preamble_count = skipped_preamble_count + 1
    end
  end
  if skipped_preamble_count > 0 then
    issue_counts.skipped_preamble = skipped_preamble_count
    append_line_stream_issue(issue_examples, "skipped_preamble", 0, 1, "")
  end

  while index <= #lines do
    local current = lines[index]
    local start_timecode = current and current.text or ""
    local format_id = detected_line_stream_timecode_format_id(start_timecode)
    if format_id == nil then
      index = index + 1
    else
      format_counts[format_id] = (format_counts[format_id] or 0) + 1

      local text_lines = {}
      local cursor = index + 1
      while cursor <= #lines and not is_line_stream_timecode(lines[cursor].text) do
        text_lines[#text_lines + 1] = lines[cursor]
        cursor = cursor + 1
      end

      local row_number = #rows + 1
      local speaker = ""
      local dialogue = ""
      local empty_character_detected = false
      local empty_character_reason = ""
      local empty_dialogue_detected = false
      local empty_dialogue_reason = ""
      local compact_text_lines = compact_nonempty_text_lines(text_lines)
      local first_raw_line_is_blank =
        #text_lines > 0 and Util.trim(tostring(text_lines[1] and text_lines[1].text or "")) == ""

      if #compact_text_lines == 0 then
        empty_character_detected = true
        empty_character_reason = EMPTY_CHARACTER_REASON_LINE_STREAM_EMPTY_RECORD
        empty_dialogue_detected = true
        empty_dialogue_reason = EMPTY_DIALOGUE_REASON_LINE_STREAM
        issue_counts.empty_character_and_dialogue = (issue_counts.empty_character_and_dialogue or 0) + 1
        append_line_stream_issue(issue_examples, "empty_character_and_dialogue", row_number, index, start_timecode)
      elseif first_raw_line_is_blank and #compact_text_lines == 1 then
        speaker = ""
        dialogue = tostring(compact_text_lines[1].text or "")
        empty_character_detected = true
        empty_character_reason = EMPTY_CHARACTER_REASON_LINE_STREAM_BLANK
        issue_counts.empty_character = (issue_counts.empty_character or 0) + 1
        append_line_stream_issue(issue_examples, "empty_character", row_number, index, start_timecode)
        if Util.trim(dialogue) == "" then
          empty_dialogue_detected = true
          empty_dialogue_reason = EMPTY_DIALOGUE_REASON_LINE_STREAM
          issue_counts.empty_dialogue = (issue_counts.empty_dialogue or 0) + 1
          append_line_stream_issue(issue_examples, "empty_dialogue", row_number, index, start_timecode)
        end
      elseif #compact_text_lines == 1 then
        speaker = tostring(compact_text_lines[1].text or "")
        dialogue = ""
        empty_dialogue_detected = true
        empty_dialogue_reason = EMPTY_DIALOGUE_REASON_LINE_STREAM
        issue_counts.empty_dialogue = (issue_counts.empty_dialogue or 0) + 1
        append_line_stream_issue(issue_examples, "empty_dialogue", row_number, index, start_timecode)
      else
        speaker = tostring(compact_text_lines[1].text or "")
        dialogue = join_text_lines(compact_text_lines, 2)
      end

      rows[row_number] = {
        start_timecode,
        tostring(speaker or ""),
        tostring(dialogue or "")
      }
      metadata[row_number] = {
        source_line_index = index,
        source_paragraph_index = current.paragraph_index,
        start_timecode = start_timecode,
        text_line_count = #text_lines,
        nonempty_text_line_count = #compact_text_lines,
        empty_character_detected = empty_character_detected,
        empty_character_reason = empty_character_reason,
        empty_dialogue_detected = empty_dialogue_detected,
        empty_dialogue_reason = empty_dialogue_reason
      }

      index = cursor
    end
  end

  if #rows == 0 then
    return nil, "paragraph_line_stream: no rows found"
  end

  if
    (issue_counts.empty_character_and_dialogue or 0) > 0 or
    (issue_counts.empty_character or 0) > 0 or
    (issue_counts.empty_dialogue or 0) > 0 or
    (issue_counts.skipped_preamble or 0) > 0
  then
    append_warning(warnings, make_line_stream_aggregate_warning(issue_counts, issue_examples))
  end

  return rows_to_result(rows, metadata, requested_mode, "paragraph_line_stream", suggested_format_from_counts(format_counts), warnings)
end

local function parse_table_last(xml_path, requested_mode, header)
  local legacy = LegacyTableParser.parse_docx_xml(xml_path, header == true)
  if type(legacy) ~= "table" or legacy.message ~= "_Success_" then
    return legacy
  end

  local warnings = {}
  local processed_rows = {}
  local metadata = {}
  local skipped_empty_count = 0
  local header_mapping = detect_table_header_mapping(legacy.rows and legacy.rows[1] or nil)
  local timecode_col = header_mapping and header_mapping.timecode_col or 1
  local end_timecode_col = header_mapping and header_mapping.end_timecode_col or nil
  local format_counts = {}
  local end_timecode_count = 0

  for source_row_index = 1, #(legacy.rows or {}) do
    local source_row = legacy.rows[source_row_index] or {}
    if row_is_empty(source_row) then
      skipped_empty_count = skipped_empty_count + 1
    else
      local row = {}
      for col = 1, #(source_row or {}) do
        row[col] = tostring(source_row[col] or "")
      end

      local row_index = #processed_rows + 1
      local row_meta = {
        source_row_index = source_row_index,
        source_table_row_index = source_row_index,
        start_timecode = tostring(row[timecode_col] or ""),
        end_timecode = "",
        timestamp_range_detected = false
      }

      if not (header_mapping and header_mapping.header_enabled == true and source_row_index == 1) then
        local start_tc, end_tc, range_kind = split_table_timecode_range(row[timecode_col])
        if start_tc and end_tc then
          row[timecode_col] = start_tc
          row_meta.start_timecode = start_tc
          row_meta.end_timecode = end_tc
          row_meta.timestamp_range_detected = true
          format_counts[range_kind] = (format_counts[range_kind] or 0) + 1
          end_timecode_count = end_timecode_count + 1
        else
          local start_format_id = detected_timecode_format_id(row[timecode_col])
          if start_format_id ~= nil then
            format_counts[start_format_id] = (format_counts[start_format_id] or 0) + 1
          end
        end

        if end_timecode_col ~= nil and Util.trim(tostring(row[end_timecode_col] or "")) ~= "" then
          row_meta.end_timecode = tostring(row[end_timecode_col] or "")
          local end_format_id = detected_timecode_format_id(row_meta.end_timecode)
          if end_format_id ~= nil then
            format_counts[end_format_id] = (format_counts[end_format_id] or 0) + 1
          end
          end_timecode_count = end_timecode_count + 1
        end
      end

      processed_rows[row_index] = row
      metadata[row_index] = row_meta
    end
  end

  if skipped_empty_count > 0 then
    append_warning(warnings, make_skipped_empty_table_rows_warning(skipped_empty_count))
  end

  legacy.source_mode_requested = tostring(requested_mode or "table_last")
  legacy.source_mode_detected = "table_last"
  legacy.supports_header = true
  legacy.suggested_timecode_format_id = suggested_format_from_counts(format_counts)
  legacy.suggested_header_enabled = header_mapping and header_mapping.header_enabled == true
  legacy.suggested_mapping = header_mapping
  legacy.rows = processed_rows
  legacy.number_of_rows = #processed_rows
  legacy.row_metadata_by_index = metadata
  legacy.warnings = warnings
  legacy.warning_count = #legacy.warnings
  legacy.empty_character_row_count = 0
  legacy.end_timecode_count = end_timecode_count
  return legacy
end

local function read_xml(xml_path, requested_mode)
  local xml_text, read_info = Files.slurp_with_cap(xml_path)
  if type(xml_text) ~= "string" then
    return nil, make_result("failed to read XML file: " .. tostring(read_info or "unknown error"), requested_mode)
  end
  return xml_text, nil
end

function DocxDialogueParser.parse_docx_dialogue_xml(path_to_valid_docx_xml, opts)
  local options = type(opts) == "table" and opts or {}
  local requested_mode = normalize_source_mode(options.source_mode)
  local xml_path = Util.trim(path_to_valid_docx_xml)
  if xml_path == "" then
    return make_result("path_to_valid_docx_xml must be a non-empty string", requested_mode)
  end

  if requested_mode == "table_last" then
    return parse_table_last(xml_path, requested_mode, options.header)
  end

  local xml_text, read_failure = read_xml(xml_path, requested_mode)
  if not xml_text then
    return read_failure
  end

  if requested_mode == "paragraph_start_end" then
    local parsed, err = parse_paragraph_start_end_from_lines(nonempty_lines_from_paragraphs(xml_text), requested_mode)
    return parsed or make_result(err, requested_mode, "paragraph_start_end", false, MILLISECOND_TIMECODE_FORMAT_ID)
  end

  if requested_mode == "paragraph_line_stream" then
    local parsed, err = parse_paragraph_line_stream_from_lines(paragraph_lines_from_paragraphs(xml_text, true), requested_mode)
    return parsed or make_result(err, requested_mode, "paragraph_line_stream", false, PLAIN_TIMECODE_FORMAT_ID)
  end

  if xml_has_table(xml_text) then
    local table_result = parse_table_last(xml_path, requested_mode, options.header)
    if type(table_result) == "table" and table_result.message == "_Success_" and #table_result.rows > 0 then
      return table_result
    end
  end

  local line_stream_lines = paragraph_lines_from_paragraphs(xml_text, true)
  local line_stream_analysis = analyze_line_stream_shape(line_stream_lines)
  if line_stream_analysis.clearly_line_stream == true then
    local line_stream_result = parse_paragraph_line_stream_from_lines(line_stream_lines, requested_mode)
    if line_stream_result ~= nil then
      return line_stream_result
    end
  end

  local lines = nonempty_lines_from_paragraphs(xml_text)
  local start_end_result = parse_paragraph_start_end_from_lines(lines, requested_mode)
  if start_end_result ~= nil then
    return start_end_result
  end

  local line_stream_result = parse_paragraph_line_stream_from_lines(line_stream_lines, requested_mode)
  if line_stream_result ~= nil then
    return line_stream_result
  end

  if line_stream_analysis.timecode_count == 0 then
    return make_result(
      "no recognizable timecodes found; paragraph line-stream documents must contain timecode, character, dialogue records",
      requested_mode
    )
  end

  return make_result("no supported DOCX dialogue layout detected", requested_mode)
end

return DocxDialogueParser

