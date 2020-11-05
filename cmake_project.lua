--
-- Name:        cmake_project.lua
-- Purpose:     Generate a cmake C/C++ project file.
-- Author:      Ryan Pusztai
-- Modified by: Andrea Zanellato
--              Manu Evans
--              Tom van Dijck
--              Yehonatan Ballas
--              Joel Linn
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
			_p(depth, '"%s"', node.relpath)
		end
	}, true)
end

--
-- Project: Generate the cmake project file.
--
function m.generate(prj)
	p.utf8()

	if prj.kind == 'Utility' then
		return
	end

	if prj.kind == 'StaticLib' then
		_p('add_library("%s" STATIC', prj.name)
	elseif prj.kind == 'SharedLib' then
		_p('add_library("%s" SHARED', prj.name)
	else
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
		_p(2, 'ARCHIVE_OUTPUT_DIRECTORY "%s"', cfg.buildtarget.directory)
		_p(2, 'LIBRARY_OUTPUT_DIRECTORY "%s"', cfg.buildtarget.directory)
		_p(2, 'RUNTIME_OUTPUT_DIRECTORY "%s"', cfg.buildtarget.directory)
		_p(1,')')
		_p('endif()')

		-- include dirs
		_p('target_include_directories("%s" PRIVATE', prj.name)
		for _, includedir in ipairs(cfg.includedirs) do
			_x(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), includedir)
		end
		_p(')')

		-- defines
		_p('target_compile_definitions("%s" PRIVATE', prj.name)
		for _, define in ipairs(cfg.defines) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), p.esc(define):gsub(' ', '\\ '))
		end
		_p(')')

		-- lib dirs
		_p('target_link_directories("%s" PRIVATE', prj.name)
		for _, libdir in ipairs(cfg.libdirs) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), libdir)
		end
		_p(')')

		-- libs
		_p('target_link_libraries("%s"', prj.name)
		-- Do not use toolset here as cmake needs to resolve dependency chains
		local uselinkgroups = isclangorgcc and cfg.linkgroups == p.ON
		if uselinkgroups then
		  _p(1, '-Wl,--start-group')
		end
		for a, link in ipairs(config.getlinks(cfg, "dependencies", "object")) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), link.linktarget.basename)
		end
		if uselinkgroups then
		  -- System libraries don't depend on the project
		  _p(1, '-Wl,--end-group')
		  _p(1, '-Wl,--start-group')
		end
		for _, link in ipairs(config.getlinks(cfg, "system", "basename")) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), link)
		end
		if uselinkgroups then
		  _p(1, '-Wl,--end-group')
		end
		_p(')')

		-- build options
		_p('target_compile_options("%s" PRIVATE', prj.name)
		-- FIXE: target_compile_options() always escapes chars like ` or "
		-- https://gitlab.kitware.com/cmake/cmake/-/issues/21396
		-- Setting COMPILE_FLAGS (and LINK_FLAGS) works as desired,
		-- but we would need to filter c vs. cxx files and set flags using
		-- set_source_files_properties() individually. That way it would
		-- also be possible to support premakes "compileas" and
		-- per file "buildoptions". See the gmake2 core module.
		for _, option in ipairs(cfg.buildoptions) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), option)
		end
		for _, flag in ipairs(toolset.getcflags(cfg)) do
			_p(1, '$<$<AND:$<CONFIG:%s>,$<COMPILE_LANGUAGE:C>>:%s>', cmake.cfgname(cfg), flag)
		end
		for _, flag in ipairs(toolset.getcxxflags(cfg)) do
			_p(1, '$<$<AND:$<CONFIG:%s>,$<COMPILE_LANGUAGE:CXX>>:%s>', cmake.cfgname(cfg), flag)
		end
		_p(')')

		-- link options
		_p('target_link_options("%s" PRIVATE', prj.name)
		for _, option in ipairs(cfg.linkoptions) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), option)
		end
		for _, flag in ipairs(toolset.getldflags(cfg)) do
			_p(1, '$<$<CONFIG:%s>:%s>', cmake.cfgname(cfg), flag)
		end
		_p(')')

		-- C++ standard
		-- only need to configure it specified
		if cfg.cppdialect ~= '' or cfg.cppdialect == 'Default' then
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
	end
end
