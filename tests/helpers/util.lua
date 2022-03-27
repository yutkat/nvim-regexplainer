local regexplainer = require'regexplainer'
local ts_utils = require'nvim-treesitter.ts_utils'
local parsers = require "nvim-treesitter.parsers"

local get_node_text = ts_utils.get_node_text

---@diagnostic disable-next-line: unused-local
local log = require'regexplainer.utils'.debug

local M = {}

-- NOTE: ideally, we'd query for the jsdoc description as an injected language, but
-- so far I've been unable to make that happen, after that, I tried querying the JSDoc tree
-- from the line above the regexp, but that also proved difficult
-- so, at long last, we do some sring manipulation

local query_js = vim.treesitter.query.parse_query('javascript', [[
  (comment) @comment
  (expression_statement
    (regex)) @expr
  ]])

-- local query_jsdoc = vim.treesitter.query.parse_query('jsdoc', [[
--   (tag
--     (tag_name)
--     (description) @description)
-- ]])
--
-- local function get_jsdoc_tag_description(lines)
--   return table.concat(vim.tbl_map(function(line)
--     return line:gsub('%s+%* ', '', 1)
--   end, lines), '\n'):gsub("^%s*(.-)%s*$", "%1")
-- end
--
-- local function get_expected_from_jsdoc(comment)
--   local jsdoc_parser = vim.treesitter.get_string_parser(comment, 'jsdoc')
--   local jsdoc_tree = jsdoc_parser:parse()[1]
--
--   for id, cnode in query_jsdoc:iter_captures(jsdoc_tree:root(), comment) do
--     local name = query_jsdoc.captures[id]
--
--     if name == 'description' then
--       local node_lines = get_node_text(cnode)
--       local prev = cnode:prev_sibling()
--       local prev_text = table.concat(get_node_text(prev), '\n')
--       if prev_text == '@example' then
--         return get_jsdoc_tag_description(node_lines):gsub('EXPECTED:\n', '')
--       end
--     end
--   end
-- end

local function get_expected_from_jsdoc(comment)
  local lines = {}
  for line in comment:gmatch("([^\n]*)\n?") do
    local clean = line
      :gsub('^/%*%*', '')
      :gsub('%*/$', '')
      :gsub('%s+%* ?', '', 1)
      :gsub('@example EXPECTED%: ?', '')
    table.insert(lines, clean)
  end

  return M.trim(table.concat(lines, '\n'))
end

local function get_cases()
  local results = {}
  local parser = parsers.get_parser(0)
  local tree = parser:parse()[1]

  for id, node in query_js:iter_captures(tree:root(), 0) do
    local name = query_js.captures[id] -- name of the capture in the query
    local prev = node:prev_sibling()
    local prev_text = table.concat(get_node_text(prev), '\n')
    if name == 'expr' and prev:type() == 'comment' then
      local text = table.concat(get_node_text(node:named_child('pattern')), '\n')
      local expected = get_expected_from_jsdoc(prev_text)
      table.insert(results, {
        text = text,
        example = expected,
        row = node:start(),
      })
    end
  end

  return results
end

function M.trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function M.editfile(testfile)
  vim.cmd("e " .. testfile)
  assert.are.same(
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p"),
    vim.fn.fnamemodify(testfile, ":p")
  )
end

function M.iter_regexes_with_descriptions(filename)
  M.editfile(filename)

  local cases = get_cases()

  local index = 0

  return function()
    index = index + 1
    if index <= #cases then
      return cases[index]
    end
  end
end

function M.clear_test_state()
  -- Clear regexplainer state
  regexplainer.teardown()

  -- Create fresh window
  vim.cmd("top new | wincmd o")
  local keepbufnr = vim.api.nvim_get_current_buf()

  -- Cleanup any remaining buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= keepbufnr then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  vim.cmd[[ bufdo bd! ]]

  assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "Failed to properly clear tab")
  assert(#vim.api.nvim_list_bufs() == 1, "Failed to properly clear buffers")
end

function M.assert_popup_text_at_row(row, expected)
  M.editfile(assert:get_parameter('fixture_filename'))
  local moved = pcall(vim.api.nvim_win_set_cursor, 0, { row, 1 })
  while moved == false do
    M.editfile(assert:get_parameter('fixture_filename'))
  end
  regexplainer.show()
  M.wait_for_regexplainer_buffer()
  local bufnr = require'regexplainer.buffers'.get_buffers()[1].bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false);
  local text = table.concat(lines, '\n')
  local regex = vim.api.nvim_buf_get_lines(0, 0, -1, false)[row]
  return assert.are.same(expected, text, row .. ': ' .. regex)
end

function M.assert_string(regexp, expected, message)
  local bufnr = vim.api.nvim_create_buf(true, true)
  local buffers

  vim.api.nvim_buf_call(bufnr, function()
    vim.bo.filetype = 'javascript'
    vim.api.nvim_set_current_line(regexp)
    vim.cmd[[:norm l]]
    regexplainer.show()
    buffers = M.wait_for_regexplainer_buffer()
  end)

  local re_bufnr = buffers[1].bufnr
  local lines = vim.api.nvim_buf_get_lines(re_bufnr, 0, vim.api.nvim_buf_line_count(re_bufnr), false);
  local text = table.concat(lines, '\n')

  -- Cleanup any remaining buffers
  vim.api.nvim_buf_delete(bufnr, { force = true })

  return assert.are.same(expected, text, message)
end

function M.sleep(n)
  os.execute("sleep " .. tonumber(n))
end

function M.wait_for_regexplainer_buffer()
  local buffers = require'regexplainer.buffers'.get_buffers()
  local count = 0
  while not #buffers and count < 20 do
    vim.cmd[[:norm l]]
    regexplainer.show()
    count = count + 1
    buffers = require'regexplainer.buffers'.get_buffers()
  end
  return buffers
end

function M.get_info_on_capture(id, name, node, metadata)
  local yes, text = pcall(get_node_text, node)
  return {
      id, name,
      text = yes and text or nil,
      metadata = metadata,
      type = node:type(),
      pos = table.pack(node:range())
    }
end

M.dedent = require'plenary.strings'.dedent

return M
