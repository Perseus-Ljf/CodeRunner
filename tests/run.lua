vim.opt.runtimepath:prepend(vim.fn.getcwd())
if vim.env.CODERUNNER_TEST_SYSTEM_PARSERS ~= "1" then
  vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/tests/.deps")
end
vim.o.swapfile = false
vim.o.clipboard = ""

local runner = require("coderunner")
local calls, deferred, messages
local exists = true
package.loaded.toggleterm = {
  exec = function(code, id, _, _, _, _, go_back, show)
    calls[#calls + 1] = { code = code, id = id, go_back = go_back, show = show }
    exists = true
  end,
}
package.loaded["toggleterm.terminal"] = {
  get = function(_, include_hidden)
    return exists and include_hidden and {} or nil
  end,
}
vim.defer_fn = function(callback, delay)
  deferred[#deferred + 1] = { callback = callback, delay = delay }
end
vim.notify = function(message)
  messages[#messages + 1] = message
end

local passed, failed = 0, 0
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function reset(filetype, lines, opts)
  vim.cmd("enew!")
  vim.bo.filetype = filetype
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_buf_set_mark(0, "<", 0, 0, {})
  vim.api.nvim_buf_set_mark(0, ">", 0, 0, {})
  vim.o.selection = "inclusive"
  vim.o.virtualedit = ""
  vim.bo.tabstop = 4
  calls, deferred, messages = {}, {}, {}
  exists = true
  runner.setup(vim.tbl_extend("force", {
    enabled_filetypes = { "python", "julia" },
    jump = false,
  }, opts or {}))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
end
local function sent(lines, suffix)
  equal(#calls, 1)
  local code = table.concat(lines, "\n")
  if suffix == nil and vim.bo.filetype == "julia" then
    code = #lines > 1 and ("begin\n" .. code .. "\nend;") or (code .. ";")
  else
    code = code .. (suffix or "")
  end
  equal(calls[1].code, code .. "\n")
end
local function select_keys(keys, leave)
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(keys .. (leave and "<Esc>" or ""), true, false, true))
end

for _, language in ipairs({ "python", "julia" }) do
  assert(
    pcall(vim.treesitter.get_string_parser, "x = 1", language),
    "Missing " .. language .. " parser. Run `make test-deps` first."
  )
end

test("runtime: loading after setup preserves user configuration", function()
  reset("julia", { "x = 1" }, {
    enabled_filetypes = { "python", "julia" },
    term_id = 7,
    startup_delay = 1500,
    languages = { julia = { start_cmd = "julia --project=." } },
  })
  local config = require("coderunner.config")
  local expected = vim.deepcopy(config.options)
  vim.g.loaded_coderunner = nil
  dofile("plugin/coderunner.lua")
  equal(config.options, expected)
  runner.run_line("nojump")
  sent({ "x = 1" })
  equal(calls[1].id, 7)
end)

test("runtime: registers commands with defaults without calling setup", function()
  reset("python", { "x = 1" })
  local config = require("coderunner.config")
  config.setup()
  local commands = { "CodeRunBlock", "CodeRunCell", "CodeRunCurrentLine", "RunCurrentLine", "CodeRunSelection" }
  for _, name in ipairs(commands) do
    vim.api.nvim_del_user_command(name)
  end
  vim.g.loaded_coderunner = nil
  dofile("plugin/coderunner.lua")
  equal(config.options, config.defaults)
  for _, name in ipairs(commands) do
    equal(vim.fn.exists(":" .. name), 2)
  end
  equal(vim.g.loaded_coderunner, 1)
end)

local julia_cases = {
  {
    name = "abstract type definition",
    lines = { "abstract type AbstractPoint end" },
    cursor = { 1, 18 },
  },
  {
    name = "primitive type definition",
    lines = { "primitive type Bits8 8 end" },
    cursor = { 1, 19 },
  },
  {
    name = "function nested in a module",
    lines = { "module Example", "    function f()", "        1", "    end", "end" },
    cursor = { 3, 8 },
    first = 2,
    last = 4,
  },
  {
    name = "while header sends the loop rather than the condition",
    lines = { "while !isempty(xs)", "    pop!(xs)", "end" },
    cursor = { 1, 8 },
  },
  {
    name = "let header sends the complete let statement",
    lines = { "let x = 1, y = 2", "    println(x + y)", "end" },
    cursor = { 1, 8 },
  },
  {
    name = "let body sends its current statement",
    lines = { "let x = 1", "    println(x)", "end" },
    cursor = { 2, 7 },
    first = 2,
    last = 2,
  },
  {
    name = "catch body sends its current statement",
    lines = { "try", "    f()", "catch err", "    println(err)", "end" },
    cursor = { 4, 8 },
    first = 4,
    last = 4,
  },
  {
    name = "multiline assignment rather than its nested call",
    lines = { "result = sum(", "    [1, 2, 3]", ")", "other = 9" },
    cursor = { 2, 5 },
    last = 3,
  },
  {
    name = "multiline standalone call",
    lines = { "println(", "    sum([1, 2])", ")" },
    cursor = { 2, 7 },
  },
  {
    name = "complete function from its body",
    lines = { "function f(x)", "    y = x + 1", "    return y", "end", "f(1)" },
    cursor = { 2, 8 },
    last = 4,
  },
  {
    name = "function at indentation before its first token",
    lines = { "function f(x)", "    x + 1", "end" },
    cursor = { 2, 0 },
  },
  {
    name = "nearest nested function",
    lines = { "function outer()", "    function inner()", "        1", "    end", "    inner()", "end" },
    cursor = { 3, 8 },
    first = 2,
    last = 4,
  },
  {
    name = "short-form where function including its begin body",
    lines = { "f(x::T) where T = begin", "    x + 1", "end" },
    cursor = { 2, 5 },
  },
  {
    name = "typed short-form function",
    lines = { "f(x)::T where T = begin", "    x", "end" },
    cursor = { 2, 4 },
  },
  {
    name = "chained macro wrappers around a function",
    lines = { "@time @inline function f(x)", "    x + 1", "end" },
    cursor = { 2, 6 },
  },
  {
    name = "macro-wrapped statement",
    lines = { "@time sum(", "    [1, 2]", ")" },
    cursor = { 2, 5 },
  },
  {
    name = "do block including its assignment",
    lines = { "result = map([1, 2]) do x", "    x + 1", "end" },
    cursor = { 2, 6 },
  },
  {
    name = "anonymous function including its assignment",
    lines = { "f = x -> begin", "    x + 1", "end" },
    cursor = { 2, 6 },
  },
  {
    name = "long anonymous function including its assignment",
    lines = { "f = function(x)", "    x + 1", "end" },
    cursor = { 2, 6 },
  },
  {
    name = "mutable struct definition",
    lines = { "mutable struct Point", "    x::Float64", "    y::Float64", "end" },
    cursor = { 3, 7 },
  },
  {
    name = "module definition",
    lines = { "module Example", "    const x = 1", "end" },
    cursor = { 2, 10 },
  },
  {
    name = "macro definition",
    lines = { "macro twice(x)", "    :(2 * $x)", "end" },
    cursor = { 2, 8 },
  },
  {
    name = "for header sends complete loop",
    lines = { "for x in 1:3", "    println(x)", "end" },
    cursor = { 1, 7 },
  },
  {
    name = "loop body sends complete current statement",
    lines = { "for x in 1:3", "    println(", "        x", "    )", "end" },
    cursor = { 3, 8 },
    first = 2,
    last = 4,
  },
  {
    name = "elseif clause sends complete conditional",
    lines = { "if x > 1", "    x", "elseif x == 1", "    1", "else", "    0", "end" },
    cursor = { 3, 3 },
  },
  {
    name = "catch clause sends complete try statement",
    lines = { "try", "    f()", "catch err", "    println(err)", "end" },
    cursor = { 3, 4 },
  },
  {
    name = "using statement",
    lines = { "using LinearAlgebra, Statistics" },
    cursor = { 1, 10 },
  },
  {
    name = "standalone identifier",
    lines = { "result" },
    cursor = { 1, 2 },
  },
  {
    name = "preserves block comments and blank lines inside functions",
    lines = { "function f()", "    #= comment", "    still a comment =#", "", "    1", "end" },
    cursor = { 5, 4 },
  },
  {
    name = "preserves multiline string contents",
    lines = { 'text = """', "# not a comment", "", "    text", '"""' },
    cursor = { 4, 5 },
  },
}
for _, case in ipairs(julia_cases) do
  test("Julia: " .. case.name, function()
    reset("julia", case.lines)
    vim.api.nvim_win_set_cursor(0, case.cursor)
    runner.run_line("hide nojump")
    local expected = {}
    for i = case.first or 1, case.last or #case.lines do
      expected[#expected + 1] = case.lines[i]
    end
    sent(expected)
    equal(calls[1].show, false)
  end)
end

test("Julia: output suppression can be disabled", function()
  reset("julia", { "x = 1" }, { languages = { julia = { suppress_output = false } } })
  runner.run_line("nojump")
  sent({ "x = 1" }, "")
end)

test("Julia: existing semicolon is not duplicated", function()
  reset("julia", { "x = 1;  " })
  select_keys("ggV", true)
  runner.run_selection()
  sent({ "x = 1;  " }, "")
end)

test("Julia: multiline wrapper preserves trailing whitespace without changing the buffer", function()
  local lines = { "x = 1  ", "\t", "" }
  reset("julia", lines)
  select_keys("ggVG", true)
  runner.run_selection()
  equal(calls[1].code, "begin\nx = 1  \n\t\n\nend;\n")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines)
end)

test("Julia: multiline selection suppresses every expression without requiring a parser", function()
  local lines = { "x = 1", "y = 2 # trailing comment", "# final comment" }
  reset("julia", lines)
  local get_string_parser = vim.treesitter.get_string_parser
  vim.treesitter.get_string_parser = function()
    error("missing parser")
  end
  local ok, err = pcall(runner.send_selection, nil, { 1, #lines })
  vim.treesitter.get_string_parser = get_string_parser
  assert(ok, err)
  equal(calls[1].code, "begin\nx = 1\ny = 2 # trailing comment\n# final comment\nend;\n")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines)
end)

test("Julia: multiline cells suppress every expression", function()
  reset("julia", { "# %%", "x = 1", "y = sum(", "    [2, 3]", ") # trailing comment" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  runner.run_block("nojump")
  equal(calls[1].code, "begin\nx = 1\ny = sum(\n    [2, 3]\n) # trailing comment\nend;\n")
end)

test("Julia: multiline selection preserves strings, blank lines and block comments", function()
  local lines = { 'text = """', "# string content", "", '"""', "#= comment", "not code =#", "x = 2" }
  reset("julia", lines)
  runner.send_selection(nil, { 1, #lines })
  equal(calls[1].code, 'begin\ntext = """\n# string content\n\n"""\n#= comment\nnot code =#\nx = 2\nend;\n')
end)

test("Julia: multiline suppression can be disabled for both cells and selections", function()
  for _, kind in ipairs({ "block", "selection" }) do
    reset("julia", { "x = 1", "y = 2" }, { languages = { julia = { suppress_output = false } } })
    if kind == "block" then
      runner.run_block("nojump")
    else
      runner.send_selection(nil, { 1, 2 })
    end
    equal(calls[1].code, "x = 1\ny = 2\n")
  end
end)

test("Julia: delayed startup sends the whole quiet block", function()
  reset("julia", { "x = 1", "y = 2" })
  exists = false
  runner.send_selection(nil, { 1, 2 })
  equal(calls[1].code, "julia")
  deferred[1].callback()
  equal(calls[2].code, "begin\nx = 1\ny = 2\nend;\n")
end)

test("Julia: selects only the statement under cursor on a semicolon-separated line", function()
  reset("julia", { "x = 1; y = sum([2, 3])" })
  vim.api.nvim_win_set_cursor(0, { 1, 12 })
  runner.run_line("nojump")
  sent({ "y = sum([2, 3])" })
end)

test("Julia: jump skips comments to the next standalone item", function()
  reset("julia", { "function f()", "    1", "end", "", "# comment", "next = 2" })
  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  runner.run_line("jump")
  sent({ "function f()", "    1", "end" })
  equal(vim.api.nvim_win_get_cursor(0)[1], 6)
end)

test("Julia: jump from an indented statement advances rather than selecting itself", function()
  reset("julia", { "let x = 1", "    println(x)", "    println(x + 1)", "end" })
  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  runner.run_line("jump")
  sent({ "    println(x)" })
  equal(vim.api.nvim_win_get_cursor(0)[1], 3)
end)

test("Julia: no code item on a top-level comment", function()
  reset("julia", { "# comment", "x = 1" })
  runner.run_line()
  equal(#calls, 0)
  assert(messages[1]:match("No Tree%-sitter"))
end)

test("Python: decorated function regression", function()
  reset("python", { "@decorate", "def f(x):", "    # retained", "", "    return x + 1", "f(1)" })
  vim.api.nvim_win_set_cursor(0, { 5, 11 })
  runner.run_line()
  sent({ "@decorate", "def f(x):", "    # retained", "", "    return x + 1" })
end)

test("Python: multiline assignment regression", function()
  reset("python", { "value = sum(", "    [1, 2]", ")", "other = 0" })
  vim.api.nvim_win_set_cursor(0, { 2, 5 })
  runner.run_line()
  sent({ "value = sum(", "    [1, 2]", ")" })
end)

test("Python: jump from an indented statement advances rather than selecting itself", function()
  reset("python", { "if True:", "    x = 1", "    y = 2" })
  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  runner.run_line("jump")
  sent({ "    x = 1" })
  equal(vim.api.nvim_win_get_cursor(0)[1], 3)
end)

test("cell commands keep their existing filtering", function()
  reset("julia", { "# %%", "# comment", "x = 1", "", "println(x)", "# %%", "y = 2" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  runner.run_block("nojump")
  sent({ "x = 1", "println(x)" })
end)

test("current item respects enabled_filetypes", function()
  reset("julia", { "x = 1" }, { enabled_filetypes = { "python" } })
  runner.run_line()
  equal(#calls, 0)
  assert(messages[1]:match("not enabled"))
end)

test("unsupported Tree-sitter filetype reports a clear warning", function()
  reset("lua", { "print(1)" }, { enabled_filetypes = { "lua" } })
  runner.run_line()
  equal(#calls, 0)
  assert(messages[1]:match("not supported"))
end)

test("missing parser reports an error without sending code", function()
  reset("julia", { "x = 1" })
  local get_parser = vim.treesitter.get_parser
  vim.treesitter.get_parser = function()
    error("missing parser")
  end
  local ok, err = pcall(runner.run_line)
  vim.treesitter.get_parser = get_parser
  assert(ok, err)
  equal(#calls, 0)
  assert(messages[1]:match("parser is not available"))
end)

local selection_cases = {
  { name = "live linewise", keys = "ggV2j", expected = { "    first", "", "    # comment" } },
  { name = "previous linewise", keys = "ggV2j", leave = true, expected = { "    first", "", "    # comment" } },
  { name = "live characterwise", keys = "gg0v6l", expected = { "    fir" } },
  { name = "previous characterwise", keys = "gg0v6l", leave = true, expected = { "    fir" } },
  { name = "backwards characterwise", keys = "gg06lv6h", expected = { "    fir" } },
  { name = "live blockwise", keys = "gg0<C-v>2l2j", expected = { "   ", "", "   " } },
  { name = "previous blockwise", keys = "gg0<C-v>5l2j", leave = true, expected = { "    fi", "", "    # " } },
  { name = "multiline characterwise", keys = "gg04lv2j6l", expected = { "first", "", "    # comme" } },
}
for _, case in ipairs(selection_cases) do
  test("selection: " .. case.name, function()
    reset("lua", { "    first", "", "    # comment", "    last" }, { enabled_filetypes = {} })
    select_keys(case.keys, case.leave)
    runner.run_selection("hide jump term=3")
    if case.name == "live blockwise" then
      equal(#calls, 0) -- A whitespace-only rectangle contains no code.
    else
      sent(case.expected)
      equal(calls[1].id, 3)
      equal(calls[1].show, false)
    end
  end)
end

test("selection: Lua visual keymap callback reads the live selection", function()
  reset("lua", { "prefix = selected + suffix" })
  vim.keymap.set("x", "<F6>", function()
    runner.run_selection("hide term=5")
  end)
  select_keys("gg09lv7l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F6>", true, false, true), "xt", false)
  vim.keymap.del("x", "<F6>")
  sent({ "selected" })
  equal(calls[1].id, 5)
end)

test("selection: visual Cmd mapping reads the live selection", function()
  reset("lua", { "prefix = selected + suffix" })
  vim.keymap.set("x", "<F7>", "<cmd>CodeRunSelection hide term=6<cr>")
  select_keys("gg09lv7l")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F7>", true, false, true), "xt", false)
  vim.keymap.del("x", "<F7>")
  sent({ "selected" })
  equal(calls[1].id, 6)
end)

test("selection: Ex visual range keeps selected columns", function()
  reset("lua", { "prefix = selected + suffix" })
  select_keys("gg09lv7l", true)
  vim.cmd("'<,'>CodeRunSelection hide nojump")
  sent({ "selected" })
end)

test("selection: explicit line range", function()
  reset("lua", { "not selected", "    selected", "\talso selected", "not selected" })
  vim.cmd("2,3CodeRunSelection hide")
  sent({ "    selected", "\talso selected" })
end)

test("selection: exclusive endpoint", function()
  reset("lua", { "abcdef" })
  vim.o.selection = "exclusive"
  select_keys("gg0v3l", true)
  runner.run_selection()
  sent({ "abc" })
end)

test("selection: tabs and trailing spaces remain unchanged", function()
  reset("unknown", { "\tprint(1)  ", "\t\tprint(2)\t" })
  select_keys("ggVj")
  runner.run_selection()
  sent({ "\tprint(1)  ", "\t\tprint(2)\t" })
end)

test("selection: blockwise partial tabs use native visual columns", function()
  reset("lua", { "\tabc", "  xyz" })
  vim.o.virtualedit = "all"
  select_keys("gg0<C-v>j02l", true)
  runner.run_selection()
  sent({ "   ", "  x" })
end)

test("selection: UTF-8 endpoints are not split", function()
  local alpha = vim.fn.nr2char(945)
  local beta = vim.fn.nr2char(946)
  reset("julia", { alpha .. beta .. " + 1" })
  select_keys("gg0vl", true)
  runner.run_selection()
  sent({ alpha .. beta })
end)

test("selection: registers, clipboard, view and buffer are preserved", function()
  reset("lua", { "    print(1)", "    print(2)" })
  vim.fn.setreg("z", { "saved", "register" }, "V")
  vim.fn.setreg("a", "unnamed content")
  vim.fn.setreg('"', { points_to = "a" })
  vim.fn.setreg("0", "last yank")
  local register, unnamed = vim.fn.getreginfo("z"), vim.fn.getreginfo('"')
  local tick = vim.api.nvim_buf_get_changedtick(0)
  local clipboard = vim.o.clipboard
  select_keys("ggVj", true)
  local view = vim.fn.winsaveview()
  runner.run_selection()
  sent({ "    print(1)", "    print(2)" })
  equal(vim.fn.getreginfo("z"), register)
  equal(vim.fn.getreginfo('"'), unnamed)
  equal(vim.fn.getreg("0"), "last yank")
  equal(vim.o.clipboard, clipboard)
  equal(vim.fn.winsaveview(), view)
  equal(vim.api.nvim_buf_get_changedtick(0), tick)
end)

test("selection: extraction does not trigger TextYankPost autocmds", function()
  reset("lua", { "print(1)" })
  local yanks = 0
  local autocmd = vim.api.nvim_create_autocmd("TextYankPost", {
    callback = function()
      yanks = yanks + 1
    end,
  })
  select_keys("ggV", true)
  runner.run_selection()
  vim.api.nvim_del_autocmd(autocmd)
  sent({ "print(1)" })
  equal(yanks, 0)
end)

test("selection: missing selection sends nothing", function()
  reset("lua", { "print(1)" })
  equal(runner.run_selection(), false)
  equal(#calls, 0)
  assert(messages[1]:match("No visual selection"))
end)

test("selection: blank selection sends nothing", function()
  reset("lua", { "    ", "" })
  select_keys("ggVj", true)
  equal(runner.run_selection(), false)
  equal(#calls, 0)
end)

test("selection: unknown filetype never starts the Python REPL", function()
  reset("lua", { "print(1)" })
  exists = false
  select_keys("ggV", true)
  runner.run_selection("term=4 hide")
  equal(#calls, 0)
  equal(#deferred, 1)
  deferred[1].callback()
  sent({ "print(1)" })
  equal(calls[1].id, 4)
end)

test("selection: configured language starts even if not enabled for cells", function()
  reset("julia", { "println(1)" }, { enabled_filetypes = {}, startup_delay = 123 })
  exists = false
  select_keys("ggV", true)
  runner.run_selection("term=2 hide")
  equal(calls[1].code, "julia")
  equal(calls[1].id, 2)
  equal(calls[1].show, false)
  equal(deferred[1].delay, 123)
  deferred[1].callback()
  equal(calls[2].code, "println(1);\n")
end)

test("selection: hidden existing terminal is reused without restarting Julia", function()
  reset("julia", { "println(1)" })
  select_keys("ggV", true)
  runner.run_selection()
  sent({ "println(1)" })
  equal(#deferred, 0)
end)

print(("\n%d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
