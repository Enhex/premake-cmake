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
-- Created:     2013/05/06
-- Copyright:   (c) 2008-2020 Jason Perkins and the Premake project
--

local p = premake
local tree = p.tree
local project = p.project
local config = p.config
local cmake = p.modules.cmake

cmake.project = {}
local m = cmake.project


function m.getcompiler(cfg)
	local default = iif(cfg.system == p.WINDOWS, "msc", "clang")
	local toolset = p.tools[_OPTIONS.cc or cfg.toolset or default]
	if not toolset then
		error("Invalid toolset '" + (_OPTIONS.cc or cfg.toolset) + "'")
	end
	return toolset
end

function m.files(prj)
	local tr = project.getsourcetree(prj)
	tree.traverse(tr, {
		onleaf = function(node, depth)
		
			_p(depth, '"%s"', path.getrelative(prj.workspace.location, node.abspath))

			-- add generated files
			for cfg in project.eachconfig(prj) do
				local filecfg = p.fileconfig.getconfig(node, cfg)
				local rule = p.global.getRuleForFile(node.name, prj.rules)

				if p.fileconfig.hasFileSettings(filecfg) then
					for _, output in ipairs(filecfg.buildoutputs) do
						_p(depth, '"%s"', path.getrelative(prj.workspace.location, output))
					end
					break
				elseif rule then
					local environ = table.shallowcopy(filecfg.environ)

					if rule.propertydefinition then
						p.rule.prepareEnvironment(rule, environ, cfg)
						p.rule.prepareEnvironment(rule, environ, filecfg)
					end
					local rulecfg = p.context.extent(rule, environ)
					for _, output in ipairs(rulecfg.buildoutputs) do
						_p(depth, '"%s"', path.getrelative(prj.workspace.location, output))
					end
					break
				end
			end
		end
	})
end

--
-- Project: Generate the cmake project file.
--
function m.generate(prj)
	p.utf8()

	if prj.kind == 'Utility' then
		return
	end

	local oldGetDefaultSeparator = path.getDefaultSeparator
	path.getDefaultSeparator = function() return "/" end


	if prj.kind == 'StaticLib' then
		_p('add_library("%s" STATIC', prj.name)
	elseif prj.kind == 'SharedLib' then
		_p('add_library("%s" SHARED', prj.name)
	else
		if prj.executable_suffix then
			_p('set(CMAKE_EXECUTABLE_SUFFIX "%s")', prj.executable_suffix)
		end
		_p('add_executable("%s"', prj.name)
	end
	m.files(prj)
	_p(')')

	for cfg in project.eachconfig(prj) do
		local toolset = m.getcompiler(cfg)
		local isclangorgcc = toolset == p.tools.clang or toolset == p.tools.gcc
		_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cmake.cfgname(cfg))
		-- dependencies
		local dependencies = project.getdependencies(prj)
		if #dependencies > 0 then
			_p(1, 'add_dependencies("%s"', prj.name)
			for _, dependency in ipairs(dependencies) do
				_p(2, '"%s"', dependency.name)
			end
			_p(1,')')
		end

		-- output dir
		_p(1,'set_target_properties("%s" PROPERTIES', prj.name)
		_p(2, 'OUTPUT_NAME "%s"', cfg.buildtarget.basename)
		_p(2, 'ARCHIVE_OUTPUT_DIRECTORY "%s"', path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
		_p(2, 'LIBRARY_OUTPUT_DIRECTORY "%s"', path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
		_p(2, 'RUNTIME_OUTPUT_DIRECTORY "%s"', path.getrelative(prj.workspace.location, cfg.buildtarget.directory))
		_p(1,')')
		_p('endif()')

		-- include dirs

		if #cfg.externalincludedirs > 0 then
			_p('target_include_directories("%s" SYSTEM PRIVATE', prj.name)
			for _, includedir in ipairs(cfg.externalincludedirs) do
				_x(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), includedir)
			end
			_p(')')
		end
		if #cfg.includedirs > 0 then
			_p('target_include_directories("%s" PRIVATE', prj.name)
			for _, includedir in ipairs(cfg.includedirs) do
				_x(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), includedir)
			end
			_p(')')
		end

		if #cfg.forceincludes > 0 then
			_p('if (MSVC)')
			_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, table.implode(p.tools.msc.getforceincludes(cfg), "", "", " "))
			_p('else()')
			_p(1, 'target_compile_options("%s" PRIVATE %s)', prj.name, table.implode(p.tools.gcc.getforceincludes(cfg), "", "", " "))
			_p('endif()')
		end

		-- defines
		if #cfg.defines > 0 then
			_p('target_compile_definitions("%s" PRIVATE', prj.name)
			for _, define in ipairs(cfg.defines) do
				_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), p.esc(define):gsub(' ', '\\ '))
			end
			_p(')')
		end

		-- lib dirs
		if #cfg.libdirs > 0 then
			_p('target_link_directories("%s" PRIVATE', prj.name)
			for _, libdir in ipairs(cfg.libdirs) do
				_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), libdir)
			end
			_p(')')
		end

		-- libs
		local uselinkgroups = isclangorgcc and cfg.linkgroups == p.ON
		if uselinkgroups or # config.getlinks(cfg, "dependencies", "object") > 0 or #config.getlinks(cfg, "system", "fullpath") > 0 then
			_p('target_link_libraries("%s"', prj.name)
			-- Do not use toolset here as cmake needs to resolve dependency chains
			if uselinkgroups then
				_p(1, '-Wl,--start-group')
			end
			for a, link in ipairs(config.getlinks(cfg, "dependencies", "object")) do
				_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), link.project.name)
			end
			if uselinkgroups then
				-- System libraries don't depend on the project
				_p(1, '-Wl,--end-group')
				_p(1, '-Wl,--start-group')
			end
			for _, link in ipairs(config.getlinks(cfg, "system", "fullpath")) do
				_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), link)
			end
			if uselinkgroups then
				_p(1, '-Wl,--end-group')
			end
			_p(')')
		end

		-- setting build options
		all_build_options = ""
		for _, option in ipairs(cfg.buildoptions) do
			all_build_options = all_build_options .. option .. " "
		end
		
		if all_build_options ~= "" then
			_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cmake.cfgname(cfg))
			_p(1, 'set_target_properties("%s" PROPERTIES COMPILE_FLAGS %s)', prj.name, all_build_options)
			_p('endif()')
		end

		-- setting link options
		all_link_options = ""
		for _, option in ipairs(cfg.linkoptions) do
			all_link_options = all_link_options .. option .. " "
		end

		if all_link_options ~= "" then
			_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cmake.cfgname(cfg))
			_p(1, 'set_target_properties("%s" PROPERTIES LINK_FLAGS "%s")', prj.name, all_link_options)
			_p('endif()')
		end
		
		if #toolset.getcflags(cfg) > 0 or #toolset.getcxxflags(cfg) > 0 then
			_p('target_compile_options("%s" PRIVATE', prj.name)

			for _, flag in ipairs(toolset.getcflags(cfg)) do
				_p(1, '$<$<AND:$<CONFIG:%s>,$<COMPILE_LANGUAGE:C>>:%s>', cmake.cfgname(cfg), flag)
			end
			for _, flag in ipairs(toolset.getcxxflags(cfg)) do
				_p(1, '$<$<AND:$<CONFIG:%s>,$<COMPILE_LANGUAGE:CXX>>:%s>', cmake.cfgname(cfg), flag)
			end
			_p(')')
		end

		-- C++ standard
		-- only need to configure it specified
		if (cfg.cppdialect ~= nil and cfg.cppdialect ~= '') or cfg.cppdialect == 'Default' then
			local standard = {}
			standard["C++98"] = 98
			standard["C++11"] = 11
			standard["C++14"] = 14
			standard["C++17"] = 17
			standard["C++20"] = 20
			standard["gnu++98"] = 98
			standard["gnu++11"] = 11
			standard["gnu++14"] = 14
			standard["gnu++17"] = 17
			standard["gnu++20"] = 20

			local extentions = iif(cfg.cppdialect:find('^gnu') == nil, 'NO', 'YES')
			local pic = iif(cfg.pic == 'On', 'True', 'False')
			local lto = iif(cfg.flags.LinkTimeOptimization, 'True', 'False')

			_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cmake.cfgname(cfg))
			_p(1, 'set_target_properties("%s" PROPERTIES', prj.name)
			_p(2, 'CXX_STANDARD %s', standard[cfg.cppdialect])
			_p(2, 'CXX_STANDARD_REQUIRED YES')
			_p(2, 'CXX_EXTENSIONS %s', extentions)
			_p(2, 'POSITION_INDEPENDENT_CODE %s', pic)
			_p(2, 'INTERPROCEDURAL_OPTIMIZATION %s', lto)
			_p(1, ')')
			_p('endif()')
		end

		-- precompiled headers
		-- copied from gmake2_cpp.lua
		if not cfg.flags.NoPCH and cfg.pchheader then
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

			_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cmake.cfgname(cfg))
			_p('target_precompile_headers("%s" PUBLIC %s)', prj.name, pch)
			_p('endif()')
		end

		-- pre/post buildcommands
		if cfg.prebuildmessage or #cfg.prebuildcommands > 0 then
			-- add_custom_command PRE_BUILD runs just before generating the target
			-- so instead, use add_custom_target to run it before any rule (as obj)
			_p('add_custom_target(prebuild-%s', prj.name)
			if cfg.prebuildmessage then
				local command = os.translateCommandsAndPaths("{ECHO} " .. premake.quote(cfg.prebuildmessage), cfg.project.basedir, cfg.project.location)
				_p('  COMMAND %s', command)
			end
			local commands = os.translateCommandsAndPaths(cfg.prebuildcommands, cfg.project.basedir, cfg.project.location)
			for _, command in ipairs(commands) do
				_p('  COMMAND %s', command)
			end
			_p(')')
			_p('add_dependencies(%s prebuild-%s)', prj.name, prj.name)
		end

		if cfg.postbuildmessage or #cfg.postbuildcommands > 0 then
			_p('add_custom_command(TARGET %s POST_BUILD', prj.name)
			if cfg.postbuildmessage then
				local command = os.translateCommandsAndPaths("{ECHO} " .. premake.quote(cfg.postbuildmessage), cfg.project.basedir, cfg.project.location)
				_p('  COMMAND %s', command)
			end
			local commands = os.translateCommandsAndPaths(cfg.postbuildcommands, cfg.project.basedir, cfg.project.location)
			for _, command in ipairs(commands) do
				_p('  COMMAND %s', command)
			end
			_p(')')
		end

		-- custom command
		local function addCustomCommand(fileconfig, filename)
			if #fileconfig.buildcommands == 0 or #fileconfig.buildoutputs == 0 then
				return
			end

			local custom_output_directories = table.unique(table.translate(fileconfig.buildoutputs, function(output) return project.getrelative(cfg.project, path.getdirectory(output)) end))
			-- Alternative would be to add 'COMMAND ${CMAKE_COMMAND} -E make_directory %s' to below add_custom_command
			_p('file(MAKE_DIRECTORY %s)', table.implode(custom_output_directories, "", "", " "))

			_p('add_custom_command(TARGET OUTPUT %s', table.implode(project.getrelative(cfg.project, fileconfig.buildoutputs),"",""," "))
			if fileconfig.buildmessage then
				_p('  COMMAND %s', os.translateCommandsAndPaths('{ECHO} ' .. premake.quote(fileconfig.buildmessage), cfg.project.basedir, cfg.project.location))
			end
			for _, command in ipairs(fileconfig.buildcommands) do
				_p('  COMMAND %s', os.translateCommandsAndPaths(command, cfg.project.basedir, cfg.project.location))
			end
			if filename ~= "" and #fileconfig.buildinputs ~= 0 then
				filename = filename .. " "
			end
			if filename ~= "" or #fileconfig.buildinputs ~= 0 then
				_p('  DEPENDS %s', filename .. table.implode(fileconfig.buildinputs,"",""," "))
			end
			_p(')')
		end
		local tr = project.getsourcetree(cfg.project)
		p.tree.traverse(tr, {
			onleaf = function(node, depth)
				local filecfg = p.fileconfig.getconfig(node, cfg)
				local rule = p.global.getRuleForFile(node.name, prj.rules)

				if p.fileconfig.hasFileSettings(filecfg) then
					addCustomCommand(filecfg, node.relpath)
				elseif rule then
					local environ = table.shallowcopy(filecfg.environ)

					if rule.propertydefinition then
						p.rule.prepareEnvironment(rule, environ, cfg)
						p.rule.prepareEnvironment(rule, environ, filecfg)
					end
					local rulecfg = p.context.extent(rule, environ)
					addCustomCommand(rulecfg, node.relpath)
				end
			end
		})
		addCustomCommand(cfg, "")
	end
-- restore
	path.getDefaultSeparator = oldGetDefaultSeparator
end
