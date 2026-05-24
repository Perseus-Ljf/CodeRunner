local config = require("coderunner.config")

local M = {}

local function notify(message, level)
  if config.options.notify then
    vim.notify(message, level, { title = "CodeRunner" })
  end
end

local function get_toggleterm()
  local ok, toggleterm = pcall(require, "toggleterm")
  if not ok then
    notify("toggleterm.nvim is required", vim.log.levels.ERROR)
    return nil
  end

  local terminal_ok, terminal = pcall(require, "toggleterm.terminal")
  if not terminal_ok then
    notify("toggleterm.terminal is not available", vim.log.levels.ERROR)
    return nil
  end

  return toggleterm, terminal
end

local function find_cell_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lang = config.get_language(vim.bo[bufnr].filetype)
  local marker = lang.cell_marker or config.defaults.languages.python.cell_marker
  local start_line = 1
  local end_line = #lines

  for line_nr = current_line, 1, -1 do
    if lines[line_nr]:match(marker) then
      start_line = line_nr + 1
      break
    end
  end

  for line_nr = current_line + 1, #lines do
    if lines[line_nr]:match(marker) then
      end_line = line_nr - 1
      break
    end
  end

  return start_line, end_line
end

local function filter_lines(lines, lang)
  local filtered = {}
  local comment = lang.comment

  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not (comment and trimmed:match(comment)) then
      table.insert(filtered, line)
    end
  end

  return filtered
end

function M.send_current_block(term_id)
  local toggleterm, terminal = get_toggleterm()
  if not toggleterm then
    return
  end

  term_id = term_id or config.options.term_id

  local start_line, end_line = find_cell_range()
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local lang = config.get_language(vim.bo.filetype)
  local filtered_lines = filter_lines(lines, lang)

  if #filtered_lines == 0 then
    notify("Current cell is empty", vim.log.levels.WARN)
    return
  end

  local code = table.concat(filtered_lines, "\n") .. "\n"
  local last_line = vim.api.nvim_buf_line_count(0)
  local target_line = math.min(end_line + 1, last_line)

  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd("normal! zz")

  if terminal.get(term_id, true) == nil or terminal.get(term_id, false) == nil then
    vim.cmd("ToggleTerm")
    if lang.start_cmd and lang.start_cmd ~= "" then
      toggleterm.exec(lang.start_cmd, term_id)
    end
    vim.defer_fn(function()
      toggleterm.exec(code, term_id)
    end, config.options.startup_delay)
  else
    toggleterm.exec(code, term_id)
  end
end

function M.register_commands()
  vim.api.nvim_create_user_command("CodeRunBlock", function(opts)
    M.send_current_block(tonumber(opts.args) or config.options.term_id)
  end, {
    force = true,
    nargs = "?",
    desc = "Send the current code cell to toggleterm",
  })

  vim.api.nvim_create_user_command("CodeRunCell", function(opts)
    M.send_current_block(tonumber(opts.args) or config.options.term_id)
  end, {
    force = true,
    nargs = "?",
    desc = "Send the current code cell to toggleterm",
  })
end

function M.setup(opts)
  config.setup(opts)
  M.register_commands()
end

return M
