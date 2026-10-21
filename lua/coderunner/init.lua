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
  julia = {
    function_definition = true,
    macro_definition = true,
    struct_definition = true,
    module_definition = true,
    abstract_definition = true,
    primitive_definition = true,
    arrow_function_expression = true,
  },
}

local JULIA_BLOCK_PARENTS = {
  function_definition = true,
  macro_definition = true,
  struct_definition = true,
  module_definition = true,
  compound_statement = true,
  quote_statement = true,
  let_statement = true,
  if_statement = true,
  elseif_clause = true,
  else_clause = true,
  try_statement = true,
  catch_clause = true,
  finally_clause = true,
  for_statement = true,
  while_statement = true,
  do_clause = true,
}

local JULIA_NON_ITEMS = {
  line_comment = true,
  block_comment = true,
  block = true,
  ERROR = true,
  signature = true,
  type_head = true,
  for_binding = true,
  let_binding = true,
  elseif_clause = true,
  else_clause = true,
  catch_clause = true,
  finally_clause = true,
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

local function send_lines(lines, opts, lang)
  local code = table.concat(lines, "\n")
  if not code:match("%S") then
    notify("No code to send", vim.log.levels.WARN)
    return false
  end

  local toggleterm, terminal = get_toggleterm()
  if not toggleterm then
    return false
  end

  lang = lang or config.get_language(current_filetype())
  code = code .. "\n"
  local term_id = opts.term_id
  local show_terminal = opts.show_terminal

  if terminal.get(term_id, true) == nil then
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

local function send_range(start_line, end_line, opts)
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local lang = config.get_language(current_filetype())
  return send_lines(filter_lines(lines, lang), opts, lang)
end

local function selection_lines(range)
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]

  if range and (range[1] ~= first or range[2] ~= last) then
    return vim.api.nvim_buf_get_lines(0, range[1] - 1, range[2], false)
  end
  if not visual and (first == 0 or last == 0) then
    notify("No visual selection available", vim.log.levels.WARN)
    return nil
  end

  -- Native yanking handles tabs, Unicode, exclusive and blockwise selections.
  local register = vim.fn.getreginfo("z")
  local unnamed = vim.fn.getreginfo('"')
  local clipboard = vim.o.clipboard
  local view = vim.fn.winsaveview()
  vim.o.clipboard = ""
  local ok, lines = pcall(function()
    vim.cmd("silent noautocmd keepjumps normal! " .. (visual and "" or "gv") .. '"zy')
    return vim.fn.getreg("z", 1, true)
  end)
  vim.fn.setreg("z", register)
  vim.fn.setreg('"', unnamed)
  vim.o.clipboard = clipboard
  vim.fn.winrestview(view)

  if not ok then
    notify("Unable to read visual selection: " .. tostring(lines), vim.log.levels.ERROR)
    return nil
  end
  return lines
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

  if row == end_row and col >= end_col then
    return false
  end

  return true
end

local function is_candidate(node, filetype)
  if filetype ~= "julia" then
    return (NODE_TYPES[filetype] or {})[node:type()]
  end

  local parent = node:parent()
  if not parent or not node:named() or JULIA_NON_ITEMS[node:type()] then
    return false
  end
  local parent_type = parent:type()
  if parent_type == "source_file" or parent_type == "block" then
    return true
  end

  -- Older Julia parsers inline block bodies into their owning statements.
  if not JULIA_BLOCK_PARENTS[parent_type] then
    return false
  end
  if node == parent:field("condition")[1] or node == parent:field("name")[1] then
    return false
  end
  if parent_type == "let_statement" or parent_type == "do_clause" or parent_type == "catch_clause" then
    local row = node:range()
    local parent_row = parent:range()
    return row > parent_row
  end
  return true
end

local function is_container(node, filetype)
  if (CONTAINER_NODE_TYPES[filetype] or {})[node:type()] then
    return true
  end
  if filetype ~= "julia" then
    return false
  end

  if node:type() == "assignment" then
    local signature = node:named_child(0)
    while signature and (signature:type() == "where_expression" or signature:type() == "typed_expression") do
      signature = signature:named_child(0)
    end
    if signature and signature:type() == "call_expression" then
      return true
    end
  elseif node:type() == "call_expression" or node:type() == "broadcast_call_expression" then
    for child in node:iter_children() do
      if child:type() == "do_clause" then
        return true
      end
    end
  end
  return false
end

local function include_wrappers(node, filetype)
  if filetype == "julia" then
    local parent = node:parent()
    -- Keep macro wrappers and assignments around anonymous/short-form functions.
    while parent and not is_candidate(node, filetype) do
      node = parent
      parent = node:parent()
    end
    return node
  end

  local parent = node:parent()
  if parent and parent:type() == "decorated_definition" then
    return parent
  end

  return node
end

local function smallest_candidate_at_cursor(root, filetype, row, col)
  local best_container
  local best_statement

  local function visit(node)
    if not node_contains_cursor(node, row, col) then
      return
    end

    if is_container(node, filetype) then
      best_container = include_wrappers(node, filetype)
    elseif is_candidate(node, filetype) then
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
  local best

  local function visit(node)
    local start_row, start_col = node:range()

    if is_candidate(node, filetype) and (start_row > row or (start_row == row and start_col >= col)) then
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
  if filetype ~= "python" and filetype ~= "julia" then
    notify("Tree-sitter execution is not supported for filetype '" .. filetype .. "'", vim.log.levels.WARN)
    return nil
  end
  local root = get_parser_root(bufnr, filetype)
  if not root then
    notify("Tree-sitter parser is not available for current buffer", vim.log.levels.ERROR)
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = vim.api.nvim_get_current_line()
  if line:sub(1, col):match("^%s*$") then
    col = math.max(col, #(line:match("^%s*") or ""))
  end
  local node = smallest_candidate_at_cursor(root, filetype, row, col)

  if not node then
    notify("No Tree-sitter code item found at cursor", vim.log.levels.WARN)
    return nil
  end

  local start_row, _, end_row, end_col = node:range()
  local end_line = end_col == 0 and end_row or end_row + 1
  return start_row + 1, end_line, root, filetype, node
end

local function jump_to_next_treesitter_item(root, filetype, end_line, current_node)
  local _, _, end_row, end_col = current_node:range()
  local node = next_candidate_after(root, filetype, end_row, end_col)
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
  if opts.jump then
    jump_to_line(end_line + 1)
  end
  send_range(start_line, end_line, opts)
end

function M.run_current_line(opts)
  opts = normalize_opts(opts)
  if not ensure_enabled() then
    return
  end

  local start_line, end_line, root, filetype, node = find_treesitter_range()
  if not start_line then
    return
  end
  local start_row, start_col, end_row, end_col = node:range()
  local first_line = vim.api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  if first_line:sub(1, start_col):match("^%s*$") then
    start_col = 0
  end
  local lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
  if opts.jump then
    jump_to_next_treesitter_item(root, filetype, end_line, node)
  end

  return send_lines(lines, opts)
end

function M.send_selection(opts, range)
  opts = normalize_opts(opts)
  local lines = selection_lines(range)
  if not lines then
    return false
  end
  -- Unknown filetypes use the existing terminal/default shell, not Python's REPL.
  local lang = config.options.languages[current_filetype()] or {}
  return send_lines(lines, opts, lang)
end

function M.run_command(kind, args)
  local opts = parse_args(args or "")

  if kind == "selection" then
    return M.send_selection(opts)
  elseif kind == "line" then
    return M.run_current_line(opts)
  else
    return M.send_current_block(opts)
  end
end

function M.run_block(args)
  M.run_command("block", args)
end

function M.run_line(args)
  M.run_command("line", args)
end

function M.run_selection(args)
  return M.run_command("selection", args)
end

local function command_complete()
  return {
    "show",
    "show=true",
    "show=false",
    "hide",
    "jump",
    "jump=true",
    "jump=false",
    "nojump",
    "term=1",
  }
end

function M.register_commands()
  vim.api.nvim_create_user_command("CodeRunSelection", function(opts)
    local range = opts.range > 0 and { opts.line1, opts.line2 } or nil
    M.send_selection(parse_args(opts.args), range)
  end, {
    force = true,
    nargs = "*",
    range = true,
    complete = command_complete,
    desc = "Send the visual selection to toggleterm without changing whitespace",
  })

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
