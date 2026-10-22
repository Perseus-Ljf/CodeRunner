local config = require("coderunner.config")
local sessions = require("coderunner.julia_session")
local M = {}
local namespace = vim.api.nvim_create_namespace("coderunner.workspace")
local rows = {}
local last_buffer, last_lines, last_tick
local closed_marker, open_marker = vim.fn.nr2char(9656), vim.fn.nr2char(9662)

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
  if width <= 3 then
    return vim.fn.strdisplaywidth(text) <= width and text or string.rep(".", math.max(0, width))
  end
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

local function pad(text, width)
  local clipped = fit(text, width)
  return clipped .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(clipped)))
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
    max_children = { 1, 500 },
    refresh_delay = { 0, 5000 },
  }) do
    local value = options[name]
    if type(value) ~= "number" or value % 1 ~= 0 or value < bounds[1] or value > bounds[2] then
      notify(("workspace.%s must be an integer between %d and %d"):format(name, bounds[1], bounds[2]))
      return false
    end
  end
  if type(options.auto_refresh) ~= "boolean" then
    notify("workspace.auto_refresh must be a boolean")
    return false
  end
  if options.position ~= "left" and options.position ~= "right" then
    notify("workspace.position must be 'left' or 'right'")
    return false
  end
  return true
end

local function window_valid()
  return M.window and vim.api.nvim_win_is_valid(M.window)
end

local function selected()
  if window_valid() then
    local row = rows[vim.api.nvim_win_get_cursor(M.window)[1]]
    return row and row.node
  end
end

function M.render()
  if not M.buffer or not vim.api.nvim_buf_is_valid(M.buffer) or not M.term_id then
    return
  end
  local session = sessions.sessions[M.term_id]
  local width = config.options.workspace.width
  local view
  if window_valid() then
    width = vim.api.nvim_win_get_width(M.window)
    local node = selected()
    view = vim.api.nvim_win_call(M.window, vim.fn.winsaveview)
    if node and (node.path ~= M.rendered_selection or node.path == M.preferred_path) then
      M.preferred_path = node.path
      M.preferred_offset = view.lnum - view.topline
    end
  end
  local usable = math.max(8, width - 1)
  local width_rules = vim.o.ambiwidth .. vim.fn.string(vim.fn.getcellwidths())
  local columns = usable >= 42
  local name_width = math.floor(usable * 0.38)
  local type_width = math.floor(usable * 0.25)
  local value_width = usable - name_width - type_width - 4
  local function cells(name, value, type)
    if not columns then
      return fit(name .. (value ~= "" and "  " .. value or ""), usable)
    end
    local first = pad(name, name_width) .. "  "
    local second = pad(value, value_width) .. "  "
    return first .. second .. fit(type, type_width), #first, #first + #second
  end
  local variables = session and session.variables or {}
  local status = session and session.status or "disconnected"
  local auto = config.options.workspace.auto_refresh and session and session.auto_supported
  local lines = {
    "Julia Workspace",
    ("Main | term %d | %s"):format(M.term_id, auto and "Auto" or "Manual"),
    ("%s  %d variables%s%s"):format(
      status:gsub("^%l", string.upper),
      #variables,
      session and session.truncated and "+" or "",
      session and session.updated and "  " .. session.updated or ""
    ),
    "",
    columns and cells("VARIABLE", "VALUE / SIZE", "TYPE") or "VARIABLE / VALUE",
    string.rep("-", usable),
  }
  local highlights, new_rows = {}, {}
  if session and session.message then
    table.insert(lines, session.message)
  end
  for index, line in ipairs(lines) do
    lines[index] = fit(line, usable)
  end
  local function append(nodes, depth)
    for _, node in ipairs(nodes) do
      local expanded = not not session.expanded[node.path]
      -- Snapshot nodes own their formatting cache; a refresh replaces the nodes.
      local display = node._workspace_display
      if
        not display
        or display.width ~= usable
        or display.width_rules ~= width_rules
        or display.depth ~= depth
        or display.expanded ~= expanded
        or display.name ~= node.name
        or display.value ~= node.value
        or display.type ~= node.type
        or display.dimensions ~= node.dimensions
        or display.expandable ~= node.expandable
      then
        local marker = node.expandable and (expanded and open_marker or closed_marker) or " "
        local name = string.rep("  ", depth) .. marker .. " " .. node.name
        local value = node.dimensions ~= "" and ("[" .. node.dimensions .. "] " .. node.value) or node.value
        local display_type = node.type
        if display_type:match("^[%a_][%w_%.]*$") then
          display_type = display_type:match("([%w_]+)$")
        end
        local line, value_start, type_start = cells(name, value, display_type)
        display = {
          width = usable,
          width_rules = width_rules,
          depth = depth,
          expanded = expanded,
          name = node.name,
          value = node.value,
          type = node.type,
          dimensions = node.dimensions,
          expandable = node.expandable,
          line = line,
          value_start = value_start,
          type_start = type_start,
        }
        node._workspace_display = display
      end
      table.insert(lines, display.line)
      new_rows[#lines] = { node = node, depth = depth }
      if columns then
        highlights[#lines] = display
      end
      if node.expandable and expanded then
        if node.children then
          append(node.children, depth + 1)
          if node.truncated then
            table.insert(lines, fit(string.rep("  ", depth + 1) .. "  ... more children omitted", usable))
          end
        elseif node.error then
          table.insert(lines, fit(string.rep("  ", depth + 1) .. "  " .. node.error, usable))
        else
          table.insert(
            lines,
            fit(string.rep("  ", depth + 1) .. (session.authenticated and "  Loading..." or "  Disconnected"), usable)
          )
        end
      end
    end
  end
  append(variables, 0)
  if #variables == 0 and status == "ready" then
    table.insert(lines, fit("No user variables", usable))
  end
  rows = new_rows
  local changed = last_buffer ~= M.buffer
    or last_tick ~= vim.api.nvim_buf_get_changedtick(M.buffer)
    or not last_lines
    or #last_lines ~= #lines
  if not changed then
    for index, line in ipairs(lines) do
      if last_lines[index] ~= line then
        changed = true
        break
      end
    end
  end
  if changed then
    vim.bo[M.buffer].modifiable = true
    vim.api.nvim_buf_set_lines(M.buffer, 0, -1, false, lines)
    vim.bo[M.buffer].modifiable = false
    vim.api.nvim_buf_clear_namespace(M.buffer, namespace, 0, -1)
    for _, item in ipairs({ { 0, "Title" }, { 1, "Comment" }, { 2, "Comment" }, { 4, "Comment" }, { 5, "Comment" } }) do
      vim.api.nvim_buf_add_highlight(M.buffer, namespace, item[2], item[1], 0, -1)
    end
    for line, spans in pairs(highlights) do
      vim.api.nvim_buf_add_highlight(M.buffer, namespace, "Identifier", line - 1, 0, spans.value_start)
      local group = spans.type == "String" and "String" or "Normal"
      vim.api.nvim_buf_add_highlight(M.buffer, namespace, group, line - 1, spans.value_start, spans.type_start)
      vim.api.nvim_buf_add_highlight(M.buffer, namespace, "Type", line - 1, spans.type_start, -1)
    end
    last_buffer, last_lines = M.buffer, lines
    last_tick = vim.api.nvim_buf_get_changedtick(M.buffer)
  end
  vim.b[M.buffer].coderunner_workspace_term = M.term_id
  if view then
    local target, best = nil, 0
    for line, row in pairs(rows) do
      local path = row.node.path
      if M.preferred_path == path then
        target, best = line, math.huge
      elseif M.preferred_path and M.preferred_path:sub(1, #path + 1) == path .. "/" and #path > best then
        target, best = line, #path
      end
    end
    if M.initial_cursor and next(rows) then
      for line in pairs(rows) do
        target = target and math.min(target, line) or line
      end
      M.preferred_path = rows[target].node.path
      M.preferred_offset = target - 1
      M.initial_cursor = false
    end
    view.lnum = target or math.min(view.lnum, #lines)
    if target and M.preferred_offset then
      view.topline = math.max(1, target - M.preferred_offset)
    end
    view.col = math.min(view.col, #lines[view.lnum])
    vim.api.nvim_win_call(M.window, function()
      vim.fn.winrestview(view)
    end)
    M.rendered_selection = rows[view.lnum] and rows[view.lnum].node.path
    if session and not session.pending and not session.dirty and not session.auto_timer then
      M.preferred_path = M.rendered_selection
    end
  end
end

sessions.on_change = function(session)
  if session.term_id == M.term_id then
    M.render()
  end
end

function M.close()
  if window_valid() then
    local tab = vim.api.nvim_win_get_tabpage(M.window)
    local normal_windows = 0
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(window).relative == "" then
        normal_windows = normal_windows + 1
      end
    end
    if normal_windows == 1 then
      vim.api.nvim_win_set_buf(M.window, vim.api.nvim_create_buf(true, false))
      vim.wo[M.window].winfixwidth = false
    else
      vim.api.nvim_win_close(M.window, true)
    end
  end
  M.window = nil
end

function M.inspect()
  local node = selected()
  if not node then
    return
  end
  local lines = { clean(node.name), "Type: " .. clean(node.type) }
  if node.dimensions ~= "" then
    table.insert(lines, "Size: " .. clean(node.dimensions))
  end
  table.insert(lines, "")
  table.insert(lines, clean(node.value))
  vim.lsp.util.open_floating_preview(lines, "text", { border = "single", focus_id = "coderunner.workspace.detail" })
end

function M.toggle_node()
  local node = selected()
  local session = sessions.sessions[M.term_id]
  if node and node.expandable then
    return sessions.expand(M.term_id, node, not session.expanded[node.path])
  end
  M.inspect()
end

local function move_tree(expand)
  local node = selected()
  local session = sessions.sessions[M.term_id]
  if not node then
    return
  end
  if node.expandable and (not not session.expanded[node.path]) ~= expand then
    sessions.expand(M.term_id, node, expand)
  elseif not expand and node.parent then
    for line, row in pairs(rows) do
      if row.node == node.parent then
        vim.api.nvim_win_set_cursor(M.window, { line, 0 })
        break
      end
    end
  elseif expand and node.children and #node.children > 0 then
    for line, row in pairs(rows) do
      if row.node == node.children[1] then
        vim.api.nvim_win_set_cursor(M.window, { line, 0 })
        break
      end
    end
  end
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
  if M.term_id ~= id then
    M.preferred_path, M.rendered_selection, M.preferred_offset = nil, nil, nil
    M.initial_cursor, rows = true, {}
  end
  M.term_id = id
  if not M.buffer or not vim.api.nvim_buf_is_valid(M.buffer) then
    M.buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buffer, "coderunner://workspace")
    vim.bo[M.buffer].buftype = "nofile"
    vim.bo[M.buffer].bufhidden = "hide"
    vim.bo[M.buffer].swapfile = false
    vim.bo[M.buffer].filetype = "coderunner-workspace"
    local mappings = {
      r = {
        function()
          M.refresh()
        end,
        "Refresh Julia workspace",
      },
      q = { M.close, "Close workspace" },
      ["<CR>"] = { M.toggle_node, "Expand or inspect variable" },
      ["<Space>"] = { M.toggle_node, "Expand or inspect variable" },
      K = { M.inspect, "Inspect variable summary" },
      l = {
        function()
          move_tree(true)
        end,
        "Expand node",
      },
      h = {
        function()
          move_tree(false)
        end,
        "Collapse node or go to parent",
      },
      ["<Right>"] = {
        function()
          move_tree(true)
        end,
        "Expand node",
      },
      ["<Left>"] = {
        function()
          move_tree(false)
        end,
        "Collapse node or go to parent",
      },
    }
    for key, mapping in pairs(mappings) do
      vim.keymap.set("n", key, mapping[1], { buffer = M.buffer, silent = true, desc = mapping[2] })
    end
  end
  if window_valid() and vim.api.nvim_win_get_tabpage(M.window) ~= vim.api.nvim_get_current_tabpage() then
    M.close()
  end
  if not window_valid() then
    M.initial_cursor = M.preferred_path == nil
    local previous = vim.api.nvim_get_current_win()
    local width = math.min(options.width, math.max(24, math.floor(vim.o.columns / 2)))
    vim.cmd((options.position == "left" and "topleft" or "botright") .. " vertical " .. width .. "split")
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
  elseif
    window_valid()
    and vim.api.nvim_win_get_tabpage(M.window) == vim.api.nvim_get_current_tabpage()
    and (not opts.term_id or opts.term_id == M.term_id)
  then
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
