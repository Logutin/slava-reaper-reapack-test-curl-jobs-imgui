-- @noindex
-- Shared UTF-8 text helpers for ReaScript modules.
--
-- Public entry points:
-- Utf8Tools.lower(text)
--
-- Current scope:
-- - simple Unicode lowercase only, based on UnicodeData simple one-to-one
--   lowercase mappings
-- - reusable across modules
--
-- Intentionally out of scope in this module for now:
-- - full Unicode casefolding
-- - locale-sensitive casing
-- - context-sensitive special casing

if not reaper then
  error("This module is intended to be used in ReaScript from Reaper, but 'reaper' global variable is not found.")
end

local Utf8SimpleLowerData = require("modules.Utf8SimpleLowerData")

local Utf8Tools = {}

function Utf8Tools.lower(text)
  local source = tostring(text or "")
  local length, err_pos = utf8.len(source)
  if length == nil then
    return nil, "invalid UTF-8 sequence at byte " .. tostring(err_pos)
  end

  if length == 0 then
    return "", nil
  end

  local chars = {}
  for _, codepoint in utf8.codes(source) do
    local mapped = Utf8SimpleLowerData[codepoint] or codepoint
    chars[#chars + 1] = utf8.char(mapped)
  end

  return table.concat(chars), nil
end

return Utf8Tools
