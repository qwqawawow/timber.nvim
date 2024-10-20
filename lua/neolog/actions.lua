---@class NeologActions
--- @field log_templates NeologLogTemplates
local M = {}

local utils = require("neolog.utils")

---@param line_number number 1-indexed
local function indent_line_number(line_number)
  local current_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { line_number, 0 })
  vim.cmd("normal! ==")
  vim.api.nvim_win_set_cursor(0, current_pos)
end

--- Build the log statement from template. Support special placeholers:
---   %identifier: the identifier text
---   %fn_name: the enclosing function name. If there's none, replaces with empty string
---   %line_number: the line_number number
---   %insert_cursor: after adding the log statement, go to insert mode and place the cursor here.
---     If there's multiple log statements, choose the first one
---@param log_template string
---@param log_target_node TSNode
---@return string, number?
local function build_log_statement(log_template, log_target_node)
  local bufnr = vim.api.nvim_get_current_buf()
  local identifier_text = vim.treesitter.get_node_text(log_target_node, bufnr)

  if string.find(log_template, "%%identifier") then
    log_template = string.gsub(log_template, "%%identifier", identifier_text)
  end

  if string.find(log_template, "%%line_number") then
    local start_row = log_target_node:start()
    log_template = string.gsub(log_template, "%%line_number", start_row + 1)
  end

  local insert_cursor_offset = string.find(log_template, "%%insert_cursor")
  if insert_cursor_offset then
    log_template = string.gsub(log_template, "%%insert_cursor", "")
  end

  return log_template, insert_cursor_offset
end

---@param statements LogStatementInsert[]
local function insert_log_statements(statements)
  local bufnr = vim.api.nvim_get_current_buf()

  table.sort(statements, function(a, b)
    -- If two statements have the same row, sort by the appearance order of the log target
    if a.row == b.row then
      local a_row, a_col = a.log_target:start()
      local b_row, b_col = b.log_target:start()
      return a_row == b_row and a_col < b_col or a_row < b_row
    end

    return a.row < b.row
  end)

  -- Offset the row numbers
  local offset = 0

  for _, statement in ipairs(statements) do
    local insert_line = statement.row + offset
    vim.api.nvim_buf_set_lines(bufnr, insert_line, insert_line, false, statement.content)
    indent_line_number(insert_line + 1)

    offset = offset + #statement.content
  end
end

---Perform post-insert operations:
---   1. Place the cursor at the insert_cursor placeholder if any
---@param statements LogStatementInsert[]
local function after_insert_log_statements(statements)
  local has_insert_cursor_statement = utils.array_find(statements, function(statement)
    return statement.insert_cursor_offset
  end)

  if has_insert_cursor_statement then
    local row = has_insert_cursor_statement.row
    local offset = has_insert_cursor_statement.insert_cursor_offset
    -- We can't simply set the cursor because the line has been indented
    -- We do it via Vim motion:
    --   1. Jump to the insert line
    --   2. Move to the first character
    --   3. Move left by the offset
    --   4. Go to insert mode
    vim.cmd(string.format("normal! %dG^%dl", row + 1, offset - 1))
    vim.cmd("startinsert")
  end
end

---Query all target containers in the current buffer that intersect with the given range
---@alias logable_range {[1]: number, [2]: number}
---@param lang string
---@param range {[1]: number, [2]: number, [3]: number, [4]: number}
---@return {container: TSNode, logable_range: logable_range?}[]
local function query_log_target_container(lang, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr, lang)
  local tree = parser:parse()[1]
  local root = tree:root()

  local query = vim.treesitter.query.get(lang, "neolog-log-container")
  if not query then
    vim.notify(string.format("logging_framework doesn't support %s language", lang), vim.log.levels.ERROR)
    return {}
  end

  local containers = {}

  for _, match, metadata in query:iter_matches(root, bufnr, 0, -1) do
    ---@type TSNode
    local log_container = match[utils.get_key_by_value(query.captures, "log_container")]

    if log_container and utils.ranges_intersect(utils.get_ts_node_range(log_container), range) then
      ---@type TSNode?
      local logable_range = match[utils.get_key_by_value(query.captures, "logable_range")]

      local logable_range_col_range

      if metadata.adjusted_logable_range then
        logable_range_col_range = {
          metadata.adjusted_logable_range[1],
          metadata.adjusted_logable_range[3],
        }
      elseif logable_range then
        logable_range_col_range = { logable_range:start(), logable_range:end_() }
      end

      table.insert(containers, { container = log_container, logable_range = logable_range_col_range })
    end
  end

  return containers
end

---Find all the log target nodes in the given container
---@param container TSNode
---@param lang string
---@return TSNode[]
local function find_log_target(container, lang)
  local query = vim.treesitter.query.get(lang, "neolog-log-target")
  if not query then
    vim.notify(string.format("logging_framework doesn't support %s language", lang), vim.log.levels.ERROR)
    return {}
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local log_targets = {}
  for _, node in query:iter_captures(container, bufnr, 0, -1) do
    table.insert(log_targets, node)
  end

  return log_targets
end

---@param filetype string
---@return string?
local function get_lang(filetype)
  -- Treesitter doesn't support jsx directly but through tsx
  if filetype == "javascriptreact" then
    return "tsx"
  end

  return vim.treesitter.language.get_lang(vim.bo.filetype)
end

---Group log targets that overlap with each other
---Due to the nature of the AST, if two nodes are overlapping, one must strictly
---include another
---@param log_targets TSNode[]
---@return TSNode[][]
local function group_overlapping_log_targets(log_targets)
  -- Add index to make sure the sort is stable
  log_targets = utils.array_sort_with_index(log_targets, function(a, b)
    local result = utils.compare_ts_node_start(a[1], b[1])
    return result == "equal" and a[2] < b[2] or result == "before"
  end)

  local groups = {}

  ---@type TSNode[]
  local current_group = {}

  for _, log_target in ipairs(log_targets) do
    if #current_group == 0 then
      table.insert(current_group, log_target)
    else
      -- Check the current node with each node in the current group
      -- If it matches any of the node, it belongs to the current group
      -- If it not, move it into a new group
      local insersect_any = utils.array_any(current_group, function(node)
        return utils.ranges_intersect(utils.get_ts_node_range(node), utils.get_ts_node_range(log_target))
      end)

      if insersect_any then
        table.insert(current_group, log_target)
      else
        table.insert(groups, current_group)
        current_group = { log_target }
      end
    end
  end

  if #current_group > 0 then
    table.insert(groups, current_group)
  end

  return groups
end

---Given a group of nodes, pick the "best" node
---We sort the nodes by the selection range and pick the first node which is
---fully included in the selection range
---@param nodes TSNode[]
---@params selection_range {[1]: number, [2]: number, [3]: number, [4]: number}
---@return TSNode
local function pick_best_node(nodes, selection_range)
  if #nodes == 0 then
    error("nodes can't be empty")
  end

  if #nodes == 1 then
    return nodes[1]
  end

  -- Sort by node start then by node end (descending)
  -- Add index to make sure the sort is stable
  nodes = utils.array_sort_with_index(nodes, function(a, b)
    local result = utils.compare_ts_node_start(a[1], b[1])
    if result == "equal" then
      result = utils.compare_ts_node_end(a[1], b[1])
      return result == "equal" and a[2] < b[2] or result == "after"
    else
      return result == "before"
    end
  end)

  -- @type TSNode?
  local best_node = utils.array_find(nodes, function(node)
    return utils.range_include(selection_range, utils.get_ts_node_range(node))
  end)

  return best_node or nodes[#nodes]
end

---@class LogStatementInsert
---@field content string[] The log statement content
---@field row number The (0-indexed) row number to insert
---@field insert_cursor_offset number? The offset of the %insert_cursor placeholder if any
---@field log_target TSNode The log target node

--- Add log statement for the current identifier at the cursor
--- @alias position "above" | "below"
--- @class AddLogOptions
--- @field log_template string
--- @field position position
function M.add_log(opts)
  local lang = get_lang(vim.bo.filetype)
  if not lang then
    vim.notify("Cannot determine language for current buffer", vim.log.levels.ERROR)
    return
  end

  local log_template = opts.log_template or M.log_templates[lang]
  local position = opts.position
  if not log_template then
    vim.notify(string.format("Log template for %s language is not found", lang), vim.log.levels.ERROR)
    return
  end

  local selection_range = utils.get_selection_range()

  local log_containers = query_log_target_container(lang, selection_range)

  ---@type LogStatementInsert[]
  local to_insert = {}

  for _, container in ipairs(log_containers) do
    local log_targets = find_log_target(container.container, lang)
    local logable_range = container.logable_range

    local insert_row

    if logable_range then
      insert_row = logable_range[1]
    else
      if position == "above" then
        insert_row = container.container:start()
      else
        insert_row = container.container:end_() + 1
      end
    end

    log_targets = utils.array_filter(log_targets, function(node)
      return utils.ranges_intersect(selection_range, utils.get_ts_node_range(node))
      -- return utils.range_include(selection_range, utils.get_ts_node_range(node))
    end)

    -- For each group, we pick the "biggest" node
    -- A node is the biggest if it contains all other nodes in the group
    local groups = group_overlapping_log_targets(log_targets)
    log_targets = utils.array_map(groups, function(group)
      return pick_best_node(group, selection_range)
    end)

    -- Filter targets that intersect with the given range
    for _, log_target in ipairs(log_targets) do
      local content, insert_cursor_offset = build_log_statement(log_template, log_target)
      table.insert(to_insert, {
        content = { content },
        row = insert_row,
        insert_cursor_offset = insert_cursor_offset,
        log_target = log_target,
      })
    end
  end

  insert_log_statements(to_insert)
  after_insert_log_statements(to_insert)
end

-- Register the custom predicate
---@param templates NeologLogTemplates
function M.setup(templates)
  M.log_templates = templates

  -- Register the custom directive
  vim.treesitter.query.add_directive("adjust-range!", function(match, _, _, predicate, metadata)
    local capture_id = predicate[2]

    ---@type TSNode
    local node = match[capture_id]

    -- Get the adjustment values from the predicate arguments
    local start_adjust = tonumber(predicate[3]) or 0
    local end_adjust = tonumber(predicate[4]) or 0

    -- Get the original range
    local start_row, start_col, end_row, end_col = node:range()

    -- Adjust the range
    local adjusted_start_row = math.max(0, start_row + start_adjust) -- Ensure we don't go below 0
    local adjusted_end_row = math.max(adjusted_start_row, end_row + end_adjust) -- Ensure end is not before start

    -- Store the adjusted range in metadata
    metadata.adjusted_logable_range = { adjusted_start_row, start_col, adjusted_end_row, end_col }
  end, { force = true })
end

return M
