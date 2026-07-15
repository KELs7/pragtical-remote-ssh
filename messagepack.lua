local mp = {}

local function is_array(t)
  if next(t) == nil then return true end -- Treat empty tables as arrays
  local i = 1
  for _ in pairs(t) do
    if t[i] == nil then return false end
    i = i + 1
  end
  return true
end

function mp.pack(v)
  local t = type(v)
  if t == "nil" then
    return string.pack("B", 0xc0)
  elseif t == "boolean" then
    return string.pack("B", v and 0xc3 or 0xc2)
  elseif t == "number" then
    if v == math.floor(v) then
      if v >= 0 then
        if v <= 127 then
          return string.pack("B", v)
        elseif v <= 255 then
          return string.pack("BB", 0xcc, v)
        elseif v <= 65535 then
          return string.pack(">BI2", 0xcd, v)
        else
          return string.pack(">BI4", 0xce, v)
        end
      else
        if v >= -32 then
          return string.pack("b", v)
        elseif v >= -128 then
          return string.pack("Bb", 0xd0, v)
        elseif v >= -32768 then
          return string.pack(">Bi2", 0xd1, v)
        else
          return string.pack(">Bi4", 0xd2, v)
        end
      end
    else
      return string.pack(">Bd", 0xcb, v)
    end
  elseif t == "string" then
    local len = #v
    if len <= 31 then
      return string.pack("B", 0xa0 + len) .. v
    elseif len <= 255 then
      return string.pack("BB", 0xd9, len) .. v
    elseif len <= 65535 then
      return string.pack(">BI2", 0xda, len) .. v
    else
      return string.pack(">BI4", 0xdb, len) .. v
    end
  elseif t == "table" then
    if is_array(v) then
      local len = #v
      local header
      if len <= 15 then
        header = string.pack("B", 0x90 + len)
      elseif len <= 65535 then
        header = string.pack(">BI2", 0xdc, len)
      else
        header = string.pack(">BI4", 0xdd, len)
      end
      local parts = {header}
      for _, item in ipairs(v) do
        table.insert(parts, mp.pack(item))
      end
      return table.concat(parts)
    else
      local len = 0
      for _ in pairs(v) do len = len + 1 end
      local header
      if len <= 15 then
        header = string.pack("B", 0x80 + len)
      elseif len <= 65535 then
        header = string.pack(">BI2", 0xde, len)
      else
        header = string.pack(">BI4", 0xdf, len)
      end
      local parts = {header}
      for k, val in pairs(v) do
        table.insert(parts, mp.pack(tostring(k)))
        table.insert(parts, mp.pack(val))
      end
      return table.concat(parts)
    end
  else
    error("unsupported serialization type: " .. t)
  end
end

function mp.unpack(str, offset)
  offset = offset or 1
  if offset > #str then return nil, offset end
  
  local byte = string.unpack("B", str, offset)
  offset = offset + 1
  
  if byte <= 0x7f then
    return byte, offset
  end
  
  if byte >= 0x80 and byte <= 0x8f then
    local len = byte - 0x80
    local map = {}
    for _ = 1, len do
      local k, v
      k, offset = mp.unpack(str, offset)
      v, offset = mp.unpack(str, offset)
      map[k] = v
    end
    return map, offset
  end
  
  if byte >= 0x90 and byte <= 0x9f then
    local len = byte - 0x90
    local arr = {}
    for i = 1, len do
      local v
      v, offset = mp.unpack(str, offset)
      arr[i] = v
    end
    return arr, offset
  end
  
  if byte >= 0xa0 and byte <= 0xbf then
    local len = byte - 0xa0
    if len == 0 then return "", offset end
    local s = str:sub(offset, offset + len - 1)
    return s, offset + len
  end
  
  if byte == 0xc0 then return nil, offset end
  if byte == 0xc2 then return false, offset end
  if byte == 0xc3 then return true, offset end
  
  if byte == 0xca then
    local v = string.unpack(">f", str, offset)
    return v, offset + 4
  end
  if byte == 0xcb then
    local v = string.unpack(">d", str, offset)
    return v, offset + 8
  end
  
  if byte == 0xcc then
    local v = string.unpack("B", str, offset)
    return v, offset + 1
  end
  if byte == 0xcd then
    local v = string.unpack(">I2", str, offset)
    return v, offset + 2
  end
  if byte == 0xce then
    local v = string.unpack(">I4", str, offset)
    return v, offset + 4
  end
  
  if byte == 0xd0 then
    local v = string.unpack("b", str, offset)
    return v, offset + 1
  end
  if byte == 0xd1 then
    local v = string.unpack(">i2", str, offset)
    return v, offset + 2
  end
  if byte == 0xd2 then
    local v = string.unpack(">i4", str, offset)
    return v, offset + 4
  end
  
  if byte == 0xd9 then
    local len = string.unpack("B", str, offset)
    offset = offset + 1
    return str:sub(offset, offset + len - 1), offset + len
  end
  if byte == 0xda then
    local len = string.unpack(">I2", str, offset)
    offset = offset + 2
    return str:sub(offset, offset + len - 1), offset + len
  end
  if byte == 0xdb then
    local len = string.unpack(">I4", str, offset)
    offset = offset + 4
    return str:sub(offset, offset + len - 1), offset + len
  end
  
  if byte == 0xdc then
    local len = string.unpack(">I2", str, offset)
    offset = offset + 2
    local arr = {}
    for i = 1, len do
      local v
      v, offset = mp.unpack(str, offset)
      arr[i] = v
    end
    return arr, offset
  end
  if byte == 0xdd then
    local len = string.unpack(">I4", str, offset)
    offset = offset + 4
    local arr = {}
    for i = 1, len do
      local v
      v, offset = mp.unpack(str, offset)
      arr[i] = v
    end
    return arr, offset
  end
  
  if byte == 0xde then
    local len = string.unpack(">I2", str, offset)
    offset = offset + 2
    local map = {}
    for _ = 1, len do
      local k, v
      k, offset = mp.unpack(str, offset)
      v, offset = mp.unpack(str, offset)
      map[k] = v
    end
    return map, offset
  end
  if byte == 0xdf then
    local len = string.unpack(">I4", str, offset)
    offset = offset + 4
    local map = {}
    for _ = 1, len do
      local k, v
      k, offset = mp.unpack(str, offset)
      v, offset = mp.unpack(str, offset)
      map[k] = v
    end
    return map, offset
  end
  
  if byte >= 0xe0 then
    return byte - 256, offset
  end
  
  error("unsupported binary serialization byte: " .. string.format("0x%02x", byte))
end

return mp