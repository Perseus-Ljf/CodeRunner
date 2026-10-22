local config = require("coderunner.config")
local sessions = require("coderunner.julia_session")
local M = {}
local namespace = vim.api.nvim_create_namespace("coderunner.workspace")
local rows = {}

local function notify(message)
  if config.options.notify then
    vim.notify(message, vim.log.levels.WARN, { title = "CodeRunner Workspace" })
  end
end

local function clean(text)
  return (text:gsub("[%z\1-\31\127]", function(character)
    return ("\\x%02x"):format(character:byte())
  end))
end

local function fit(text, width)
  text = clean(text)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local low, high = 0, vim.fn.strchars(text)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle)) <= width - 3 then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. "..."
end

local function validate(id)
  if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then
    notify("Workspace terminal id must be a positive integer")
    return false
  end
  local options = config.options.workspace
  for name, bounds in pairs({
    width = { 24, 200 },
    timeout = { 100, 120000 },
    max_items = { 1, 2000 },
    preview_length = { 16, 512 },
  }) do
    local value = options[name]
    if type(value) ~= "number" or value % 1 ~= 0 or value < bounds[1] or value > bounds[2] then
      notify(("workspace.%s must be an integer between %d and %d"):format(name, bounds[1], bounds[2]))
      return false
    end
  end
  if options.position ~= "left" and options.position ~= "right" then
    notify("workspace.position must be 'left' or 'right'")
    return false
  end
  return true
end

function M.render()
  if not M.buffer or not vim.api.nvim_buf_is_valid(M.buffer) then
    return
  end
  local session = sessions.sessions[M.term_id]
  local width = config.options.workspace.width
  if M.window and vim.api.nvim_win_is_valid(M.window) then
    width = vim.api.nvim_win_get_width(M.window)
  end
  local lines = { "Julia Workspace | term " .. M.term_id }
  local status = session and session.status or "disconnected"
  local variables = session and session.variables or {}
  lines[2] = ("%s | %d variables%s"):format(status, #variables, session and session.truncated and "+" or "")
  if session and session.updated then
    lines[2] = lines[2] .. " | " .. session.updated
  end
  lines[3] = ""
  if session and session.message then
    table.insert(lines, session.message)
    table.insert(lines, "")
  end
  rows = {}
  local name_lines = {}
  for _, variable in ipairs(variables) do
    name_lines[#lines + 1] = true
    rows[#lines + 1] = variable
    table.insert(lines, variable.name .. " :: " .. variable.type)
    rows[#lines + 1] = variable
    local dimensions = variable.dimensions ~= "" and ("[" .. variable.dimensions .. "] ") or ""
    table.insert(lines, "  " .. dimensions .. variable.value)
  end
  if #variables == 0 and status == "ready" then
    table.insert(lines, "No user variables")
  end
  for index, line in ipairs(lines) do
    lines[index] = fit(line, math.max(8, width - 1))
  end
  vim.bo[M.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(M.buffer, 0, -1, false, lines)
  vim.bo[M.buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buffer, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(M.buffer, namespace, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(M.buffer, namespace, "Comment", 1, 0, -1)
  for line in pairs(name_lines) do
    vim.api.nvim_buf_add_highlight(M.buffer, namespace, "Identifier", line - 1, 0, -1)
  end
  vim.b[M.buffer].coderunner_workspace_term = M.term_id
end

sessions.on_change = function(session)
  if session.term_id == M.term_id then
    M.render()
  end
end

function M.close()
  if M.window and vim.api.nvim_win_is_valid(M.window) then
    vim.api.nvim_win_close(M.window, true)
  end
  M.window = nil
end

function M.inspect()
  local variable = rows[vim.api.nvim_win_get_cursor(0)[1]]
  if not variable then
    return
  end
  local lines = { clean(variable.name), "Type: " .. clean(variable.type) }
  if variable.dimensions ~= "" then
    table.insert(lines, "Size: " .. clean(variable.dimensions))
  end
  table.insert(lines, "")
  table.insert(lines, clean(variable.value))
  vim.lsp.util.open_floating_preview(lines, "text", { border = "single", focus_id = "coderunner.workspace.detail" })
end

function M.refresh(opts)
  opts = opts or {}
  local id = opts.term_id or M.term_id or config.options.term_id
  if not validate(id) then
    return false
  end
  if sessions.refresh(id) then
    return true
  end
  local session, message = sessions.connect(id, opts.attach)
  if not session then
    notify(message)
    return false
  end
  return true
end

function M.open(opts)
  opts = opts or {}
  local id = opts.term_id or config.options.term_id
  local options = config.options.workspace
  if not validate(id) then
    return false
  end
  local session, message = sessions.connect(id, opts.attach)
  if not session then
    notify(message)
    return false
  end
  M.term_id = id
  if not M.buffer or not vim.api.nvim_buf_is_valid(M.buffer) then
    M.buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buffer, "coderunner://workspace")
    vim.bo[M.buffer].buftype = "nofile"
    vim.bo[M.buffer].bufhidden = "hide"
    vim.bo[M.buffer].swapfile = false
    vim.bo[M.buffer].filetype = "coderunner-workspace"
    vim.keymap.set("n", "r", function()
      M.refresh()
    end, { buffer = M.buffer, silent = true, desc = "Refresh Julia workspace" })
    vim.keymap.set("n", "q", M.close, { buffer = M.buffer, silent = true, desc = "Close workspace" })
    vim.keymap.set("n", "<CR>", M.inspect, { buffer = M.buffer, silent = true, desc = "Inspect variable summary" })
  end
  if not M.window or not vim.api.nvim_win_is_valid(M.window) then
    local previous = vim.api.nvim_get_current_win()
    vim.cmd((options.position == "left" and "topleft" or "botright") .. " vertical " .. options.width .. "split")
    M.window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.window, M.buffer)
    vim.wo[M.window].number = false
    vim.wo[M.window].relativenumber = false
    vim.wo[M.window].signcolumn = "no"
    vim.wo[M.window].foldcolumn = "0"
    vim.wo[M.window].wrap = false
    vim.wo[M.window].winfixwidth = true
    vim.wo[M.window].cursorline = true
    vim.api.nvim_set_current_win(previous)
  else
    vim.api.nvim_win_set_buf(M.window, M.buffer)
  end
  M.render()
  if session.authenticated then
    sessions.refresh(id)
  end
  return true
end

function M.command(action, args)
  local opts = {}
  for token in (args or ""):gmatch("%S+") do
    if token == "attach" then
      opts.attach = true
    else
      local id = tonumber(token) or tonumber(token:match("^term=(%d+)$"))
      if not id or id < 1 or id % 1 ~= 0 then
        notify("Expected a positive terminal id, term=N, or attach")
        return false
      end
      opts.term_id = id
    end
  end
  if action == "refresh" then
    return M.refresh(opts)
  elseif action == "disconnect" then
    sessions.disconnect(opts.term_id or M.term_id or config.options.term_id)
    return true
  elseif M.window and vim.api.nvim_win_is_valid(M.window) and (not opts.term_id or opts.term_id == M.term_id) then
    M.close()
    return true
  end
  return M.open(opts)
end

local group = vim.api.nvim_create_augroup("CodeRunnerWorkspace", { clear = true })
local resize_events = { "VimResized" }
if vim.fn.exists("##WinResized") == 1 then
  table.insert(resize_events, "WinResized")
end
vim.api.nvim_create_autocmd(resize_events, { group = group, callback = M.render })

return M
