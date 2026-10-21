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
end, debug.traceback)

for _, id in ipairs({ 91, 92 }) do
  local term = terminal.get(id, true)
  if term then
    term:shutdown()
  end
end
if not ok then
  print(err)
end
vim.cmd(ok and "qa!" or "cquit 1")
