--
-- Name:        cmake_project.lua
-- Purpose:     Generate a cmake C/C++ project file.
-- Author:      Ryan Pusztai
-- Modified by: Andrea Zanellato
--              Manu Evans
--              Tom van Dijck
--              Yehonatan Ballas
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
	local toolset = p.tools[_OPTIONS.cc or cfg.toolset or p.CLANG]
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

	_p('add_executable("%s"', prj.name)
	m.files(prj)
	_p(')')
	
	for cfg in project.eachconfig(prj) do
		_p('target_include_directories("%s" PUBLIC', prj.name)
		for _, includedir in ipairs(cfg.includedirs) do
			_x(1, '$<$<CONFIG:%s>:%s>', cfg.name, project.getrelative(cfg.project, includedir))
		end
		_p(')')
	
		_p('target_compile_definitions("%s" PUBLIC', prj.name)
		for _, define in ipairs(cfg.defines) do
			_p(1, '$<$<CONFIG:%s>:%s>', cfg.name, p.esc(define):gsub(' ', '\\ '))
		end
		_p(')')

		_p('target_link_directories("%s" PUBLIC', prj.name)
		for _, libdir in ipairs(cfg.libdirs) do
			_p(1, '$<$<CONFIG:%s>:%s>', cfg.name, project.getrelative(cfg.project, libdir))
		end
		_p(')')

		local toolset = m.getcompiler(cfg)
		_p('target_link_libraries("%s" PUBLIC', prj.name)
		for _, link in ipairs(toolset.getlinks(cfg)) do
			_p(1, '$<$<CONFIG:%s>:%s>', cfg.name, link)
		end
		_p(')')

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

			local extentions = 'YES'
			if cfg.cppdialect:find('^gnu') == nil then
				extentions = 'NO'
			end
			
			_p('if(CMAKE_BUILD_TYPE STREQUAL %s)', cfg.name)
			_p(1, 'set_target_properties("%s" PROPERTIES', prj.name)
			_p(2, 'CXX_STANDARD %s', standard[cfg.cppdialect])
			_p(2, 'CXX_STANDARD_REQUIRED YES')
			_p(2, 'CXX_EXTENSIONS %s', extentions)
			_p(1, ')')
			_p('endif()')
		end
	end
end
