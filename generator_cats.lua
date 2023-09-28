local function sorted_entries(t)
  local tmp = {}
  for k in pairs(t) do
    tmp[#tmp + 1] = k
  end
  table.sort(tmp)
  return tmp
end

------------------
-- cdef.lua
------------------
local cparser = require "cparser.cparser"

local tmpfile = io.tmpfile()
cparser.cpp("cimgui/cimgui.h", tmpfile, { "-U__GNUC__", "-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS" })

tmpfile:seek "set"
local data = tmpfile:read "*all"
tmpfile:close()

local cdef = {
  'require("ffi").cdef[[',
  data:gsub("#.-\n", ""),
  "]]",
}

------------------
-- cimgui.lua
------------------
local cats = {}

cats[#cats + 1] = [[
---@meta 
---cimgui-love https://github.com/apicici/cimgui-love
---https://luals.github.io/wiki/annotations/

---@class cimgui
---@field love table]]

local defs = require "cimgui.generator.output.definitions"
local classes = {}
local functions = {}
local ignored_defaults = {}
local overloads = {}

for _, k in ipairs(sorted_entries(defs)) do
  local t = defs[k]
  for _, s in ipairs(t) do
    -- flag pointer arguments that are meant as outputs and list them separately as well
    -- flag if the function has va_list arguments
    s.in_argsT, s.out_argsT = {}, {}
    for _, arg in ipairs(s.argsT) do
      s.va_list = s.va_list or arg.type == "va_list"
      if arg.name:match "^out_" or arg.name:match "^out$" or arg.name:match "^pOut" then
        arg.out = true
        table.insert(s.out_argsT, arg)
      else
        table.insert(s.in_argsT, arg)
      end
    end

    if not s.templated and not s.va_list then
      --ignore templates and va_list functions
      if s.stname ~= "" then
        --check if we're working with a class
        local class_name = s.stname
        classes[class_name] = classes[class_name] or { constructors = {}, methods = {} }
        local c = classes[class_name]

        if s.constructor then
          table.insert(c.constructors, s)
        elseif s.destructor then
          c.destructor = s
        else
          table.insert(c.methods, s)
        end
      else
        table.insert(functions, s)
      end
    end
  end
end

local defaults_patterns = { -- in the order they should be tried
  { [[^(".*")$]], "%1" }, -- string
  { [[^%+?(%-?%d*%.?%d*)f?$]], "%1" }, -- number
  { [[^FLT_MAX$]], "%1" }, -- FLT_MAX
  { [[^FLT_MIN$]], "%1" }, -- FLT_MIN
  { [[^sizeof%((%w+)%)$]], [[ffi.sizeof("%1")]] }, -- sizeof
  { [[^true$]], "%1" }, -- true
  { [[^false$]], "%1" }, -- false
  { [[^ImVec2%(%+?(%-?%d*%.?%d*)f?,%+?(%-?%d*%.?%d*)f?%)$]], "M.ImVec2_Float(%1, %2)" }, -- ImVec2
  { [[^ImVec2%(%+?(%-?FLT_MIN)f?,%+?(%-?%d*%.?%d*)f?%)$]], "M.ImVec2_Float(%1, %2)" }, -- ImVec2 & FLT_MIN
  {
    [[^ImVec4%(%+?(%-?%d*%.?%d*)f?,%+?(%-?%d*%.?%d*)f?,%+?(%-?%d*%.?%d*)f?,%+?(%-?%d*%.?%d*)f?%)$]],
    "M.ImVec4_Float(%1, %2, %3, %4)",
  }, -- ImVec4
}

local function add_defaults(t, strings_table)
  for i, arg in ipairs(t.in_argsT) do
    local d = t.defaults[arg.name]
    local substitution
    if d then
      for _, x in ipairs(defaults_patterns) do
        if d:match(x[1]) then
          substitution = d:gsub(x[1], x[2])
          break
        end
      end
      if substitution then
        strings_table[#strings_table + 1] = string.format("    if i%d == nil then i%d = %s end", i, i, substitution)
      elseif d ~= "NULL" then
        ignored_defaults[#ignored_defaults + 1] = string.format([[%s: %s=%s]], t.ov_cimguiname, arg.name, d)
      end
    end
  end
end

local cats_type_map = {
  ["const char*"] = "string",
  ["void"] = "",
  ["bool"] = "boolean",
}

local function cats_arguments_string(t)
  local args = {}
  for i, a in ipairs(t.in_argsT) do
    args[i] = a.name .. ": " .. (cats_type_map[a.type] or "any")
  end
  return table.concat(args, ", ")
end

local function cats_ret_string(t)
  return cats_type_map[t.ret]
end

for _, f in ipairs(functions) do
  local s = string.format("---@field %s fun(%s)", f.ov_cimguiname:gsub("^ig", ""), cats_arguments_string(f))
  local r = cats_ret_string(f)
  if r and #r > 0 then
    s = s .. ": " .. r
  end
  table.insert(cats, s)
end

------------------
-- enums.lua
------------------
local structs_and_enums = require "cimgui.generator.output.structs_and_enums"

table.insert(cats, 'local M={}')
for _, k in ipairs(sorted_entries(structs_and_enums.enums)) do
  local t = structs_and_enums.enums[k]
  for _, s in ipairs(t) do
    table.insert(cats, string.format("M.%s = %d", s.name, s.calc_value))
  end
end
table.insert(cats, 'return M')

print "src/cimgui.lua"
local f = assert(io.open("src/cimgui.lua", "w"))
f:write(table.concat(cats, "\n"))
f:close()
