--
-- Name:        cmake_project.lua
-- Purpose:     Generate a cmake C/C++ project file.
-- Author:      Ryan Pusztai
-- Modified by: Andrea Zanellato
--              Manu Evans
--              Tom van Dijck
--              Yehonatan Ballas
--              Joel Linn
--              UndefinedVertex
--              Joris Dauphin
--              alchemyyy
-- Created:     2013/05/06
-- Copyright:   (c) 2008-2024 Jason Perkins and the Premake project
--

local p = premake
local tree = p.tree
local project = p.project
local config = p.config
local cmake = p.modules.cmake

cmake.project = {}
local m = cmake.project

-- CMake-native command token translations using ${CMAKE_COMMAND} -E
-- This replaces the platform-specific translations (copy, cp, xcopy, etc.)
-- with cross-platform CMake commands that work on all platforms.
local cmake_command_tokens = {
	chdir = function(v)
		return "${CMAKE_COMMAND} -E chdir " .. path.normalize(v)
	end,
	copy = function(v)
		return "${CMAKE_COMMAND} -E copy_directory " .. path.normalize(v)
	end,
	copyfile = function(v)
		return "${CMAKE_COMMAND} -E copy " .. path.normalize(v)
	end,
	copyfileifnewer = function(v)
		return "${CMAKE_COMMAND} -E copy_if_different " .. path.normalize(v)
	end,
	copydir = function(v)
		return "${CMAKE_COMMAND} -E copy_directory " .. path.normalize(v)
	end,
	delete = function(v)
		return "${CMAKE_COMMAND} -E rm -f " .. path.normalize(v)
	end,
	echo = function(v)
		return "${CMAKE_COMMAND} -E echo " .. v
	end,
	linkdir = function(v)
		return "${CMAKE_COMMAND} -E create_symlink " .. path.normalize(v)
	end,
	linkfile = function(v)
		return "${CMAKE_COMMAND} -E create_symlink " .. path.normalize(v)
	end,
	mkdir = function(v)
		return "${CMAKE_COMMAND} -E make_directory " .. path.normalize(v)
	end,
	move = function(v)
		return "${CMAKE_COMMAND} -E rename " .. path.normalize(v)
	end,
	rmdir = function(v)
		return "${CMAKE_COMMAND} -E rm -rf " .. path.normalize(v)
	end,
	touch = function(v)
		return "${CMAKE_COMMAND} -E touch " .. path.normalize(v)
	end,
}

function m.esc(s)
	if type(s) == "table" then
		return table.translate(s, m.esc)
	end
	s, _ = s:gsub('\\', '\\\\')
	s, _ = s:gsub('"', '\\"')
	return s
end

function m.unquote(s)
	if type(s) == "table" then
		return table.translate(s, m.unquote)
	end
	s, _ = s:gsub('"', '')
	return s
end


function m.quote(s) -- handle single quote: required for "old" version of cmake
	s, _ = premake.quote(s):gsub("'", " ")
	return s
end

function m.getcompiler(cfg)
	local default = iif(cfg.system == p.WINDOWS, "msc", "clang")
	local toolset, toolset_version = p.tools.canonical(_OPTIONS.cc or cfg.toolset or default)
	if not toolset then
		error("Invalid toolset '" + (_OPTIONS.cc or cfg.toolset) + "'")
	end
	return toolset
end

function m.files(cfg)
	local prj = cfg.project
	local files = {}

	table.foreachi(prj._.files, function(node)
		if node.excludefrombuild then
			return
		end
		local filecfg = p.fileconfig.getconfig(node, cfg)
		local rule = p.global.getRuleForFile(node.name, prj.rules)

		if p.fileconfig.hasFileSettings(filecfg) then
			if filecfg.compilebuildoutputs then
				for _, output in ipairs(filecfg.buildoutputs) do
					table.insert(files, string.format('%s', path.getrelative(prj.workspace.location, output)))
				end
			end
		elseif rule then
			local environ = table.shallowcopy(filecfg.environ)

			if rule.propertydefinition then
				p.rule.prepareEnvironment(rule, environ, cfg)
				p.rule.prepareEnvironment(rule, environ, filecfg)
			end
			local rulecfg = p.context.extent(rule, environ)
			for _, output in ipairs(rulecfg.buildoutputs) do
				table.insert(files, string.format('%s', path.getrelative(prj.workspace.location, output)))
			end
		elseif not node.generated then
			table.insert(files, string.format('%s', path.getrelative(prj.workspace.location, node.abspath)))
		end
	end)
	return files
end

local function is_empty(t)
	for _, _ in pairs(t) do
		return false
	end
	return true
end

local one_expression = "one_expression"
local table_expression = "table_expression"
local function generator_expression(prj, callback, mode)
	local common = nil
	local by_cfg = {}
	for cfg in project.eachconfig(prj) do
		local settings = callback(cfg)

		if not common then
			common = table.arraycopy(settings)
		else
			common = table.intersect(common, settings)
		end
		by_cfg[cfg] = settings
	end
	for cfg in project.eachconfig(prj) do
		by_cfg[cfg] = table.difference(by_cfg[cfg], common)
		if is_empty(by_cfg[cfg]) then
			by_cfg[cfg] = nil
		end
	end
	common_str = table.implode(common or {}, "", "", " ")
	if is_empty(by_cfg) then
		if mode == table_expression then
			return common, true
		else
			return common_str, true
		end
	end
	if #common_str > 0 then
		common_str = common_str .. " "
	end
	if mode == one_expression then
		local res = ''
		local suffix = ''
		for cfg, settings in pairs(by_cfg) do
			res = res .. string.format('$<IF:$<CONFIG:%s>,%s,', cmake.cfgname(cfg), m.esc(common_str .. table.implode(settings, "", "", " ")))
			suffix = suffix .. '>'
		end
		return res .. suffix, false
	else
		local res = {}
		for cfg, settings in pairs(by_cfg) do
			res = table.join(res, table.translate(settings, function(setting) return string.format('$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), m.esc(setting)) end))
		end
		if mode == table_expression then
			return table.join(common, res), false
		else
			return common_str .. table.implode(res, "", "", " "), false
		end
	end
end

local function generate_prebuild(prj)
	local prebuildcommands, same_output_by_cfg = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.prebuildmessage or #cfg.prebuildcommands > 0 then
			if cfg.prebuildmessage then
				table.insert(res, os.translateCommandsAndPaths("{ECHO} " .. m.quote(cfg.prebuildmessage), cfg.project.basedir, cfg.project.location, cmake_command_tokens))
			end
			res = table.join(res, os.translateCommandsAndPaths(cfg.prebuildcommands, cfg.project.basedir, cfg.project.location, cmake_command_tokens))
		end
		return res
	end, table_expression)
	if #prebuildcommands == 0 then
		return
	end
	local commands = {}
	if not same_output_by_cfg then
		for i, command in ipairs(prebuildcommands) do
			local variable_name = string.format("PREBUILD_COMMAND_%s_%i", prj.name, i)
			_p(0, 'SET(%s %s)', variable_name, command)
			commands[i] = '"${' .. variable_name .. '}"'
		end
	else
		commands = prebuildcommands
	end
	-- add_custom_command PRE_BUILD runs just before generating the target
	-- so instead, use add_custom_target to run it before any rule (as obj)
	_p(0, 'add_custom_target(prebuild-%s', prj.name)
	for _, command in ipairs(commands) do
		_p(1, 'COMMAND %s', command)
	end
	if not same_output_by_cfg then
		_p(1, 'COMMAND_EXPAND_LISTS')
	end
	_p(0, ')')
	_p(0, 'add_dependencies(%s prebuild-%s)', prj.name, prj.name)
end

local function generate_prelink(prj)
	local prelinkcommands, same_output_by_cfg = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.prelinkmessage or #cfg.prelinkcommands > 0 then
			if cfg.prelinkmessage then
				table.insert(res, os.translateCommandsAndPaths("{ECHO} " .. m.quote(cfg.prelinkmessage), cfg.project.basedir, cfg.project.location, cmake_command_tokens))
			end
			res = table.join(res, os.translateCommandsAndPaths(cfg.prelinkcommands, cfg.project.basedir, cfg.project.location, cmake_command_tokens))
		end
		return res
	end, table_expression)
	if #prelinkcommands == 0 then
		return
	end
	local commands = {}
	if not same_output_by_cfg then
		for i, command in ipairs(prelinkcommands) do
			local variable_name = string.format("PRELINK_COMMAND_%s_%i", prj.name, i)
			_p(0, 'SET(%s %s)', variable_name, command)
			commands[i] = '"${' .. variable_name .. '}"'
		end
	else
		commands = prelinkcommands
	end
	_p(0, 'add_custom_command(TARGET %s PRE_LINK', prj.name)
	for _, command in ipairs(commands) do
		_p(1, 'COMMAND %s', command)
	end
	if not same_output_by_cfg then
		_p(1, 'COMMAND_EXPAND_LISTS')
	end
	_p(0, ')')
end

local function generate_postbuild(prj)
	local postbuildcommands, same_output_by_cfg = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.postbuildmessage or #cfg.postbuildcommands > 0 then
			if cfg.postbuildmessage then
				table.insert(res, os.translateCommandsAndPaths("{ECHO} " .. m.quote(cfg.postbuildmessage), cfg.project.basedir, cfg.project.location, cmake_command_tokens))
			end
			res = table.join(res, os.translateCommandsAndPaths(cfg.postbuildcommands, cfg.project.basedir, cfg.project.location, cmake_command_tokens))
		end
		return res
	end, table_expression)
	if #postbuildcommands == 0 then
		return
	end
	local commands = {}
	if not same_output_by_cfg then
		for i, command in ipairs(postbuildcommands) do
			local variable_name = string.format("POSTBUILD_COMMAND_%i_%s", i, prj.name)
			_p(0, 'SET(%s %s)', variable_name, command)
			commands[i] = '"${' .. variable_name .. '}"'
		end
	else
		commands = postbuildcommands
	end

	_p(0, 'add_custom_command(TARGET %s POST_BUILD', prj.name)
	for _, command in ipairs(commands) do
		_p(1, 'COMMAND %s', command)
	end
	if not same_output_by_cfg then
		_p(1, 'COMMAND_EXPAND_LISTS')
	end
	_p(0, ')')
end

--
-- Project: Generate the cmake project file.
--
function m.generate(prj)
	p.utf8()
    
    -- if kind is only defined for configs, promote to project
    if prj.kind == nil then
        for cfg in project.eachconfig(prj) do
            prj.kind = cfg.kind
        end
    end

	if prj.kind == 'Utility' or prj.kind == 'None' then
		-- Generate a custom target for Utility/None projects
		local files = generator_expression(prj, m.files, table_expression)
		_p('add_custom_target("%s" SOURCES', prj.name)
		for _, file in ipairs(files) do
			_p(1, '%s', file)
		end
		_p(')')
		-- prebuild/postbuild still apply
		generate_prebuild(prj)
		generate_postbuild(prj)
		return
	end

	if prj.kind == 'SharedItems' then
		-- SharedItems are header-only / interface libraries
		local files = generator_expression(prj, m.files, table_expression)
		_p('add_library("%s" INTERFACE', prj.name)
		for _, file in ipairs(files) do
			_p(1, '%s', file)
		end
		_p(')')
		return
	end

	local oldGetDefaultSeparator = path.getDefaultSeparator
	path.getDefaultSeparator = function() return "/" end

	if prj.kind == 'StaticLib' then
		_p('add_library("%s" STATIC', prj.name)
	elseif prj.kind == 'SharedLib' then
		_p('add_library("%s" SHARED', prj.name)
	elseif prj.kind == 'Makefile' then
		-- Makefile projects become custom targets
		_p('add_custom_target("%s"', prj.name)
		for _, file in ipairs(generator_expression(prj, m.files, table_expression)) do
			_p(1, '%s', file)
		end
		_p(')')
		-- Makefile projects use buildcommands/rebuildcommands/cleancommands
		-- which are handled through pre/post build
		generate_prebuild(prj)
		generate_postbuild(prj)
		path.getDefaultSeparator = oldGetDefaultSeparator
		return
	else
		if prj.executable_suffix then
			_p('set(CMAKE_EXECUTABLE_SUFFIX "%s")', prj.executable_suffix)
		end
		-- WindowedApp gets the WIN32 flag for Windows subsystem
		if prj.kind == 'WindowedApp' then
			_p('add_executable("%s" WIN32', prj.name)
		else
			_p('add_executable("%s"', prj.name)
		end
	end
	for _, file in ipairs(generator_expression(prj, m.files, table_expression)) do
		_p(1, '%s', file);
	end
	_p(')')

	-- output name
	_p(0, 'set_target_properties("%s" PROPERTIES OUTPUT_NAME %s)', prj.name, generator_expression(prj, function(cfg) return {cfg.buildtarget.basename} end, one_expression))

	-- target prefix/suffix/extension overrides
	local targetprefix = generator_expression(prj, function(cfg)
		if cfg.targetprefix and cfg.targetprefix ~= "" then
			return {cfg.targetprefix}
		end
		return {}
	end, one_expression)
	if #targetprefix > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES PREFIX "%s")', prj.name, targetprefix)
	end
	--[[ Incompatible with premake-qt
	local targetsuffix = generator_expression(prj, function(cfg)
		if cfg.targetsuffix and cfg.targetsuffix ~= "" then
			return {cfg.targetsuffix}
		end
		return {}
	end, one_expression)
	if #targetsuffix > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES SUFFIX "%s")', prj.name, targetsuffix)
	end

	local targetextension = generator_expression(prj, function(cfg)
		if cfg.targetextension and cfg.targetextension ~= "" then
			return {cfg.targetextension}
		end
		return {}
	end, one_expression)
	if #targetextension > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES SUFFIX "%s")', prj.name, targetextension)
	end
    --]]

	-- output dir
	_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
 	for cfg in project.eachconfig(prj) do
		-- Multi-configuration generators appends a per-configuration subdirectory
		-- to the specified directory (unless a generator expression is used)
		-- for XXX_OUTPUT_DIRECTORY but not for XXX_OUTPUT_DIRECTORY_<CONFIG>
		_p(1, 'ARCHIVE_OUTPUT_DIRECTORY_%s "%s"', cmake.cfgname(cfg):upper(), path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
		_p(1, 'LIBRARY_OUTPUT_DIRECTORY_%s "%s"', cmake.cfgname(cfg):upper(), path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
		_p(1, 'RUNTIME_OUTPUT_DIRECTORY_%s "%s"', cmake.cfgname(cfg):upper(), path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
	end
	_p(0, ')')

	-- object directory (intermediate directory)
	local objdir = generator_expression(prj, function(cfg)
		if cfg.objdir then
			return {path.getrelative(prj.workspace.location, cfg.objdir)}
		end
		return {}
	end, one_expression)
	if #objdir > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
		for cfg in project.eachconfig(prj) do
			if cfg.objdir then
				_p(1, 'VS_INTERMEDIATE_DIRECTORY_%s "%s"', cmake.cfgname(cfg):upper(), path.getrelative(prj.workspace.location, cfg.objdir))
			end
		end
		_p(0, ')')
	end

	-- dependencies (from links)
	local dependencies = project.getdependencies(prj)
	if #dependencies > 0 then
		_p(0, 'add_dependencies("%s"', prj.name)
		for _, dependency in ipairs(dependencies) do
			_p(1, '"%s"', dependency.name)
		end
		_p(0,')')
	end

	-- dependson (non-linking build order dependencies)
	local dependson_list = generator_expression(prj, function(cfg)
		if cfg.dependson and #cfg.dependson > 0 then
			return cfg.dependson
		end
		return {}
	end, table_expression)
	if #dependson_list > 0 then
		_p(0, 'add_dependencies("%s"', prj.name)
		for _, dep in ipairs(dependson_list) do
			_p(1, '"%s"', dep)
		end
		_p(0, ')')
	end

	-- include dirs
	local externalincludedirs = generator_expression(prj, function(cfg) return cfg.externalincludedirs end, table_expression)
	if #externalincludedirs > 0 then
		_p(0, 'target_include_directories("%s" SYSTEM PRIVATE', prj.name)
		for _, dir in ipairs(externalincludedirs) do
			_p(1, '%s', dir)
		end
		_p(0, ')')
	end
	local includedirs = generator_expression(prj, function(cfg) return cfg.includedirs end, table_expression)
	if #includedirs > 0 then
		_p(0, 'target_include_directories("%s" PRIVATE', prj.name)
		for _, dir in ipairs(includedirs) do
			_p(1, '%s', dir)
		end
		_p(0, ')')
	end

	local msvc_frameworkdirs = generator_expression(prj, function(cfg) return p.tools.msc.getincludedirs(cfg, {}, {}, cfg.frameworkdirs, cfg.includedirsafter) end)
	local gcc_frameworkdirs = generator_expression(prj, function(cfg) return p.tools.gcc.getincludedirs(cfg, {}, {}, cfg.frameworkdirs, cfg.includedirsafter) end)

	if #msvc_frameworkdirs > 0 or #gcc_frameworkdirs > 0 then
		_p(0, 'if (MSVC)')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, msvc_frameworkdirs)
		_p(0, 'else()')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, gcc_frameworkdirs)
		_p(0, 'endif()')
	end

	local msvc_forceincludes = generator_expression(prj, function(cfg) return p.tools.msc.getforceincludes(cfg) end)
	local gcc_forceincludes = generator_expression(prj, function(cfg) return p.tools.gcc.getforceincludes(cfg) end)
	if #msvc_forceincludes > 0 or #gcc_forceincludes > 0 then
		_p(0, '# force include')
		_p(0, 'if (MSVC)')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, msvc_forceincludes)
		_p(0, 'else()')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, gcc_forceincludes)
		_p(0, 'endif()')
	end

	-- defines
	local defines = generator_expression(prj, function(cfg) return m.esc(cfg.defines) end, table_expression) --p.esc(define):gsub(' ', '\\ ')
	if #defines > 0 then
		_p(0, 'target_compile_definitions("%s" PRIVATE', prj.name)
		for _, define in ipairs(defines) do
			_p(1, '%s', define)
		end
		_p(0, ')')
	end

	local msvc_undefines = generator_expression(prj, function(cfg) return p.tools.msc.getundefines(cfg.undefines) end)
	local gcc_undefines = generator_expression(prj, function(cfg) return p.tools.gcc.getundefines(cfg.undefines) end)

	if #msvc_undefines > 0 or #gcc_undefines > 0 then
		_p(0, 'if (MSVC)')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, msvc_undefines)
		_p(0, 'else()')
		_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, gcc_undefines)
		_p(0, 'endif()')
	end

	-- character set defines
	local charset_defines = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.characterset == "Unicode" then
			table.insert(res, "UNICODE")
			table.insert(res, "_UNICODE")
		elseif cfg.characterset == "MBCS" then
			table.insert(res, "_MBCS")
		end
		return res
	end, table_expression)
	if #charset_defines > 0 then
		_p(0, 'target_compile_definitions("%s" PRIVATE', prj.name)
		for _, define in ipairs(charset_defines) do
			_p(1, '%s', define)
		end
		_p(0, ')')
	end

	-- setting build options
	local all_build_options = generator_expression(prj, function(cfg) return m.unquote(cfg.buildoptions) end, table_expression)
	if #all_build_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, option in ipairs(all_build_options) do
			_p(1, '%s', option)
		end
		_p(0, ')')
	end

	-- C++ standard
	local cppdialect = generator_expression(prj, function(cfg)
		if (cfg.cppdialect ~= nil and cfg.cppdialect ~= '') or cfg.cppdialect == 'Default' then
			local standard = {
				["C++98"] = 98,
				["C++0x"] = 11,
				["C++11"] = 11,
				["C++1y"] = 14,
				["C++14"] = 14,
				["C++1z"] = 17,
				["C++17"] = 17,
				["C++2a"] = 20,
				["C++20"] = 20,
				["C++2b"] = 23,
				["C++23"] = 23,
				["C++latest"] = 23,
				["gnu++98"] = 98,
				["gnu++0x"] = 11,
				["gnu++11"] = 11,
				["gnu++1y"] = 14,
				["gnu++14"] = 14,
				["gnu++1z"] = 17,
				["gnu++17"] = 17,
				["gnu++2a"] = 20,
				["gnu++20"] = 20,
				["gnu++2b"] = 23,
				["gnu++23"] = 23,
			}
			local val = standard[cfg.cppdialect]
			if val then
				return { tostring(val) }
			end
		end
		return {}
	end, one_expression)
	if #cppdialect > 0 then
		local extension = generator_expression(prj, function(cfg) return iif(cfg.cppdialect:find('^gnu') == nil, {'NO'}, {'YES'}) end, one_expression)
		_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
		_p(1, 'CXX_STANDARD %s', cppdialect)
		_p(1, 'CXX_STANDARD_REQUIRED YES')
		_p(1, 'CXX_EXTENSIONS %s', extension)
		_p(0, ')')
	end

	-- C standard
	local cdialect = generator_expression(prj, function(cfg)
		if cfg.cdialect ~= nil and cfg.cdialect ~= '' and cfg.cdialect ~= 'Default' then
			local standard = {
				["C89"] = 90,
				["C90"] = 90,
				["C99"] = 99,
				["C11"] = 11,
				["C17"] = 17,
				["C23"] = 23,
				["gnu89"] = 90,
				["gnu90"] = 90,
				["gnu99"] = 99,
				["gnu11"] = 11,
				["gnu17"] = 17,
				["gnu23"] = 23,
			}
			local val = standard[cfg.cdialect]
			if val then
				return { tostring(val) }
			end
		end
		return {}
	end, one_expression)
	if #cdialect > 0 then
		local c_extension = generator_expression(prj, function(cfg) return iif(cfg.cdialect and cfg.cdialect:find('^gnu') ~= nil, {'YES'}, {'NO'}) end, one_expression)
		_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
		_p(1, 'C_STANDARD %s', cdialect)
		_p(1, 'C_STANDARD_REQUIRED YES')
		_p(1, 'C_EXTENSIONS %s', c_extension)
		_p(0, ')')
	end

	-- Position Independent Code (independent of dialect)
	local pic = generator_expression(prj, function(cfg)
		if cfg.pic == 'On' then
			return {'True'}
		elseif cfg.pic == 'Off' then
			return {'False'}
		end
		return {}
	end, one_expression)
	if #pic > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES POSITION_INDEPENDENT_CODE %s)', prj.name, pic)
	end

	-- Link-Time Optimization (independent of dialect)
	local lto = generator_expression(prj, function(cfg)
		if cfg.linktimeoptimization and cfg.linktimeoptimization ~= "Off" and cfg.linktimeoptimization ~= "Default" then
			return {'True'}
		elseif cfg.linktimeoptimization == "Off" then
			return {'False'}
		end
		return {}
	end, one_expression)
	if #lto > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES INTERPROCEDURAL_OPTIMIZATION %s)', prj.name, lto)
	end

	-- compileas: force compilation language for source files
	local compileas = generator_expression(prj, function(cfg)
		if cfg.compileas == "C" then
			return {"C"}
		elseif cfg.compileas == "C++" then
			return {"CXX"}
		end
		return {}
	end, one_expression)
	if #compileas > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES LINKER_LANGUAGE %s)', prj.name, compileas)
	end

	-- MSVC runtime library
	local msvc_runtime = generator_expression(prj, function(cfg)
		local rt = ""
		if cfg.staticruntime == "On" then
			rt = "MultiThreaded"
		elseif cfg.staticruntime == "Off" or cfg.staticruntime == "Default" or cfg.staticruntime == nil then
			rt = "MultiThreadedDLL"
		else
			return {}
		end
		if cfg.runtime == "Debug" then
			rt = rt .. "Debug"
		end
		return {rt}
	end, one_expression)
	if #msvc_runtime > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES MSVC_RUNTIME_LIBRARY "%s")', prj.name, msvc_runtime)
	end

	-- Optimization
	local optimize_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.optimize then
			if cfg.optimize == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Od>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-O0>')
			elseif cfg.optimize == "On" or cfg.optimize == "Debug" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Og>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Og>')
			elseif cfg.optimize == "Size" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/O1>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Os>')
			elseif cfg.optimize == "Speed" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/O2>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-O2>')
			elseif cfg.optimize == "Full" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Ox>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-O3>')
			end
		end
		return res
	end, table_expression)
	if #optimize_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(optimize_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Debug symbols
	local symbols_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.symbols then
			if cfg.symbols == "On" or cfg.symbols == "Full" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Zi>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-g>')
			elseif cfg.symbols == "FastLink" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/ZI>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-g>')
			elseif cfg.symbols == "Off" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-g0>')
			end
		end
		return res
	end, table_expression)
	if #symbols_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(symbols_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Debug format (SplitDwarf etc.)
	local debugformat_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.debugformat then
			if cfg.debugformat == "SplitDwarf" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-gsplit-dwarf>')
			elseif cfg.debugformat == "Dwarf" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-gdwarf>')
			elseif cfg.debugformat == "c7" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Z7>')
			end
		end
		return res
	end, table_expression)
	if #debugformat_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(debugformat_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Warnings
	local warnings_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.warnings then
			if cfg.warnings == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/W0>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>')
			elseif cfg.warnings == "Default" then
				-- default, no flags needed
			elseif cfg.warnings == "High" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/W4>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall>')
			elseif cfg.warnings == "Extra" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/W4>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wextra>')
			elseif cfg.warnings == "Everything" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Wall>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Weverything>')
			end
		end
		return res
	end, table_expression)
	if #warnings_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(warnings_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- External warnings (for system/external includes)
	local externalwarnings_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.externalwarnings then
			if cfg.externalwarnings == "Off" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wno-system-headers>')
			elseif cfg.externalwarnings == "Default" then
				-- default, no flags needed
			elseif cfg.externalwarnings == "High" or cfg.externalwarnings == "Extra" or cfg.externalwarnings == "Everything" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wsystem-headers>')
			end
		end
		return res
	end, table_expression)
	if #externalwarnings_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(externalwarnings_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Enable/disable specific warnings
	local enablewarnings_opts = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.enablewarnings and #cfg.enablewarnings > 0 then
			for _, w in ipairs(cfg.enablewarnings) do
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/w1' .. w .. '>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-W' .. w .. '>')
			end
		end
		return res
	end, table_expression)
	if #enablewarnings_opts > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(enablewarnings_opts) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	local disablewarnings_opts = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.disablewarnings and #cfg.disablewarnings > 0 then
			for _, w in ipairs(cfg.disablewarnings) do
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/wd' .. w .. '>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wno-' .. w .. '>')
			end
		end
		return res
	end, table_expression)
	if #disablewarnings_opts > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(disablewarnings_opts) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Fatal warnings (treat warnings as errors)
	local fatalwarnings_opts = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.fatalwarnings and #cfg.fatalwarnings > 0 then
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/WX>')
			table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Werror>')
		end
		return res
	end, table_expression)
	if #fatalwarnings_opts > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(fatalwarnings_opts) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- RTTI
	local rtti_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.rtti then
			if cfg.rtti == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/GR->')
				table.insert(res, '$<$<AND:$<NOT:$<CXX_COMPILER_ID:MSVC>>,$<COMPILE_LANGUAGE:CXX>>:-fno-rtti>')
			elseif cfg.rtti == "On" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/GR>')
				table.insert(res, '$<$<AND:$<NOT:$<CXX_COMPILER_ID:MSVC>>,$<COMPILE_LANGUAGE:CXX>>:-frtti>')
			end
		end
		return res
	end, table_expression)
	if #rtti_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(rtti_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Exception handling
	local exceptions_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.exceptionhandling then
			if cfg.exceptionhandling == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/EHs-c->')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fno-exceptions>')
			elseif cfg.exceptionhandling == "On" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/EHsc>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fexceptions>')
			elseif cfg.exceptionhandling == "SEH" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/EHa>')
			elseif cfg.exceptionhandling == "CThrow" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/EHsc>')
			end
		end
		return res
	end, table_expression)
	if #exceptions_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(exceptions_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Floating point model
	local floatingpoint_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.floatingpoint then
			if cfg.floatingpoint == "Fast" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/fp:fast>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-ffast-math>')
			elseif cfg.floatingpoint == "Strict" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/fp:strict>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-ffloat-store>')
			end
		end
		return res
	end, table_expression)
	if #floatingpoint_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(floatingpoint_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Symbol visibility
	local visibility_val = generator_expression(prj, function(cfg)
		if cfg.visibility then
			local vis_map = {
				["Default"] = "default",
				["Hidden"] = "hidden",
				["Internal"] = "internal",
				["Protected"] = "protected",
			}
			local v = vis_map[cfg.visibility]
			if v then
				return {v}
			end
		end
		return {}
	end, one_expression)
	if #visibility_val > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
		_p(1, 'C_VISIBILITY_PRESET %s', visibility_val)
		_p(1, 'CXX_VISIBILITY_PRESET %s', visibility_val)
		_p(0, ')')
	end

	-- Inline visibility
	local inlinesvisibility_val = generator_expression(prj, function(cfg)
		if cfg.inlinesvisibility == "Hidden" then
			return {"YES"}
		end
		return {}
	end, one_expression)
	if #inlinesvisibility_val > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES VISIBILITY_INLINES_HIDDEN %s)', prj.name, inlinesvisibility_val)
	end

	-- Omit frame pointer
	local omitframepointer_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.omitframepointer then
			if cfg.omitframepointer == "On" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Oy>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fomit-frame-pointer>')
			elseif cfg.omitframepointer == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Oy->')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fno-omit-frame-pointer>')
			end
		end
		return res
	end, table_expression)
	if #omitframepointer_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(omitframepointer_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Unsigned char
	local unsignedchar_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.unsignedchar then
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/J>')
			table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-funsigned-char>')
		end
		return res
	end, table_expression)
	if #unsignedchar_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(unsignedchar_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- OpenMP
	local openmp_options = generator_expression(prj, function(cfg)
		if cfg.openmp == "On" then
			return {"$<$<CXX_COMPILER_ID:MSVC>:/openmp>", "$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fopenmp>"}
		end
		return {}
	end, table_expression)
	if #openmp_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(openmp_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Struct member alignment
	local structmemberalign_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.structmemberalign then
			local val = tostring(cfg.structmemberalign)
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/Zp' .. val .. '>')
			table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fpack-struct=' .. val .. '>')
		end
		return res
	end, table_expression)
	if #structmemberalign_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(structmemberalign_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Buffer security check
	local buffersecuritycheck_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.buffersecuritycheck then
			if cfg.buffersecuritycheck == "On" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/GS>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fstack-protector>')
			elseif cfg.buffersecuritycheck == "Off" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/GS->')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fno-stack-protector>')
			end
		end
		return res
	end, table_expression)
	if #buffersecuritycheck_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(buffersecuritycheck_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Strict aliasing
	local strictaliasing_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.strictaliasing then
			if cfg.strictaliasing == "Off" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fno-strict-aliasing>')
			elseif cfg.strictaliasing == "Level1" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fstrict-aliasing>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wstrict-aliasing=1>')
			elseif cfg.strictaliasing == "Level2" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fstrict-aliasing>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wstrict-aliasing=2>')
			elseif cfg.strictaliasing == "Level3" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fstrict-aliasing>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wstrict-aliasing=3>')
			end
		end
		return res
	end, table_expression)
	if #strictaliasing_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(strictaliasing_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Edit and Continue
	local editandcontinue_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.editandcontinue == "On" then
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/ZI>')
		elseif cfg.editandcontinue == "Off" then
			-- default, no special flag needed
		end
		return res
	end, table_expression)
	if #editandcontinue_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(editandcontinue_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Multi-processor compilation
	local multiprocessor_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.multiprocessorcompile == "On" then
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/MP>')
		end
		return res
	end, table_expression)
	if #multiprocessor_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(multiprocessor_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Vector extensions
	local vectorext_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.vectorextensions then
			local ext = cfg.vectorextensions
			if ext == "AVX" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/arch:AVX>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-mavx>')
			elseif ext == "AVX2" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/arch:AVX2>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-mavx2>')
			elseif ext == "SSE" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/arch:SSE>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-msse>')
			elseif ext == "SSE2" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/arch:SSE2>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-msse2>')
			elseif ext == "SSE3" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-msse3>')
			elseif ext == "SSSE3" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-mssse3>')
			elseif ext == "SSE4.1" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-msse4.1>')
			elseif ext == "SSE4.2" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-msse4.2>')
			elseif ext == "IA32" then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/arch:IA32>')
			elseif ext == "ALTIVEC" then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-maltivec>')
			end
		end
		return res
	end, table_expression)
	if #vectorext_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(vectorext_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- ISA extensions
	local isaext_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.isaextensions and #cfg.isaextensions > 0 then
			local isa_map = {
				["MOVBE"] = "-mmovbe",
				["POPCNT"] = "-mpopcnt",
				["PCLMUL"] = "-mpclmul",
				["LZCNT"] = "-mlzcnt",
				["BMI"] = "-mbmi",
				["BMI2"] = "-mbmi2",
				["F16C"] = "-mf16c",
				["AES"] = "-maes",
				["FMA"] = "-mfma",
				["FMA4"] = "-mfma4",
				["RDRND"] = "-mrdrnd",
				["SHA"] = "-msha",
			}
			for _, ext in ipairs(cfg.isaextensions) do
				local flag = isa_map[ext]
				if flag then
					table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:' .. flag .. '>')
				end
			end
		end
		return res
	end, table_expression)
	if #isaext_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(isaext_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- CFLAGS/CXXFLAGS from toolset
	local msvc_cflags = generator_expression(prj, function(cfg) return table.translate(p.tools.msc.getcflags(cfg), function(s) return string.format('$<$<COMPILE_LANG_AND_ID:C,MSVC>:%s>', s) end) end, table_expression)
	local msvc_cxxflags = generator_expression(prj, function(cfg) return table.translate(p.tools.msc.getcxxflags(cfg), function(s) return string.format('$<$<COMPILE_LANG_AND_ID:CXX,MSVC>:%s>', s) end) end, table_expression)
	local gcc_cflags = generator_expression(prj, function(cfg) return table.translate(p.tools.gcc.getcflags(cfg), function(s) return string.format('$<$<AND:$<NOT:$<C_COMPILER_ID:MSVC>>,$<COMPILE_LANGUAGE:C>>:%s>', s) end) end, table_expression)
	local gcc_cxxflags = generator_expression(prj, function(cfg) return table.translate(p.tools.gcc.getcxxflags(cfg), function(s) return string.format('$<$<AND:$<NOT:$<CXX_COMPILER_ID:MSVC>>,$<COMPILE_LANGUAGE:CXX>>:%s>', s) end) end, table_expression)

	if #msvc_cflags > 0 or #msvc_cxxflags > 0 or #gcc_cflags > 0 or #gcc_cxxflags > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, flag in ipairs(msvc_cflags) do
			_p(1, flag)
		end
		for _, flag in ipairs(msvc_cxxflags) do
			_p(1, flag)
		end
		for _, flag in ipairs(gcc_cflags) do
			_p(1, flag)
		end
		for _, flag in ipairs(gcc_cxxflags) do
			_p(1, flag)
		end
		_p(0, ')')
	end

	-- lib dirs
	local libdirs = generator_expression(prj, function(cfg) return cfg.libdirs end, table_expression)
	if #libdirs > 0 then
		_p(0, 'target_link_directories("%s" PRIVATE', prj.name)
		for _, libdir in ipairs(libdirs) do
			_p(1, '"%s"', libdir)
		end
		_p(0, ')')
	end

	-- system library dirs
	local syslibdirs = generator_expression(prj, function(cfg)
		if cfg.syslibdirs and #cfg.syslibdirs > 0 then
			return cfg.syslibdirs
		end
		return {}
	end, table_expression)
	if #syslibdirs > 0 then
		_p(0, 'target_link_directories("%s" PRIVATE', prj.name)
		for _, libdir in ipairs(syslibdirs) do
			_p(1, '"%s"', libdir)
		end
		_p(0, ')')
	end

	-- libs
	local libs = generator_expression(prj, function(cfg)
		local toolset = m.getcompiler(cfg)
		local isclangorgcc = toolset == p.tools.clang or toolset == p.tools.gcc
		local uselinkgroups = isclangorgcc and cfg.linkgroups == p.ON
		local res = {}
		if uselinkgroups or #config.getlinks(cfg, "dependencies", "object") > 0 or #config.getlinks(cfg, "system", "fullpath") > 0 then
			-- Do not use toolset here as cmake needs to resolve dependency chains
			if uselinkgroups then
				table.insert(res, '-Wl,--start-group')
			end
			for a, link in ipairs(config.getlinks(cfg, "dependencies", "object")) do
				table.insert(res, link.project.name)
			end
			if uselinkgroups then
				-- System libraries don't depend on the project
				table.insert(res, '-Wl,--end-group')
				table.insert(res, '-Wl,--start-group')
			end
			for _, link in ipairs(config.getlinks(cfg, "system", "fullpath")) do
				table.insert(res, link)
			end
			if uselinkgroups then
				table.insert(res, '-Wl,--end-group')
			end
			return res
		end
		return {}
	end, table_expression)
	if #libs > 0 then
		_p(0, 'target_link_libraries("%s"', prj.name)
		for _, lib in ipairs(libs) do
			_p(1, '%s', lib)
		end
		_p(0, ')')
	end

	-- setting link options
	local all_link_options = generator_expression(prj, function(cfg)
		local toolset = m.getcompiler(cfg)
		return table.join(toolset.getldflags(cfg), cfg.linkoptions) end, table_expression)
	if #all_link_options > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		for _, link_option in ipairs(all_link_options) do
			_p(1, '%s', link_option)
		end
		_p(0, ')')
	end

	-- Linker fatal warnings
	local linkerfatalwarnings_opts = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.linkerfatalwarnings and #cfg.linkerfatalwarnings > 0 then
			table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/WX>')
			table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wl,--fatal-warnings>')
		end
		return res
	end, table_expression)
	if #linkerfatalwarnings_opts > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(linkerfatalwarnings_opts) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Linker selection (LLD)
	local linker_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.linker == "LLD" then
			table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fuse-ld=lld>')
		end
		return res
	end, table_expression)
	if #linker_options > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(linker_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- OpenMP link libraries
	local openmp_link_options = generator_expression(prj, function(cfg)
		if cfg.openmp == "On" then
			return {"$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fopenmp>"}
		end
		return {}
	end, table_expression)
	if #openmp_link_options > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(openmp_link_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Sanitizer link options (expanded to cover all sanitizer types)
	local sanitize_link_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.sanitize and #cfg.sanitize ~= 0 then
			if table.contains(cfg.sanitize, "Address") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=address>')
			end
			if table.contains(cfg.sanitize, "Fuzzer") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=fuzzer>')
			end
			if table.contains(cfg.sanitize, "Thread") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=thread>')
			end
			if table.contains(cfg.sanitize, "UndefinedBehavior") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=undefined>')
			end
		end
		return res
	end, table_expression)
	if #sanitize_link_options > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(sanitize_link_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- Sanitizer compile options
	local sanitize_compile_options = generator_expression(prj, function(cfg)
		local res = {}
		if cfg.sanitize and #cfg.sanitize ~= 0 then
			if table.contains(cfg.sanitize, "Address") then
				table.insert(res, '$<$<CXX_COMPILER_ID:MSVC>:/fsanitize=address>')
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=address>')
			end
			if table.contains(cfg.sanitize, "Fuzzer") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=fuzzer>')
			end
			if table.contains(cfg.sanitize, "Thread") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=thread>')
			end
			if table.contains(cfg.sanitize, "UndefinedBehavior") then
				table.insert(res, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-fsanitize=undefined>')
			end
		end
		return res
	end, table_expression)
	if #sanitize_compile_options > 0 then
		_p(0, 'target_compile_options("%s" PRIVATE', prj.name)
		for _, opt in ipairs(sanitize_compile_options) do
			_p(1, '%s', opt)
		end
		_p(0, ')')
	end

	-- RPATH / runpath directories
	local runpathdirs = generator_expression(prj, function(cfg)
		if cfg.runpathdirs and #cfg.runpathdirs > 0 then
			return cfg.runpathdirs
		end
		return {}
	end, table_expression)
	if #runpathdirs > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES', prj.name)
		_p(1, 'INSTALL_RPATH "%s"', table.implode(runpathdirs, "", "", ";"))
		_p(1, 'BUILD_WITH_INSTALL_RPATH TRUE')
		_p(0, ')')
	end

	-- Entry point
	local entrypoint = generator_expression(prj, function(cfg)
		if cfg.entrypoint and cfg.entrypoint ~= "" then
			return {cfg.entrypoint}
		end
		return {}
	end, one_expression)
	if #entrypoint > 0 then
		_p(0, 'target_link_options("%s" PRIVATE', prj.name)
		_p(1, '$<$<CXX_COMPILER_ID:MSVC>:/ENTRY:%s>', entrypoint)
		_p(1, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-e>')
		_p(1, '$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:%s>', entrypoint)
		_p(0, ')')
	end

	-- System version (Windows SDK version)
	local systemversion = generator_expression(prj, function(cfg)
		if cfg.systemversion and cfg.systemversion ~= "" then
			return {cfg.systemversion}
		end
		return {}
	end, one_expression)
	if #systemversion > 0 then
		_p(0, 'set_target_properties("%s" PROPERTIES VS_WINDOWS_TARGET_PLATFORM_VERSION "%s")', prj.name, systemversion)
	end

	-- precompiled headers
	local pch = generator_expression(prj, function(cfg)
		-- copied from gmake2_cpp.lua
		if cfg.enablepch ~= p.OFF and cfg.pchheader then
			local pch = cfg.pchheader
			local found = false

			-- test locally in the project folder first (this is the most likely location)
			local testname = path.join(cfg.project.basedir, pch)
			if os.isfile(testname) then
				pch = project.getrelative(cfg.project, testname)
				found = true
			else
				-- else scan in all include dirs.
				for _, incdir in ipairs(cfg.includedirs) do
					testname = path.join(incdir, pch)
					if os.isfile(testname) then
						pch = project.getrelative(cfg.project, testname)
						found = true
						break
					end
				end
			end

			if not found then
				pch = project.getrelative(cfg.project, path.getabsolute(pch))
			end
			return {pch}
		end
		return {}
	end, one_expression)
	if pch ~= "" then
		_p(0, 'target_precompile_headers("%s" PUBLIC %s)', prj.name, pch)
	end

	-- prebuild commands
	generate_prebuild(prj)

	-- prelink commands
	generate_prelink(prj)

	-- postbuild commands
	generate_postbuild(prj)

	-- custom command
--	local custom_output_directories_by_cfg = {}
	local custom_commands_by_filename = {}

	local function addCustomCommand(cfg, fileconfig, filename)
		if #fileconfig.buildcommands == 0 or #fileconfig.buildoutputs == 0 then
			return
		end
--[[
		custom_output_directories_by_cfg[cfg] = custom_output_directories_by_cfg[cfg] or {}
		custom_output_directories_by_cfg[cfg] = table.join(custom_output_directories_by_cfg[cfg], table.translate(fileconfig.buildoutputs, function(output) return project.getrelative(prj, path.getdirectory(output)) end))
--]]
		custom_commands_by_filename[filename] = custom_commands_by_filename[filename] or {}
		custom_commands_by_filename[filename][cfg] = custom_commands_by_filename[filename][cfg] or {}
		custom_commands_by_filename[filename][cfg]["outputs"] = project.getrelative(cfg.project, fileconfig.buildoutputs)
		custom_commands_by_filename[filename][cfg]["commands"] = {}
		custom_commands_by_filename[filename][cfg]["depends"] = {}
		custom_commands_by_filename[filename][cfg]["compilebuildoutputs"] = fileconfig.compilebuildoutputs

		if fileconfig.buildmessage then
			table.insert(custom_commands_by_filename[filename][cfg]["commands"], os.translateCommandsAndPaths('{ECHO} ' .. m.quote(fileconfig.buildmessage), cfg.project.basedir, cfg.project.location, cmake_command_tokens))
		end
		for _, command in ipairs(fileconfig.buildcommands) do
			table.insert(custom_commands_by_filename[filename][cfg]["commands"], os.translateCommandsAndPaths(command, cfg.project.basedir, cfg.project.location, cmake_command_tokens))
		end
		if filename ~= "" then
			table.insert(custom_commands_by_filename[filename][cfg]["depends"], filename)
		end
		custom_commands_by_filename[filename][cfg]["depends"] = table.join(custom_commands_by_filename[filename][cfg]["depends"], fileconfig.buildinputs)
	end
	local tr = project.getsourcetree(prj)
	p.tree.traverse(tr, {
		onleaf = function(node, depth)
			for cfg in project.eachconfig(prj) do
				local filecfg = p.fileconfig.getconfig(node, cfg)
				local rule = p.global.getRuleForFile(node.name, prj.rules)

				if p.fileconfig.hasFileSettings(filecfg) then
					addCustomCommand(cfg, filecfg, node.relpath)
				elseif rule then
					local environ = table.shallowcopy(filecfg.environ)

					if rule.propertydefinition then
						p.rule.prepareEnvironment(rule, environ, cfg)
						p.rule.prepareEnvironment(rule, environ, filecfg)
					end
					local rulecfg = p.context.extent(rule, environ)
					addCustomCommand(cfg, rulecfg, node.relpath)
				end
			end
		end
	})

--[[
	local custom_output_directories = generator_expression(prj, function(cfg) return table.difference(table.unique(custom_output_directories_by_cfg[cfg]), {"."}) end, table_expression)
	if not is_empty(custom_output_directories) then
		-- Alternative would be to add 'COMMAND ${CMAKE_COMMAND} -E make_directory %s' to below add_custom_command
		_p(0, '# Custom output directories')
		_p(0, 'file(MAKE_DIRECTORY')
		for _, dir in ipairs(custom_output_directories) do
			_p(1, '%s', dir)
		end
		_p(0, ')')
	end
--]]
	for filename, custom_ouput_by_cfg in pairs(custom_commands_by_filename) do
		--local custom_outputs_directories = generator_expression(prj, function(cfg)
		--		return table.difference(table.unique(project.getrelative(prj, table.translate(custom_ouput_by_cfg[cfg]["outputs"], path.getdirectory))), {".", ""})
		--	end, table_expression)
		local _, same_output_by_cfg = generator_expression(prj, function(cfg) return custom_ouput_by_cfg[cfg]["outputs"] end, table_expression)
		--local custom_commands = generator_expression(prj, function(cfg) return custom_ouput_by_cfg[cfg]["commands"] end, table_expression)
		--local depends = generator_expression(prj, function(cfg) return custom_ouput_by_cfg[cfg]["depends"] end, table_expression)

		for cfg in project.eachconfig(prj) do
			_p(0, 'add_custom_command(OUTPUT %s', table.implode(custom_ouput_by_cfg[cfg]["outputs"], "", "", " "))
			custom_outputs_directories = table.difference(table.unique(project.getrelative(prj, table.translate(custom_ouput_by_cfg[cfg]["outputs"], path.getdirectory))), {".", ""})
			if not is_empty(custom_outputs_directories) then
				_p(1, 'COMMAND ${CMAKE_COMMAND} -E make_directory %s', table.implode(custom_outputs_directories, "", "", " "))
			end
			for _, command in ipairs(custom_ouput_by_cfg[cfg]["commands"]) do
				_p(1, 'COMMAND %s', command)
			end
			for _, dep in ipairs(custom_ouput_by_cfg[cfg]["depends"]) do
				_p(1, 'DEPENDS %s', dep)
			end

			_p(0, ')')
			if same_output_by_cfg then break end
		end

		--local custom_target_by_cfg = {}
		for cfg in project.eachconfig(prj) do
			if not custom_ouput_by_cfg[cfg]["compilebuildoutputs"] then
				local config_prefix = (same_output_by_cfg and "") or cmake.cfgname(cfg) .. '_'
				local target_name = 'CUSTOM_TARGET_' .. config_prefix .. filename:gsub('/', '_'):gsub('\\', '_')
				--custom_target_by_cfg[cfg] = target_name
				_p(0, 'add_custom_target(%s DEPENDS %s)', target_name, table.implode(custom_ouput_by_cfg[cfg]["outputs"],"",""," "))

				_p(0, 'add_dependencies(%s %s)', prj.name, target_name)
				if same_output_by_cfg then break end
			end
		end
		--[[ add_dependencies doesn't support generator expression :/
		local custom_dependencies = generator_expression(prj, function(cfg) return {custom_target_by_cfg[cfg]} end, table_expression)
		_p(0, 'add_dependencies(%s', prj.name)
		for _, target in ipairs(custom_dependencies) do
			_p(1, '%s', target)
		end
		_p(0, ')')
		--]]
	end
	_p('')
-- restore
	path.getDefaultSeparator = oldGetDefaultSeparator
end
