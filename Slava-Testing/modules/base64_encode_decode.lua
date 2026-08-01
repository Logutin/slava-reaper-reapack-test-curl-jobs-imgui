-- @noindex
-- Minimal base64/base64url codec for Lua 5.4.
-- JWT payloads are base64url and often omit '=' padding.
-- This is encode/decode only. For JWT security, signature validation is separate (not part of this module).

local M = {}

local ALPH_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ALPH_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function build_decoder(alphabet)
  local decoder = {}
  for i = 1, #alphabet do
    decoder[alphabet:byte(i)] = i - 1
  end
  return decoder
end

local DEC_STD = build_decoder(ALPH_STD)
local DEC_URL = build_decoder(ALPH_URL)

local function pad_to_4(text)
  local remainder = #text % 4
  if remainder == 0 then
    return text
  end
  if remainder == 1 then
    return nil, "invalid base64 length"
  end
  return text .. string.rep("=", 4 - remainder)
end

local function encode_with_alphabet(data, alphabet, include_padding)
  local input = tostring(data or "")
  local out = {}

  for i = 1, #input, 3 do
    local a = input:byte(i) or 0
    local b = input:byte(i + 1)
    local c = input:byte(i + 2)
    local value = (a << 16) | ((b or 0) << 8) | (c or 0)

    out[#out + 1] = alphabet:sub(((value >> 18) & 0x3F) + 1, ((value >> 18) & 0x3F) + 1)
    out[#out + 1] = alphabet:sub(((value >> 12) & 0x3F) + 1, ((value >> 12) & 0x3F) + 1)

    if b == nil then
      out[#out + 1] = include_padding and "=" or ""
      out[#out + 1] = include_padding and "=" or ""
    elseif c == nil then
      out[#out + 1] = alphabet:sub(((value >> 6) & 0x3F) + 1, ((value >> 6) & 0x3F) + 1)
      out[#out + 1] = include_padding and "=" or ""
    else
      out[#out + 1] = alphabet:sub(((value >> 6) & 0x3F) + 1, ((value >> 6) & 0x3F) + 1)
      out[#out + 1] = alphabet:sub((value & 0x3F) + 1, (value & 0x3F) + 1)
    end
  end

  return table.concat(out)
end

local function decode_with_decoder(text, decoder, allow_no_padding)
  local input = tostring(text or ""):gsub("%s+", "")
  if allow_no_padding then
    local padded, pad_err = pad_to_4(input)
    if not padded then
      return nil, pad_err
    end
    input = padded
  end

  if (#input % 4) ~= 0 then
    return nil, "invalid base64 length"
  end

  local out = {}
  for i = 1, #input, 4 do
    local c1 = input:byte(i)
    local c2 = input:byte(i + 1)
    local c3 = input:byte(i + 2)
    local c4 = input:byte(i + 3)
    if not c1 or not c2 or not c3 or not c4 then
      return nil, "invalid base64 block"
    end

    local v1 = decoder[c1]
    local v2 = decoder[c2]
    if v1 == nil or v2 == nil then
      return nil, "invalid base64 character"
    end

    local pad = 0
    local v3, v4

    if c3 == 61 then
      if c4 ~= 61 then
        return nil, "invalid padding"
      end
      pad = 2
      v3, v4 = 0, 0
    else
      v3 = decoder[c3]
      if v3 == nil then
        return nil, "invalid base64 character"
      end

      if c4 == 61 then
        pad = 1
        v4 = 0
      else
        v4 = decoder[c4]
        if v4 == nil then
          return nil, "invalid base64 character"
        end
      end
    end

    local value = (v1 << 18) | (v2 << 12) | (v3 << 6) | v4
    out[#out + 1] = string.char((value >> 16) & 0xFF)
    if pad < 2 then
      out[#out + 1] = string.char((value >> 8) & 0xFF)
    end
    if pad < 1 then
      out[#out + 1] = string.char(value & 0xFF)
    end
  end

  return table.concat(out)
end

function M.encode_std(data)
  return encode_with_alphabet(data, ALPH_STD, true)
end

function M.decode_std(text)
  return decode_with_decoder(text, DEC_STD, false)
end

function M.encode_url(data, no_padding)
  return encode_with_alphabet(data, ALPH_URL, not no_padding)
end

function M.decode_url(text)
  return decode_with_decoder(text, DEC_URL, true)
end

return M

