--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      24bit-xjkp
-- @file        config.lua
--

-- imports
import("utils")
import("cachegen")
import("qmltc")

-- enable the jobgraph prepare implementation for the target
--
-- The rule only registers `on_preparecmd_file` by default. When both qmlcachegen and
-- qmltc are needed, we attach `on_prepare_files` to the target rule, so that the two
-- tools can run in parallel for the same file. The target keeps its own rule instance,
-- other targets are not affected.
local function _enable_jobgraph(target)
    if target:data("qt.qml.jobgraph") then
        return
    end
    local ruleinst = assert(target:rule("qt.qml"), "qt.qml: rule not found")
    local cloned = ruleinst:clone()
    cloned:set("prepare_files", function (target, jobgraph, sourcebatch, opt)
        import("prepare_qml").prepare_jobgraph(target, jobgraph, sourcebatch, opt)
    end)
    cloned:extraconf_set("prepare_files", { jobgraph = true })
    target:rule_add(cloned)
    target:data_set("qt.qml.jobgraph", true)
end

-- find and check the tools needed by the module
function main(target)
    local setting = utils.get_setting(target)
    local tools = {}
    if setting.cachegen then
        tools.cachegen = cachegen.get_tool(target, setting)
    end
    if setting.type_compiler then
        tools.qmltc = qmltc.get_tool(target)
    end
    target:data_set("qt.qml.tools", tools)
    if tools.cachegen and tools.qmltc then
        _enable_jobgraph(target)
    end
end
