-- @noindex
-- Minimal DOCX XML last-table parser for ReaScript projects.
-- Public entry point:
-- DocxXmlParser.parse_docx_xml(path_to_valid_docx_xml, header)

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local Files = require("modules.Files")
local Util = require("modules.Util")

local DocxXmlParser = {}

local function make_result(message, header_requested)
  local result = {
    message = tostring(message or ""),
    number_of_columns = 0,
    number_of_rows = 0,
    rows = {}
  }
  if header_requested then
    result.header = {}
  end
  return result
end

local function make_failure_result(message, header_requested)
  return make_result(message, header_requested)
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

local function find_last_table_span(xml_text)
  local table_stack = {}
  local last_start = nil
  local last_stop = nil

  for tag_start, tag_body, next_pos in xml_text:gmatch("()<([^>]+)>()") do
    local name, is_closing, is_self_closing = parse_tag_descriptor(tag_body)
    if name == "w:tbl" then
      if is_closing then
        local open_start = table_stack[#table_stack]
        if not open_start then
          return nil, "malformed XML: unexpected closing w:tbl"
        end
        table_stack[#table_stack] = nil
        last_start = open_start
        last_stop = next_pos - 1
      elseif not is_self_closing then
        table_stack[#table_stack + 1] = tag_start
      else
        last_start = tag_start
        last_stop = next_pos - 1
      end
    end
  end

  if #table_stack > 0 then
    return nil, "malformed XML: unclosed w:tbl"
  end
  if not last_start or not last_stop then
    return nil, "no w:tbl found in XML"
  end

  return last_start, last_stop
end

local function parse_last_table_block(table_text)
  local rows = {}
  local max_columns = 0
  local core_stack = {}

  local current_row = nil
  local current_cell_parts = nil
  local cell_seen_paragraph = false

  local table_depth = 0
  local run_depth = 0
  local in_text = false
  local cursor = 1

  local function push_core(tag_name)
    core_stack[#core_stack + 1] = tag_name
  end

  local function pop_core(expected)
    local actual = core_stack[#core_stack]
    if actual ~= expected then
      return false, ("malformed XML: unexpected closing %s"):format(expected)
    end
    core_stack[#core_stack] = nil
    return true
  end

  local function append_to_cell(text)
    if current_cell_parts == nil then return end
    current_cell_parts[#current_cell_parts + 1] = tostring(text or "")
  end

  local function finish_cell()
    if current_row == nil then
      return nil, "malformed XML: w:tc closed outside w:tr"
    end
    local cell_text = Util.trim(table.concat(current_cell_parts or {}))
    current_row[#current_row + 1] = cell_text
    current_cell_parts = nil
    cell_seen_paragraph = false
    return true
  end

  for tag_start, tag_body, next_pos in table_text:gmatch("()<([^>]+)>()") do
    if in_text and tag_start > cursor then
      append_to_cell(table_text:sub(cursor, tag_start - 1))
    end

    local name, is_closing, is_self_closing = parse_tag_descriptor(tag_body)
    local active_table_depth = table_depth

    if name == "w:tbl" then
      if is_closing then
        if table_depth < 1 then
          return nil, nil, "malformed XML: unexpected closing w:tbl"
        end
        table_depth = table_depth - 1
      elseif not is_self_closing then
        table_depth = table_depth + 1
      end
    elseif active_table_depth == 1 and name ~= nil then
      if name == "w:tr" then
        if is_closing then
          local ok, err = pop_core("w:tr")
          if not ok then return nil, nil, err end
          if current_row == nil then
            return nil, nil, "malformed XML: w:tr closed without active row"
          end
          rows[#rows + 1] = current_row
          if #current_row > max_columns then
            max_columns = #current_row
          end
          current_row = nil
        elseif not is_self_closing then
          if current_row ~= nil then
            return nil, nil, "malformed XML: nested w:tr is not supported"
          end
          current_row = {}
          push_core("w:tr")
        end
      elseif name == "w:tc" then
        if is_closing then
          local ok, err = pop_core("w:tc")
          if not ok then return nil, nil, err end
          local ok_finish, finish_err = finish_cell()
          if not ok_finish then return nil, nil, finish_err end
        elseif not is_self_closing then
          if current_row == nil then
            return nil, nil, "malformed XML: w:tc opened outside w:tr"
          end
          if current_cell_parts ~= nil then
            return nil, nil, "malformed XML: nested w:tc is not supported"
          end
          current_cell_parts = {}
          cell_seen_paragraph = false
          push_core("w:tc")
        end
      elseif name == "w:p" then
        if is_closing then
          local ok, err = pop_core("w:p")
          if not ok then return nil, nil, err end
        elseif not is_self_closing and current_cell_parts ~= nil then
          if cell_seen_paragraph then
            append_to_cell("\n")
          end
          cell_seen_paragraph = true
          push_core("w:p")
        end
      elseif name == "w:r" then
        if is_closing then
          if run_depth > 0 then
            run_depth = run_depth - 1
          end
        elseif not is_self_closing and current_cell_parts ~= nil then
          run_depth = run_depth + 1
        end
      elseif name == "w:t" then
        if is_closing then
          local ok, err = pop_core("w:t")
          if not ok then return nil, nil, err end
          in_text = false
        elseif not is_self_closing and current_cell_parts ~= nil then
          push_core("w:t")
          in_text = true
        end
      elseif name == "w:tab" then
        if not is_closing and current_cell_parts ~= nil and run_depth > 0 then
          append_to_cell(" ")
        end
      elseif name == "w:br" or name == "w:cr" then
        if not is_closing and current_cell_parts ~= nil and run_depth > 0 then
          append_to_cell("\n")
        end
      end
    end

    cursor = next_pos
  end

  if in_text and cursor <= #table_text then
    append_to_cell(table_text:sub(cursor))
  end

  if table_depth ~= 0 then
    return nil, nil, "malformed XML: unclosed w:tbl in selected table"
  end
  if current_cell_parts ~= nil then
    return nil, nil, "malformed XML: unclosed w:tc in selected table"
  end
  if current_row ~= nil then
    return nil, nil, "malformed XML: unclosed w:tr in selected table"
  end
  if #core_stack > 0 then
    return nil, nil, "malformed XML: unclosed core tag " .. tostring(core_stack[#core_stack])
  end

  return rows, max_columns, nil
end

local function pad_rows(rows, target_columns)
  for i = 1, #rows do
    local row = rows[i]
    for j = #row + 1, target_columns do
      row[j] = ""
    end
  end
end

function DocxXmlParser.parse_docx_xml(path_to_valid_docx_xml, header)
  if type(path_to_valid_docx_xml) ~= "string" then
    return make_failure_result("path_to_valid_docx_xml must be a string", header)
  end

  local xml_path = Util.trim(path_to_valid_docx_xml)
  if xml_path == "" then
    return make_failure_result("path_to_valid_docx_xml must be a non-empty string", header)
  end

  local xml_text, read_info = Files.slurp_with_cap(xml_path)
  if type(xml_text) ~= "string" then
    return make_failure_result("failed to read XML file: " .. tostring(read_info or "unknown error"), header)
  end

  local table_start, table_stop_or_err = find_last_table_span(xml_text)
  if not table_start then
    return make_failure_result(table_stop_or_err, header)
  end

  local table_text = xml_text:sub(table_start, table_stop_or_err)
  local rows, max_columns, parse_err = parse_last_table_block(table_text)
  if not rows then
    return make_failure_result(parse_err, header)
  end

  pad_rows(rows, max_columns)

  local result = {
    message = "_Success_",
    number_of_columns = max_columns,
    number_of_rows = 0,
    rows = rows
  }

  if header then
    result.header = {}
    if rows[1] ~= nil then
      result.header = rows[1]
      table.remove(rows, 1)
    end
  end

  result.number_of_rows = #rows
  return result
end

return DocxXmlParser

