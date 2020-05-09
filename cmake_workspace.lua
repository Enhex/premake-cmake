--
-- Name:        cmake_workspace.lua
-- Purpose:     Generate a CMake file.
-- Author:      Ryan Pusztai
-- Modified by: Andrea Zanellato
--              Manu Evans
--              Yehonatan Ballas
-- Created:     2013/05/06
-- Copyright:   (c) 2008-2020 Jason Perkins and the Premake project
--

local p = premake
local project = p.project
local workspace = p.workspace
local tree = p.tree
local cmake = p.modules.cmake

cmake.workspace = {}
local m = cmake.workspace

--
-- Generate a CMake file
--
function m.generate(wks)
	p.utf8()
	p.w('cmake_minimum_required(VERSION 3.16)')
	p.w('project("%s")', wks.name)

	--
	-- Project list
	--
	local tr = workspace.grouptree(wks)
	tree.traverse(tr, {
		onleaf = function(n)
			local prj = n.project

			-- Build a relative path from the workspace file to the project file
			local prjpath = p.filename(prj, ".cmake")
			prjpath = path.getrelative(prj.workspace.location, prjpath)
			p.w('include(%s)', prjpath)
		end,

		--TODO wks.startproject
	})
end
