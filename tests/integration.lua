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
  assert(values.workspace_scalar.value == "99")
  print("PASS Julia workspace: reconnect to an existing Julia process")
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
