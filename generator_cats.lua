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
local cparser = require("cparser.cparser")

local tmpfile = io.tmpfile()
cparser.cpp("cimgui/cimgui.h", tmpfile, { "-U__GNUC__", "-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS" })

tmpfile:seek("set")
local data = tmpfile:read("*all")
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

---@class cimgui]]

local defs = require("cimgui.generator.output.definitions")
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
			if arg.name:match("^out_") or arg.name:match("^out$") or arg.name:match("^pOut") then
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

local templates = {}

templates.class_begin = [[
local &name& = &name& or {}
&name&.__index = &name&]]

templates.class_overloaded_constructor = [[M.&shortconstructor& = M.&shortconstructor&  or function(&args&)
    jit.off(true)
    local p = C.&constructor&(&args&)
    return ffi.gc(p[0], C.&destructor&)
end]]

templates.class_single_constructor = [[local mt = getmetatable(&name&) or {}
mt.__call = mt.__call or function(&callargs&)
    jit.off(true)
    local p = C.&constructor&(&args&)
    return ffi.gc(p[0], C.&destructor&)
end
setmetatable(&name&, mt)]]

templates.class_method_begin = [[&name&["&shortmethod&"] = &name&["&shortmethod&"]  or function(&wrapargs&)
    jit.off(true)]] -- ["key"] instead of .key since in some cases shortmethod=end

templates.class_method_begin_fix_end = [[&name&.c_end = &name&["end"] ]]

templates.method_or_function_end = [[    local out = C.&function&(&allargs&)
    return &outargs&
end]]

templates.class_end = [[M.&name& = &name&
ffi.metatype("&name&", &name&)
]]

templates.function_begin = [[M.&shortfunction& = M.&shortfunction&  or function(&wrapargs&)
    jit.off(true)]]

templates.out_arg = [[    local &arg& = ffi.new("&type&[1]")]]

templates.texture_id = [[    local ptr = ffi.cast("void *", &arg&)
    _common.textures[tostring(ptr)] = &arg&
    &arg& = ptr]]

templates.drawcallback = [[    if not ffi.istype("ImDrawCallback", &arg&) then
        local str = tostring(&arg&)
        _common.callbacks[str] = &arg&
        i2 = ffi.cast("ImDrawCallback", str)
    end]]

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
				strings_table[#strings_table + 1] =
					string.format("    if i%d == nil then i%d = %s end", i, i, substitution)
			elseif d ~= "NULL" then
				ignored_defaults[#ignored_defaults + 1] = string.format([[%s: %s=%s]], t.ov_cimguiname, arg.name, d)
			end
		end
	end
end

local function wrap_arguments_string(t)
	local args = {}
	for i, a in ipairs(t.in_argsT) do
		args[i] = a.type == "..." and "..." or string.format("i%d", i)
	end
	return table.concat(args, ", ")
end

local function all_arguments_string(t)
	local args = {}
	local num_outputs = 0
	for i, a in ipairs(t.argsT) do
		if a.out then
			num_outputs = num_outputs + 1
			args[i] = string.format("o%d", num_outputs)
		else
			args[i] = a.type == "..." and "..." or string.format("i%d", i - num_outputs)
		end
	end
	return table.concat(args, ", ")
end

local function out_args_string(t)
	local args = {}
	for i = 1, #t.out_argsT do
		args[i] = string.format("o%d[0]", i)
	end
	args[#args + 1] = "out"
	return table.concat(args, ", ")
end

-- for _, name in ipairs(sorted_entries(classes)) do
-- 	local class = classes[name]
-- 	cats[#cats + 1] = templates.class_begin:gsub("&name&", name)
-- 	for _, m in ipairs(class.methods) do
-- 		local shortmethod = m.ov_cimguiname:gsub("^" .. name .. "_", "")
-- 		cats[#cats + 1] = templates.class_method_begin:gsub("&%w+&", {
-- 			["&name&"] = name,
-- 			["&shortmethod&"] = shortmethod,
-- 			["&wrapargs&"] = wrap_arguments_string(m),
-- 		})
-- 		add_defaults(m, cats)
-- 		for i, arg in ipairs(m.in_argsT) do
-- 			if arg.type == "ImTextureID" then
-- 				cats[#cats + 1] = templates.texture_id:gsub("&arg&", string.format("i%d", i))
-- 			elseif arg.type == "ImDrawCallback" then
-- 				cats[#cats + 1] = templates.drawcallback:gsub("&arg&", string.format("i%d", i))
-- 			end
-- 		end
-- 		for i, arg in ipairs(m.out_argsT) do
-- 			cats[#cats + 1] = templates.out_arg:gsub("&%w+&", {
-- 				["&arg&"] = string.format("o%d", i),
-- 				["&type&"] = arg.type:gsub("%*$", ""),
-- 			})
-- 		end
-- 		cats[#cats + 1] = templates.method_or_function_end:gsub("&%w+&", {
-- 			["&allargs&"] = all_arguments_string(m),
-- 			["&function&"] = m.ov_cimguiname,
-- 			["&outargs&"] = out_args_string(m),
-- 		})
-- 		if shortmethod == "end" then
-- 			cats[#cats + 1] = templates.class_method_begin_fix_end:gsub("&name&", name)
-- 		end
-- 	end

-- 	if #class.constructors == 1 then
-- 		local c = class.constructors[1]
-- 		local args = wrap_arguments_string(c)
-- 		cats[#cats + 1] = templates.class_single_constructor:gsub("&%w+&", {
-- 			["&name&"] = name,
-- 			["&constructor&"] = c.ov_cimguiname,
-- 			["&destructor&"] = class.destructor.ov_cimguiname,
-- 			["&callargs&"] = table.concat({ "self", args ~= "" and args or nil }, ", "),
-- 			["&args&"] = args,
-- 		})
-- 	elseif #class.constructors > 1 then
-- 		overloads[#overloads + 1] = name
-- 		for i, c in ipairs(class.constructors) do
-- 			overloads[#overloads + 1] = string.format("    %s%s", c.ov_cimguiname:gsub("^" .. name .. "_", ""), c.args)
-- 			cats[#cats + 1] = templates.class_overloaded_constructor:gsub("&%w+&", {
-- 				["&shortconstructor&"] = c.ov_cimguiname:gsub("^" .. name .. "_", ""),
-- 				["&constructor&"] = c.ov_cimguiname,
-- 				["&destructor&"] = class.destructor.ov_cimguiname,
-- 				["&args&"] = wrap_arguments_string(c),
-- 			})
-- 		end
-- 		overloads[#overloads + 1] = ""
-- 	end
-- 	cats[#cats + 1] = templates.class_end:gsub("&name&", name)
-- end

local overloaded_functions = {}

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
	local s = string.format("---@field %s fun(%s)", f.cimguiname:gsub("^ig", ""), cats_arguments_string(f))
	local r = cats_ret_string(f)
	if r and #r > 0 then
		s = s .. ": " .. r
	end
	table.insert(cats, s)

	-- if f.cimguiname ~= f.ov_cimguiname then
	-- 	local shortname = f.cimguiname:gsub("^ig", "")
	-- 	if not overloads[shortname] then
	-- 		overloads[shortname] = {}
	-- 		table.insert(overloaded_functions, shortname)
	-- 	end
	-- 	table.insert(overloads[shortname], string.format("    %s%s", f.ov_cimguiname:gsub("^ig", ""), f.args))
	-- end
	-- cats[#cats + 1] = templates.function_begin:gsub("&%w+&", {
	-- 	["&shortfunction&"] = f.ov_cimguiname:gsub("^ig", ""),
	-- 	["&wrapargs&"] = wrap_arguments_string(f),
	-- })
	-- add_defaults(f, cats)
	-- for i, arg in ipairs(f.in_argsT) do
	-- 	if arg.type == "ImTextureID" then
	-- 		cats[#cats + 1] = templates.texture_id:gsub("&arg&", string.format("i%d", i))
	-- 	elseif arg.type == "ImDrawCallback" then
	-- 		cats[#cats + 1] = templates.drawcallback:gsub("&arg&", string.format("i%d", i))
	-- 	end
	-- end
	-- for i, arg in ipairs(f.out_argsT) do
	-- 	cats[#cats + 1] = templates.out_arg:gsub("&%w+&", {
	-- 		["&arg&"] = string.format("o%d", i),
	-- 		["&type&"] = arg.type:gsub("%*$", ""),
	-- 	})
	-- end
	-- cats[#cats + 1] = templates.method_or_function_end:gsub("&%w+&", {
	-- 	["&allargs&"] = all_arguments_string(f),
	-- 	["&function&"] = f.ov_cimguiname,
	-- 	["&outargs&"] = out_args_string(f),
	-- })
end

print("src/cimgui.lua")
local f = assert(io.open("src/cimgui.lua", "w"))
f:write(table.concat(cats, "\n"))
f:close()

------------------
-- enums.lua
------------------
local structs_and_enums = require("cimgui.generator.output.structs_and_enums")

local enums = {}
enums[1] = [[local path = (...):gsub("[^%.]*$", "")
local M = require(path .. "master")
]]

for _, k in ipairs(sorted_entries(structs_and_enums.enums)) do
	local t = structs_and_enums.enums[k]
	for _, s in ipairs(t) do
		enums[#enums + 1] = string.format("M.%s = %d", s.name, s.calc_value)
	end
end
