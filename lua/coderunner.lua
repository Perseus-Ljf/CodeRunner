local ok, toggleterm = pcall(require, "toggleterm")
if not ok then
  vim.notify("toggleterm not found!", vim.log.levels.ERROR)
  return
end
local M = {}

local function find_cell_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filetype = vim.bo.filetype

  local cell_markers = {
    python = "^%s*# %%",
    matlab = "^%s*% %%",
    julia = "^%s*# %%",
  }

  local marker = cell_markers[filetype] or "^%s*# %%"
  local start_line = 1
  local end_line = #lines

  for i = current_line, 1, -1 do
    if lines[i]:match(marker) then
      start_line = i + 1
      break
    end
  end
  for i = current_line + 1, #lines do
    if lines[i]:match(marker) then
      end_line = i - 1
      break
    end
  end
  return start_line, end_line
end

M.send_current_block = function(term_id)
  term_id = term_id or 1
  local start_line, end_line = find_cell_range()
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local filetype = vim.bo.filetype

  local lang_config = {
    python = {
      comment = "^#",
      start_cmd = "sipy",
    },
    matlab = {
      comment = "^%%",
      start_cmd = "matlab -nodisplay",
    },
  }
  local config = lang_config[filetype] or lang_config.python
  local filtered_lines = {}
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match(config.comment) then
      table.insert(filtered_lines, line)
    end
  end
  if #filtered_lines == 0 then
    vim.notify("null cell", vim.log.levels.WARN)
    return
  end
  local code = table.concat(filtered_lines, "\n") .. "\n"
  local last_line = vim.api.nvim_buf_line_count(0)
  local target_line = math.min(end_line + 1, last_line)
  local terminal = require("toggleterm.terminal")

  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd("normal! zz")

  if terminal.get(term_id, true) == nil or terminal.get(term_id, false) == nil then
    vim.cmd("ToggleTerm")
    toggleterm.exec(config.start_cmd, term_id)
    vim.defer_fn(function()
      toggleterm.exec(code, term_id)
    end, 500)
  else
    toggleterm.exec(code, term_id)
  end
end

M.register_commands = function()
  vim.api.nvim_create_user_command("CodeRunBlock", function(opts)
    M.send_current_block(tonumber(opts.args) or 1)
  end, { nargs = "?" })
end

M.setup = function()
  M.register_commands()
end

return M
