--
-- Name:        cmake.lua
-- Purpose:     Define the cmake action(s).
-- Author:      Ryan Pusztai
-- Modified by: Andrea Zanellato
--              Andrew Gough
--              Manu Evans
--              Jason Perkins
--              Yehonatan Ballas
-- Created:     2013/05/06
-- Copyright:   (c) 2008-2020 Jason Perkins and the Premake project
--

local p = premake

p.modules.cmake = {}
p.modules.cmake._VERSION = p._VERSION

local cmake = p.modules.cmake
local project = p.project


function cmake.generateWorkspace(wks)
    p.eol("\r\n")
    p.indent("  ")
    
    p.generate(wks, "CMakeLists.txt", cmake.workspace.generate)
end

function cmake.generateProject(prj)
    p.eol("\r\n")
    p.indent("  ")

    if project.isc(prj) or project.iscpp(prj) then
        p.generate(prj, ".cmake", cmake.project.generate)
    end
end

function cmake.cfgname(cfg)
    local cfgname = cfg.buildcfg
    if cmake.workspace.multiplePlatforms then
        -- CMake breaks if "|" is used here
        cfgname = string.format("%s-%s", cfg.platform, cfg.buildcfg)
    end
    return cfgname
end

function cmake.cleanWorkspace(wks)
    p.clean.file(wks, "CMakeLists.txt")
end

function cmake.cleanProject(prj)
    p.clean.file(prj, prj.name .. ".cmake")
end

include("cmake_workspace.lua")
include("cmake_project.lua")

include("_preload.lua")

return cmake
