local config = require("coderunner.config")

local M = {}

local NODE_TYPES = {
  python = {
    decorated_definition = true,
    class_definition = true,
    function_definition = true,
    async_function_definition = true,
    if_statement = true,
    elif_clause = true,
    else_clause = true,
    for_statement = true,
    while_statement = true,
    try_statement = true,
    except_clause = true,
    finally_clause = true,
    with_statement = true,
    match_statement = true,
    import_statement = true,
    import_from_statement = true,
    expression_statement = true,
    assignment = true,
    augmented_assignment = true,
    return_statement = true,
    raise_statement = true,
    assert_statement = true,
    delete_statement = true,
    pass_statement = true,
    break_statement = true,
    continue_statement = true,
    global_statement = true,
    nonlocal_statement = true,
  },
}

local CONTAINER_NODE_TYPES = {
  python = {
    decorated_definition = true,
    class_definition = true,
    function_definition = true,
    async_function_definition = true,
  },
}

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

local function current_filetype()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype
end

local function ensure_enabled()
  local filetype = current_filetype()
  if config.is_enabled_filetype(filetype) then
    return true
  end

  notify(("CodeRunner is not enabled for filetype '%s'"):format(filetype), vim.log.levels.WARN)
  return false
end

local function parse_args(args)
  local opts = {
    term_id = config.options.term_id,
    show_terminal = config.options.show_terminal,
    jump = config.options.jump,
  }

  for token in args:gmatch("%S+") do
    local key, value = token:match("^([%w_%-]+)=(.+)$")

    if tonumber(token) then
      opts.term_id = tonumber(token)
    elseif token == "show" or token == "open" then
      opts.show_terminal = true
    elseif token == "hide" or token == "closed" then
      opts.show_terminal = false
    elseif token == "jump" or token == "next" then
      opts.jump = true
    elseif token == "nojump" or token == "stay" then
      opts.jump = false
    elseif key == "term" or key == "term_id" or key == "id" then
      opts.term_id = tonumber(value) or opts.term_id
    elseif key == "show" or key == "open" then
      opts.show_terminal = value == "true" or value == "1" or value == "yes"
    elseif key == "jump" then
      opts.jump = value == "true" or value == "1" or value == "yes"
    end
  end

  return opts
end

local function normalize_opts(opts)
  opts = opts or {}
  return {
    term_id = opts.term_id or config.options.term_id,
    show_terminal = vim.F.if_nil(opts.show_terminal, config.options.show_terminal),
    jump = vim.F.if_nil(opts.jump, config.options.jump),
  }
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

local function send_range(start_line, end_line, opts)
  local toggleterm, terminal = get_toggleterm()
  if not toggleterm then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local lang = config.get_language(vim.bo.filetype)
  local filtered_lines = filter_lines(lines, lang)

  if #filtered_lines == 0 then
    notify("Current cell is empty", vim.log.levels.WARN)
    return false
  end

  local code = table.concat(filtered_lines, "\n") .. "\n"
  local term_id = opts.term_id or config.options.term_id
  local show_terminal = opts.show_terminal

  if terminal.get(term_id, true) == nil or terminal.get(term_id, false) == nil then
    if lang.start_cmd and lang.start_cmd ~= "" then
      toggleterm.exec(lang.start_cmd, term_id, nil, nil, nil, nil, true, show_terminal)
    end
    vim.defer_fn(function()
      toggleterm.exec(code, term_id, nil, nil, nil, nil, true, show_terminal)
    end, config.options.startup_delay)
  else
    toggleterm.exec(code, term_id, nil, nil, nil, nil, true, show_terminal)
  end

  return true
end

local function jump_to_line(line_nr)
  local last_line = vim.api.nvim_buf_line_count(0)
  local target_line = math.max(1, math.min(line_nr, last_line))

  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd("normal! zz")
end

local function get_parser_root(bufnr, filetype)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, filetype)
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  return tree and tree:root() or nil
end

local function node_contains_cursor(node, row, col)
  local start_row, start_col, end_row, end_col = node:range()

  if row < start_row or row > end_row then
    return false
  end

  if row == start_row and col < start_col then
    return false
  end

  if row == end_row and col > end_col then
    return false
  end

  return true
end

local function candidate_types(filetype)
  return NODE_TYPES[filetype] or NODE_TYPES.python
end

local function container_types(filetype)
  return CONTAINER_NODE_TYPES[filetype] or CONTAINER_NODE_TYPES.python
end

local function include_decorators(node)
  local parent = node:parent()
  if parent and parent:type() == "decorated_definition" then
    return parent
  end

  return node
end

local function smallest_candidate_at_cursor(root, filetype, row, col)
  local types = candidate_types(filetype)
  local containers = container_types(filetype)
  local best_container
  local best_statement

  local function visit(node)
    if not node_contains_cursor(node, row, col) then
      return
    end

    local node_type = node:type()
    if containers[node_type] then
      best_container = include_decorators(node)
    elseif types[node_type] then
      best_statement = node
    end

    for child in node:iter_children() do
      visit(child)
    end
  end

  visit(root)
  return best_container or best_statement
end

local function next_candidate_after(root, filetype, row, col)
  local types = candidate_types(filetype)
  local best

  local function visit(node)
    local start_row, start_col = node:range()

    if types[node:type()] and (start_row > row or (start_row == row and start_col > col)) then
      if not best then
        best = node
      else
        local best_row, best_col = best:range()
        if start_row < best_row or (start_row == best_row and start_col < best_col) then
          best = node
        end
      end
    end

    for child in node:iter_children() do
      visit(child)
    end
  end

  visit(root)
  return best
end

local function find_treesitter_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local filetype = current_filetype()
  local root = get_parser_root(bufnr, filetype)
  if not root then
    notify("Tree-sitter parser is not available for current buffer", vim.log.levels.ERROR)
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local node = smallest_candidate_at_cursor(root, filetype, row, col)

  if not node then
    notify("No Tree-sitter code item found at cursor", vim.log.levels.WARN)
    return nil
  end

  local start_row, _, end_row = node:range()
  return start_row + 1, end_row + 1, root, filetype
end

local function jump_to_next_treesitter_item(root, filetype, end_line)
  local node = next_candidate_after(root, filetype, end_line - 1, 0)
  if not node then
    jump_to_line(end_line + 1)
    return
  end

  local start_row = node:range()
  jump_to_line(start_row + 1)
end

function M.send_current_block(opts)
  opts = normalize_opts(opts)
  if not ensure_enabled() then
    return
  end

  local start_line, end_line = find_cell_range()
  local sent = send_range(start_line, end_line, opts)

  if sent and opts.jump then
    jump_to_line(end_line + 1)
  end
end

function M.run_current_line(opts)
  opts = normalize_opts(opts)
  if not ensure_enabled() then
    return
  end

  local start_line, end_line, root, filetype = find_treesitter_range()
  if not start_line then
    return
  end

  local sent = send_range(start_line, end_line, opts)

  if sent and opts.jump then
    jump_to_next_treesitter_item(root, filetype, end_line)
  end
end

function M.run_command(kind, args)
  local opts = parse_args(args or "")

  if kind == "line" then
    M.run_current_line(opts)
  else
    M.send_current_block(opts)
  end
end

local function command_complete()
  return {
    "show",
    "hide",
    "jump",
    "nojump",
    "term=1",
  }
end

function M.register_commands()
  vim.api.nvim_create_user_command("CodeRunBlock", function(opts)
    M.run_command("block", opts.args)
  end, {
    force = true,
    nargs = "*",
    complete = command_complete,
    desc = "Send the current code cell to toggleterm",
  })

  vim.api.nvim_create_user_command("CodeRunCell", function(opts)
    M.run_command("block", opts.args)
  end, {
    force = true,
    nargs = "*",
    complete = command_complete,
    desc = "Send the current code cell to toggleterm",
  })

  vim.api.nvim_create_user_command("CodeRunCurrentLine", function(opts)
    M.run_command("line", opts.args)
  end, {
    force = true,
    nargs = "*",
    complete = command_complete,
    desc = "Send the current Tree-sitter code item to toggleterm",
  })

  vim.api.nvim_create_user_command("RunCurrentLine", function(opts)
    M.run_command("line", opts.args)
  end, {
    force = true,
    nargs = "*",
    complete = command_complete,
    desc = "Send the current Tree-sitter code item to toggleterm",
  })
end

function M.setup(opts)
  config.setup(opts)
  M.register_commands()
end

return M
