---@module "unwind.collector"
--- File deduplication, frame grouping, and vendor filtering logic.
--- Groups parsed frames by unique file path, maintaining original occurrence order.
--- Delegated to unwind.collector.data, unwind.collector.ui, and unwind.collector.persistence.

local data = require("unwind.collector.data")
local ui = require("unwind.collector.ui")
local persistence = require("unwind.collector.persistence")

local M = {}

M.data = data
M.ui = ui
M.persistence = persistence

M.is_vendor_or_ignored = data.is_vendor_or_ignored
M.collect = data.collect

return M
