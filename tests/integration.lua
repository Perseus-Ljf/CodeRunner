vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/tests/.deps")
vim.opt.runtimepath:prepend(vim.env.TOGGLETERM_RTP or (vim.fn.stdpath("data") .. "/site/pack/core/opt/toggleterm.nvim"))
vim.o.swapfile = false

local runner = require("coderunner")
local terminal = require("toggleterm.terminal")
require("toggleterm").setup({ start_in_insert = false, shade_terminals = false })
runner.setup({
  enabled_filetypes = { "julia" },
  startup_delay = 2000,
  show_terminal = false,
  jump = false,
  languages = {
    julia = { start_cmd = "julia --startup-file=no --history-file=no --color=no" },
  },
})

local function buffer(filetype, lines)
  vim.cmd("enew!")
  vim.bo.filetype = filetype
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end
local function output(id)
  local term = terminal.get(id, true)
  if not term or not term.bufnr then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false), "\n")
end
local function wait_for(id, text)
  assert(
    vim.wait(30000, function()
      return output(id):find(text, 1, true) ~= nil
    end, 50),
    "Terminal did not produce " .. text .. ":\n" .. output(id)
  )
end
local function select_all(args)
  vim.cmd("normal! ggVG")
  assert(runner.run_selection(args))
end

local ok, err = xpcall(function()
  buffer("julia", { "@inline function coderunner_test(x)", "    x + 1", "end" })
  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  runner.run_line("term=91 hide nojump")
  wait_for(91, "coderunner_test (generic function with 1 method)")

  buffer("julia", { 'println("TREE_RESULT_", coderunner_test(41))' })
  runner.run_line("term=91 hide nojump")
  wait_for(91, "TREE_RESULT_42")
  print("PASS real Julia REPL: macro-wrapped function and statement")

  buffer("julia", {
    "function visual_test(x)",
    "    #= retained block comment",
    "    not Julia code =#",
    "",
    "    x * 2",
    "end",
    'println("VISUAL_RESULT_", visual_test(21))',
  })
  select_all("term=91 hide")
  wait_for(91, "VISUAL_RESULT_42")
  assert(not output(91):find("ERROR:", 1, true), output(91))
  print("PASS real Julia REPL: visual function with indentation and block comment")

  buffer("sh", { "printf 'SHELL_RESULT_%s\\n' 42" })
  select_all("term=92 hide")
  wait_for(92, "SHELL_RESULT_42")
  print("PASS real shell: visual selection for a filetype outside enabled_filetypes")

  local workspace = require("coderunner.workspace")
  local sessions = require("coderunner.julia_session")
  buffer("julia", {
    "workspace_scalar = 42",
    "workspace_matrix = reshape(collect(1:6), 2, 3)",
    'workspace_unicode = "' .. vim.fn.nr2char(20320) .. vim.fn.nr2char(22909) .. '"',
    "workspace_undef = Vector{String}(undef, 2)",
  })
  select_all("term=91 hide")
  assert(workspace.open({ term_id = 91 }))
  local function snapshot(id)
    assert(
      vim.wait(30000, function()
        local state = sessions.sessions[id]
        return state and state.status == "ready"
      end, 20),
      vim.inspect(sessions.sessions[id]) .. "\n" .. output(id)
    )
    local values = {}
    for _, item in ipairs(sessions.sessions[id].variables) do
      values[item.name] = item
    end
    return values
  end
  local values = snapshot(91)
  assert(values.workspace_scalar.value == "42", vim.inspect(values))
  assert(values.workspace_matrix.dimensions == "2 x 3")
  assert(values.workspace_matrix.type == "Matrix{Int64}")
  assert(values.workspace_unicode.value:find(vim.fn.nr2char(20320), 1, true))
  assert(values.workspace_undef.value == "[#undef, #undef]")
  assert(not values.CodeRunnerWorkspace)
  assert(vim.bo[workspace.buffer].modifiable == false)
  assert(vim.b[workspace.buffer].coderunner_workspace_term == 91)
  print("PASS Julia workspace: real same-process snapshot, dimensions, Unicode and undef")

  buffer("julia", { "workspace_scalar = 99", 'println("WORKSPACE_CHANGED")' })
  select_all("term=91 hide")
  wait_for(91, "WORKSPACE_CHANGED")
  assert(workspace.refresh({ term_id = 91 }))
  values = snapshot(91)
  assert(values.workspace_scalar.value == "99")
  print("PASS Julia workspace: refresh reflects mutated REPL state")

  local function variable(id, name)
    for _, item in ipairs(sessions.sessions[id].variables) do
      if item.name == name then
        return item
      end
    end
  end
  local function await_value(id, name, expected)
    assert(
      vim.wait(15000, function()
        local item = variable(id, name)
        return item and item.value == expected and sessions.sessions[id].status == "ready"
      end, 20),
      "Missing automatic update for "
        .. name
        .. " ("
        .. vim.inspect(variable(id, name))
        .. "; "
        .. sessions.sessions[id].status
        .. "; "
        .. tostring(sessions.sessions[id].message)
        .. ")\n"
        .. output(id)
    )
  end
  assert(sessions.sessions[91].auto_supported)
  buffer("julia", { "workspace_scalar = 101" })
  runner.run_line("term=91 hide nojump")
  await_value(91, "workspace_scalar", "101")
  buffer("julia", { "# %%", "workspace_scalar = 102" })
  runner.run_block("term=91 hide nojump")
  await_value(91, "workspace_scalar", "102")
  buffer("julia", { "workspace_scalar = 103" })
  select_all("term=91 hide")
  await_value(91, "workspace_scalar", "103")
  print("PASS Julia workspace: line, block and selection automatically refresh")

  local repl = terminal.get(91, true)
  repl:send("workspace_scalar = 202", true)
  await_value(91, "workspace_scalar", "202")
  repl:send("41 + 1", true)
  repl:send('println("ANS_RESULT_", ans)', true)
  wait_for(91, "ANS_RESULT_42")
  repl:send("begin\nworkspace_total = 0\nfor i in 1:4\nworkspace_total += i\nend\nend", true)
  await_value(91, "workspace_total", "10")
  repl:send('begin workspace_partial = 7; error("WORKSPACE_INTENTIONAL_ERROR") end;', true)
  await_value(91, "workspace_partial", "7")
  print("PASS Julia workspace: manual input, ans, soft scope and error completion")

  repl:send(
    'struct WorkspaceAddress; city::String; end; mutable struct WorkspacePerson; name::String; address::WorkspaceAddress; values::Vector{Int}; end; workspace_person = WorkspacePerson("Ada", WorkspaceAddress("Paris"), [1, 2, 3]);',
    true
  )
  await_value(91, "workspace_person", "3 fields")
  local person = variable(91, "workspace_person")
  assert(person.expandable)
  assert(sessions.expand(91, person, true))
  assert(vim.wait(5000, function()
    return person.children ~= nil
  end, 20))
  assert(person.children[1].name == "name" and person.children[1].value == '"Ada"')
  local address = person.children[2]
  assert(address.name == "address" and address.expandable)
  assert(sessions.expand(91, address, true))
  assert(vim.wait(5000, function()
    return address.children ~= nil
  end, 20))
  assert(address.children[1].value == '"Paris"')
  repl:send('workspace_person.address = WorkspaceAddress("Rome");', true)
  assert(
    vim.wait(15000, function()
      local fresh = variable(91, "workspace_person")
      local child = fresh and fresh.children and fresh.children[2]
      return child and child.children and child.children[1].value == '"Rome"'
    end, 20),
    output(91)
  )
  print("PASS Julia workspace: real nested structs and expanded fields update automatically")

  assert(vim.wait(5000, function()
    return sessions.sessions[91].status == "ready"
  end, 20))
  local config = require("coderunner.config")
  config.options.workspace.auto_refresh = false
  local sequence = sessions.sessions[91].sequence
  repl:send('workspace_scalar = 303; println("MANUAL_MODE_DONE")', true)
  wait_for(91, "MANUAL_MODE_DONE")
  vim.wait(400, function()
    return false
  end, 20)
  assert(sessions.sessions[91].sequence == sequence)
  assert(variable(91, "workspace_scalar").value == "202")
  config.options.workspace.auto_refresh = true
  assert(workspace.refresh({ term_id = 91 }))
  await_value(91, "workspace_scalar", "303")
  print("PASS Julia workspace: automatic refresh can be disabled")

  assert(not workspace.open({ term_id = 92 }))
  assert(not sessions.sessions[92], "Shell must not receive Julia bootstrap")
  workspace.close()
  assert(workspace.open({ term_id = 93 }))
  values = snapshot(93)
  assert(not values.workspace_scalar, "New Julia process must not inherit another workspace")
  print("PASS Julia workspace: new process startup and terminal isolation")

  workspace.close()
  sessions.disconnect(91)
  assert(workspace.open({ term_id = 91, attach = true }))
  values = snapshot(91)
  assert(values.workspace_scalar.value == "303")
  repl:send(
    'println("HOOK_COUNT_", count(h -> h === CodeRunnerWorkspace.transform, Base.active_repl_backend.ast_transforms))',
    true
  )
  wait_for(91, "HOOK_COUNT_1")
  print("PASS Julia workspace: reconnect to an existing Julia process without duplicate hooks")
  workspace.close()
  terminal.get(91, true):shutdown()
  assert(vim.wait(5000, function()
    return sessions.sessions[91].status == "disconnected"
  end, 20))
  print("PASS Julia workspace: terminal exit disconnects the session")
end, debug.traceback)

for _, id in ipairs({ 91, 92, 93 }) do
  local term = terminal.get(id, true)
  if term then
    term:shutdown()
  end
end
if not ok then
  print(err)
end
vim.cmd(ok and "qa!" or "cquit 1")
