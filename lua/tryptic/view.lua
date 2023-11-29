local devicons_installed, devicons = pcall(require, 'nvim-web-devicons')
local u = require 'tryptic.utils'
local float = require 'tryptic.float'
local fs = require 'tryptic.fs'
local git = require 'tryptic.git'
local diagnostics = require 'tryptic.diagnostics'

local M = {}

---@param Diagnostics Diagnostics
---@param Git Git
---@param path_details PathDetails
---@return PathDetails
local function filter_and_encrich_dir_contents(Diagnostics, Git, path_details)
  local vim = _G.tryptic_mock_vim or vim

  local filtered_children = u.cond(vim.g.tryptic_config.options.show_hidden, {
    when_true = path_details.children,
    when_false = function()
      local child_paths = u.map(path_details.children, u.get 'path')
      local paths_not_ignored = Git:filter_ignored(child_paths)
      return u.filter(path_details.children, function(child)
        local is_git_ignored = not u.list_includes(paths_not_ignored, child.path)
        local is_dot_file = string.sub(child.display_name, 1, 1) == '.'
        return not is_git_ignored and not is_dot_file
      end)
    end,
  })

  path_details.children = filtered_children
  path_details.git_status = Git:status_of(path_details.path)
  path_details.diagnostic_status = Diagnostics:get(path_details.path)

  for index, child in ipairs(path_details.children) do
    path_details.children[index].git_status = Git:status_of(child.path)
    path_details.children[index].diagnostic_status = Diagnostics:get(child.path)
  end
  return path_details
end

---Take a PathDetails and return lines and highlights for an nvim buffer
---@param State TrypticState
---@param path_details PathDetails
---@return string[] # Lines including icons
---@return string[] # Highlights for icons
local function path_details_to_lines(State, path_details)
  local lines = {}
  local highlights = {}

  for _, child in ipairs(path_details.children) do
    local line, highlight_name = u.cond(child.is_dir, {
      when_true = function()
        local line = ''
        if devicons_installed then
          line = line .. ' '
        end
        line = line .. child.display_name
        return line, 'Directory'
      end,
      when_false = function()
        if devicons_installed then
          local maybe_icon, maybe_highlight = devicons.get_icon_by_filetype(child.filetype)
          local highlight = maybe_highlight or 'Comment'
          local fallback_icon = ''
          local icon = maybe_icon or fallback_icon
          local line = icon .. ' ' .. child.display_name
          return line, highlight
        end
        return child.display_name
      end,
    })

    local cut_paths = u.map(State.cut_list, function(value)
      return value.path
    end)

    local copy_paths = u.map(State.copy_list, function(value)
      return value.path
    end)

    -- TODO: Replace these with the state methods
    if u.list_includes(cut_paths, child.path) then
      line = line .. ' (cut)'
    end

    if u.list_includes(copy_paths, child.path) then
      line = line .. ' (copy)'
    end

    table.insert(lines, line)
    table.insert(highlights, highlight_name)
  end

  return lines, highlights
end

---Get the PathDetails that correspond to the path under the cursor
---@param State TrypticState
---@return PathDetails
function M.get_target_under_cursor(State)
  local vim = _G.tryptic_mock_vim or vim
  local line_number = vim.api.nvim_win_get_cursor(0)[1]
  return State.windows.current.contents.children[line_number]
end

---Get a list of PathDetails that correspond to all the paths under the visual selection
---@param State TrypticState
---@return PathDetails[]
function M.get_targets_in_selection(State)
  local vim = _G.tryptic_mock_vim or vim
  local from = vim.fn.getpos('v')[2]
  local to = vim.api.nvim_win_get_cursor(0)[1]
  local results = {}
  local paths = State.windows.current.contents.children
  if paths then
    -- need to check min and max to account for the directionality of the visual selection
    for i = math.min(to, from), math.max(to, from), 1 do
      table.insert(results, paths[i])
    end
  end
  return results
end

---Get the line number of a particular path in the buffer
---@param path string
---@param path_details PathDetails
---@return integer
local function line_number_of_path(path, path_details)
  local num = 1
  for i, child in ipairs(path_details) do
    if child.path == path then
      num = i
      break
    end
  end
  return num
end

---Currently just return "(cwd)" if the path == cwd
---@param path string
---@return string?
local function get_title_postfix(path)
  local vim = _G.tryptic_mock_vim or vim
  if path == vim.fn.getcwd() then
    return '(cwd)'
  end
end

---@param buf integer
---@param sign_name string
---@param group string
---@param line_num integer
local function place_sign(buf, sign_name, group, line_num)
  -- If the sign isn't defined sign_getdefined will return an empty {}
  if vim.fn.sign_getdefined(sign_name)[1] then
    vim.fn.sign_place(0, group, sign_name, buf, { lnum = line_num })
  end
end

---@param buf integer
---@param children PathDetails
---@param group string # see :h sign-group
---@return nil
local function set_sign_columns(buf, children, group)
  local vim = _G.tryptic_mock_vim or vim
  vim.fn.sign_unplace(group)
  for index, entry in ipairs(children) do
    if entry.git_status then
      local sign_name = git.get_sign(entry.git_status)
      place_sign(buf, sign_name, group, index)
    end

    if entry.diagnostic_status then
      local sign_name = diagnostics.get_sign(entry.diagnostic_status)
      place_sign(buf, sign_name, group, index)
    end
  end
end

-- TODO: This function is probably pointless
---@param Diagnostics Diagnostics
---@param Git Git
---@param path string
---@return PathDetails
local function get_dir_contents(Diagnostics, Git, path)
  local contents = fs.get_path_details(path)
  return filter_and_encrich_dir_contents(Diagnostics, Git, contents)
end

---@param State TrypticState
---@param target_dir string
---@param Diagnostics Diagnostics
---@param Git Git
---@param cursor_target? string full path
---@return nil
function M.nav_to(State, target_dir, Diagnostics, Git, cursor_target)
  local vim = _G.tryptic_mock_vim or vim

  local focused_win = State.windows.current.win
  local parent_win = State.windows.parent.win
  local child_win = State.windows.child.win

  local focused_buf = vim.api.nvim_win_get_buf(focused_win)
  local focused_contents = get_dir_contents(Diagnostics, Git, target_dir)
  local focused_title = vim.fs.basename(target_dir)
  local focused_lines, focused_highlights = path_details_to_lines(State, focused_contents)

  local parent_buf = vim.api.nvim_win_get_buf(parent_win)
  local parent_path = vim.fs.dirname(target_dir)
  local parent_title = vim.fs.basename(parent_path)
  local parent_contents = get_dir_contents(Diagnostics, Git, parent_path)
  local parent_lines, parent_highlights = path_details_to_lines(State, parent_contents)

  float.win_set_lines(parent_win, parent_lines)
  float.win_set_lines(focused_win, focused_lines, true)

  set_sign_columns(focused_buf, focused_contents.children, 'tryptic_sign_col_focused')
  set_sign_columns(parent_buf, parent_contents.children, 'tryptic_sign_col_parent')

  float.win_set_title(parent_win, parent_title, '', 'Directory', get_title_postfix(parent_path))
  float.win_set_title(focused_win, focused_title, '', 'Directory', get_title_postfix(target_dir))

  float.buf_apply_highlights(focused_buf, focused_highlights)
  float.buf_apply_highlights(parent_buf, parent_highlights)

  ---@type integer
  local focused_win_line_number = u.cond(cursor_target, {
    when_true = function()
      return line_number_of_path(cursor_target --[[@as string]], focused_contents.children)
    end,
    when_false = State.path_to_line_map[target_dir] or 1,
  })
  local buf_line_count = vim.api.nvim_buf_line_count(focused_buf)
  vim.api.nvim_win_set_cursor(0, { math.min(focused_win_line_number, buf_line_count), 0 })

  local parent_win_line_number = line_number_of_path(target_dir, parent_contents.children)
  vim.api.nvim_win_set_cursor(parent_win, { parent_win_line_number, 0 })

  State.windows = {
    parent = {
      path = parent_path,
      contents = parent_contents,
      win = parent_win,
    },
    current = {
      path = target_dir,
      previous_path = State.windows.current.path,
      contents = focused_contents,
      win = focused_win,
    },
    child = {
      path = '',
      contents = nil,
      lines = nil,
      win = child_win,
    },
  }
end

---@param State TrypticState
---@param Diagnostics Diagnostics
---@param Git Git
---@return nil
function M.jump_to_cwd(State, Diagnostics, Git)
  local vim = _G.tryptic_mock_vim or vim
  local current = State.windows.current
  local cwd = vim.fn.getcwd()
  -- TODO: DRY
  if current.path == cwd and current.previous_path then
    M.nav_to(State, current.previous_path, Diagnostics, Git)
  else
    M.nav_to(State, cwd, Diagnostics, Git)
  end
end

---@param State TrypticState
---@param path_details PathDetails
---@param Diagnostics Diagnostics
---@param Git Git
---@return nil
function M.update_child_window(State, path_details, Diagnostics, Git)
  local vim = _G.tryptic_mock_vim or vim
  local buf = vim.api.nvim_win_get_buf(State.windows.child.win)

  State.windows.child.path = u.cond(path_details == nil, {
    when_true = nil,
    when_false = function()
      return path_details.path
    end,
  })

  if path_details == nil then
    float.win_set_title(State.windows.child.win, '[empty directory]')
    float.buf_set_lines(buf, {})
  elseif path_details.is_dir then
    float.win_set_title(
      State.windows.child.win,
      path_details.basename,
      '',
      'Directory',
      get_title_postfix(path_details.path)
    )
    local contents = get_dir_contents(Diagnostics, Git, path_details.path)
    local lines, highlights = path_details_to_lines(State, contents)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'tryptic')
    float.buf_set_lines(buf, lines)
    float.buf_apply_highlights(buf, highlights)
    set_sign_columns(buf, contents.children, 'tryptic_sign_col_child')
  else
    local filetype = fs.get_filetype_from_path(path_details.path) -- TODO: De-dupe this
    local icon, highlight = u.cond(devicons_installed, {
      when_true = function()
        return devicons.get_icon_by_filetype(filetype)
      end,
      when_false = function()
        return nil, nil
      end,
    })
    float.win_set_title(State.windows.child.win, path_details.basename, icon, highlight)
    float.buf_set_lines_from_path(buf, path_details.path)
  end
end

---@param State TrypticState
---@param path string
---@return nil
function M.jump_cursor_to(State, path)
  local vim = _G.tryptic_mock_vim or vim
  local line_num
  for index, item in ipairs(State.windows.current.contents.children) do
    if item.path == path then
      line_num = index
      break
    end
  end
  if line_num then
    vim.api.nvim_win_set_cursor(0, { line_num, 0 })
  end
end

---@param State TrypticState
---@param Diagnostics Diagnostics
---@param Git Git
---@return nil
function M.refresh_view(State, Diagnostics, Git)
  -- TODO: This an inefficient way of refreshing the view
  M.nav_to(State, State.windows.current.path, Diagnostics, Git)
end

return M
