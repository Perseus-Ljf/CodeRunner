vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.columns = 140
vim.o.lines = 40

local uv = vim.uv or vim.loop
local config = require("coderunner.config")
local runner = require("coderunner")
local terminals, peers, messages = {}, {}, {}
local auto_connect, responder = true, nil

local function hex(text)
  return (text:gsub(".", function(byte)
    return ("%02x"):format(byte:byte())
  end))
end
local function frame(id, variables, truncated, generation)
  local lines = { "BEGIN\t" .. id .. "\t" .. (generation or 1) }
  for _, variable in ipairs(variables) do
    local fields = { "VAR", tostring(id) }
    for _, key in ipairs({ "name", "type", "dimensions", "value" }) do
      table.insert(fields, hex(variable[key] or ""))
    end
    table.insert(fields, tostring(variable.id or 0))
    table.insert(fields, variable.expandable and "1" or "0")
    table.insert(lines, table.concat(fields, "\t"))
  end
  table.insert(lines, "END\t" .. id .. "\t" .. (truncated and "1" or "0"))
  return table.concat(lines, "\n") .. "\n"
end
local function connect(term, token, version)
  local peer = uv.new_tcp()
  table.insert(peers, peer)
  peer:connect("127.0.0.1", term.port, function(err)
    assert(not err, err)
    local hello = "HELLO\t" .. (token or term.token) .. "\t" .. (version or 2)
    peer:write(hello .. (version == 1 and "\n" or "\t1\n"))
    local buffer = ""
    peer:read_start(function(read_err, data)
      assert(not read_err, read_err)
      if not data then
        return
      end
      buffer = buffer .. data
      while true do
        local newline = buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local request = buffer:sub(1, newline - 1)
        buffer = buffer:sub(newline + 1)
        local kind, number = request:match("^(%u+)\t(%d+)")
        local id = tonumber(number)
        assert(id and (kind == "REFRESH" or kind == "CHILDREN"), request)
        term.requests = (term.requests or 0) + 1
        if responder then
          responder(peer, id, term, vim.split(request, "\t", { plain = true }))
        else
          peer:write(frame(id, { { name = "answer", type = "Int64", value = "42" } }))
        end
      end
    end)
  end)
  term.peer = peer
  return peer
end

package.loaded["toggleterm.terminal"] = {
  get = function(id)
    return terminals[id]
  end,
  Terminal = {
    new = function(_, opts)
      local term = { id = opts.id, cmd = opts.cmd, job_id = opts.id * 10 }
      function term:spawn()
        self.bufnr = vim.api.nvim_create_buf(false, true)
        terminals[self.id] = self
      end
      function term:send(code)
        self.bootstrap = code
        local port, token = code:match('%.start%((%d+), "(%x+)"%)')
        assert(port and token, code)
        self.port, self.token = tonumber(port), token
        if auto_connect then
          connect(self)
        end
      end
      return term
    end,
  },
}
vim.notify = function(message)
  table.insert(messages, message)
end
runner.setup()
assert(not package.loaded["coderunner.workspace"], "Workspace should load on demand")
for _, command in ipairs({
  "CodeRunWorkspace",
  "CodeRunWorkspaceRefresh",
  "CodeRunWorkspaceDisconnect",
  "CodeRunWorkspaceFind",
}) do
  assert(vim.fn.exists(":" .. command) == 2)
end
local workspace = require("coderunner.workspace")
local sessions = require("coderunner.julia_session")
local passed, failed = 0, 0
local function wait_for(condition)
  assert(vim.wait(3000, condition, 5), "Timed out waiting for workspace state")
end
local function ready(id)
  wait_for(function()
    return sessions.sessions[id] and sessions.sessions[id].status == "ready"
  end)
  return sessions.sessions[id]
end
local function test(name, fn)
  workspace.close()
  for id in pairs(sessions.sessions) do
    sessions.disconnect(id)
  end
  for _, peer in ipairs(peers) do
    if not peer:is_closing() then
      peer:close()
    end
  end
  terminals, peers, messages = {}, {}, {}
  sessions.sessions, sessions.known = {}, {}
  auto_connect, responder = true, nil
  config.setup({ workspace = { timeout = 1000 } })
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS workspace: " .. name)
  else
    failed = failed + 1
    print("FAIL workspace: " .. name .. "\n" .. err)
  end
end

test("starts Julia lazily, renders read-only sidebar and preserves focus", function()
  local window = vim.api.nvim_get_current_win()
  assert(workspace.open({ term_id = 21 }))
  local state = ready(21)
  assert(terminals[21].cmd == "julia")
  assert(state.variables[1].value == "42")
  assert(vim.api.nvim_get_current_win() == window)
  assert(vim.bo[workspace.buffer].modifiable == false)
  assert(vim.bo[workspace.buffer].buftype == "nofile")
  local lines = table.concat(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false), "\n")
  assert(lines:find("answer", 1, true) and lines:find("Int64", 1, true))
  assert(lines:find("VARIABLE", 1, true) and lines:find("VALUE / SIZE", 1, true))
  assert(workspace.command("toggle", "term=21"))
  assert(not workspace.window)
  assert(state.authenticated, "Closing the panel must not kill the REPL connection")
end)

test("unknown terminals require explicit Julia confirmation", function()
  local term = package.loaded["toggleterm.terminal"].Terminal:new({ id = 22 })
  term:spawn()
  assert(not workspace.open({ term_id = 22 }))
  assert(not term.bootstrap)
  assert(messages[1]:find("attach", 1, true))
  assert(workspace.open({ term_id = 22, attach = true }))
  ready(22)
  assert(sessions.known[22].terminal == term)
end)

test("rejects an incorrect handshake without consuming the listener", function()
  auto_connect = false
  assert(workspace.open({ term_id = 23 }))
  connect(terminals[23], "incorrect")
  vim.wait(30, function()
    return false
  end, 5)
  assert(not sessions.sessions[23].authenticated)
  connect(terminals[23])
  ready(23)
end)

test("fragmented UTF-8 snapshots are atomic and stale responses are ignored", function()
  local unicode = vim.fn.nr2char(20320) .. vim.fn.nr2char(22909)
  local tail
  responder = function(peer, id)
    local response = frame(id, { { name = unicode, type = "String", value = unicode .. "\n\tvalue" } }, true)
    local split = response:find("\n") + 3
    peer:write(response:sub(1, split))
    tail = function()
      peer:write(response:sub(split + 1))
    end
  end
  assert(workspace.open({ term_id = 24 }))
  wait_for(function()
    return tail ~= nil
  end)
  assert(#sessions.sessions[24].variables == 0)
  tail()
  local state = ready(24)
  assert(state.variables[1].name == unicode)
  assert(state.variables[1].value == unicode .. "\n\tvalue")
  assert(state.truncated)
  terminals[24].peer:write(frame(0, { { name = "stale", type = "Int64", value = "0" } }))
  vim.wait(30, function()
    return false
  end, 5)
  assert(state.variables[1].name == unicode)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false)) do
    assert(not line:find("\t", 1, true))
    assert(vim.fn.strdisplaywidth(line) < vim.api.nvim_win_get_width(workspace.window))
  end
end)

test("timeout keeps the last snapshot and allows a subsequent refresh", function()
  assert(workspace.open({ term_id = 25 }))
  local state = ready(25)
  config.options.workspace.timeout = 100
  responder = function() end
  assert(workspace.refresh({ term_id = 25 }))
  local expired = state.sequence
  wait_for(function()
    return state.status == "timeout"
  end)
  assert(state.variables[1].value == "42")
  terminals[25].peer:write(frame(expired, { { name = "late", type = "Int64", value = "0" } }))
  responder = function(peer, id)
    peer:write(frame(id, { { name = "answer", type = "Int64", value = "99" } }))
  end
  assert(workspace.refresh({ term_id = 25 }))
  ready(25)
  assert(state.variables[1].value == "99")
end)

test("repeated refreshes coalesce and invalid frames disconnect safely", function()
  assert(workspace.open({ term_id = 26 }))
  local state = ready(26)
  responder = function(peer, id)
    peer:write("BEGIN\t" .. id .. "\nVAR\t" .. id .. "\tzz\t00\t00\t00\n")
  end
  assert(workspace.refresh({ term_id = 26 }))
  assert(workspace.refresh({ term_id = 26 }))
  wait_for(function()
    return state.status == "disconnected"
  end)
  assert(terminals[26].requests == 2)
  assert(state.variables[1].value == "42")
  assert(state.message == "Invalid workspace response")
end)

test("separate terminals and replacement jobs cannot reuse stale sessions", function()
  assert(workspace.open({ term_id = 27 }))
  local old = ready(27)
  responder = function(peer, id)
    peer:write(frame(id, { { name = "other", type = "String", value = "second" } }))
  end
  assert(workspace.open({ term_id = 28 }))
  local other = ready(28)
  assert(old.variables[1].name == "answer")
  assert(other.variables[1].name == "other")
  assert(vim.b[workspace.buffer].coderunner_workspace_term == 28)
  terminals[27].job_id = terminals[27].job_id + 1
  assert(not workspace.refresh({ term_id = 27 }))
  assert(old.status == "disconnected")
  assert(not workspace.open({ term_id = 27 }))
  assert(workspace.open({ term_id = 27, attach = true }))
  local replacement = ready(27)
  assert(replacement ~= old)
  assert(replacement.variables[1].name == "other")
end)

test("terminal exit and connection EOF update status", function()
  assert(workspace.open({ term_id = 29 }))
  local state = ready(29)
  terminals[29].peer:close()
  wait_for(function()
    return state.status == "disconnected"
  end)
  assert(not sessions.known[29])
  assert(workspace.open({ term_id = 29, attach = true }))
  state = ready(29)
  vim.api.nvim_exec_autocmds("TermClose", { group = "CodeRunnerJuliaSessions", buffer = terminals[29].bufnr })
  assert(state.status == "disconnected")
end)

test("validates command arguments and configuration before connecting", function()
  assert(not workspace.command("toggle", "term=-1"))
  assert(not workspace.command("refresh", "wat"))
  assert(not workspace.open({ term_id = 0 }))
  config.options.workspace.max_items = 0
  assert(not workspace.open({ term_id = 30 }))
  assert(not workspace.refresh({ term_id = 30 }))
  assert(not terminals[30])
  config.options.workspace.max_items = 500
  config.options.workspace.position = "invalid"
  assert(not workspace.open({ term_id = 30 }))
end)

test("registered Ex commands toggle, refresh and disconnect their target", function()
  vim.cmd("CodeRunWorkspace term=32")
  local state = ready(32)
  vim.cmd("CodeRunWorkspaceRefresh term=32")
  ready(32)
  assert(terminals[32].requests == 2)
  vim.cmd("CodeRunWorkspaceDisconnect term=32")
  assert(state.status == "disconnected")
  vim.cmd("CodeRunWorkspace term=32")
  assert(not workspace.window)
end)

test("connection timeout closes resources and marks the session disconnected", function()
  auto_connect = false
  config.options.workspace.timeout = 100
  assert(workspace.open({ term_id = 31 }))
  local state = sessions.sessions[31]
  wait_for(function()
    return state.status == "disconnected"
  end)
  assert(not state.server and not state.client and not state.timer)
end)

test("execution notifications debounce and respect manual mode", function()
  config.options.workspace.refresh_delay = 30
  assert(workspace.open({ term_id = 40 }))
  local state = ready(40)
  responder = function(peer, id)
    peer:write(frame(id, { { name = "answer", type = "Int64", value = "99" } }))
  end
  terminals[40].peer:write(string.rep("CHANGED\n", 12))
  wait_for(function()
    return state.sequence == 2 and state.status == "ready"
  end)
  assert(terminals[40].requests == 2)
  assert(state.variables[1].value == "99")
  config.options.workspace.auto_refresh = false
  terminals[40].peer:write("CHANGED\n")
  vim.wait(70, function()
    return false
  end, 5)
  assert(state.sequence == 2)
end)

test("an execution finishing during a request triggers one subsequent refresh", function()
  config.options.workspace.refresh_delay = 20
  assert(workspace.open({ term_id = 41 }))
  local state = ready(41)
  local held
  responder = function(peer, id)
    if id == 2 then
      held = function()
        peer:write(frame(id, { { name = "answer", type = "Int64", value = "50" } }))
      end
    else
      peer:write(frame(id, { { name = "answer", type = "Int64", value = "99" } }))
    end
  end
  assert(workspace.refresh({ term_id = 41 }))
  wait_for(function()
    return held ~= nil
  end)
  terminals[41].peer:write("CHANGED\n")
  wait_for(function()
    return state.dirty
  end)
  held()
  wait_for(function()
    return state.sequence == 3 and state.status == "ready"
  end)
  assert(state.variables[1].value == "99")
  assert(terminals[41].requests == 3)
end)

test("nested trees load lazily and preserve expansion and selection after refresh", function()
  local generation, city = 0, "Paris"
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      generation = generation + 1
      peer:write(
        frame(
          id,
          { { name = "person", type = "Person", value = "2 fields", id = 1, expandable = true } },
          false,
          generation
        )
      )
    elseif fields[4] == "1" then
      peer:write(frame(id, {
        { name = "name", type = "String", value = '"Ada"' },
        { name = "address", type = "Address", value = "1 field", id = 2, expandable = true },
      }, false, generation))
    else
      peer:write(frame(id, { { name = "city", type = "String", value = city } }, false, generation))
    end
  end
  assert(workspace.open({ term_id = 42 }))
  local state = ready(42)
  local root = state.variables[1]
  assert(not root.children and terminals[42].requests == 1)
  assert(sessions.expand(42, root, true))
  wait_for(function()
    return root.children ~= nil
  end)
  local address = root.children[2]
  assert(sessions.expand(42, address, true))
  wait_for(function()
    return address.children ~= nil
  end)
  local path = address.children[1].path
  for line, text in ipairs(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false)) do
    if text:find("city", 1, true) then
      vim.api.nvim_win_set_cursor(workspace.window, { line, 0 })
    end
  end
  workspace.render()
  city = "London"
  assert(workspace.refresh({ term_id = 42 }))
  wait_for(function()
    local item = state.variables[1]
    return state.status == "ready" and item.children and item.children[2].children ~= nil
  end)
  root = state.variables[1]
  assert(root.children[2].children[1].value == "London")
  assert(state.expanded[root.path] and state.expanded[root.children[2].path])
  assert(workspace.preferred_path == path, vim.inspect(workspace.preferred_path))
  local line = vim.api.nvim_win_get_cursor(workspace.window)[1]
  assert(vim.api.nvim_buf_get_lines(workspace.buffer, line - 1, line, false)[1]:find("city", 1, true))
  local requests = terminals[42].requests
  assert(sessions.expand(42, root, false))
  assert(sessions.expand(42, root, true))
  assert(terminals[42].requests == requests, "Collapsing must retain loaded children")
end)

test("expansion emits only pending and completed states and reuses loaded children", function()
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, { { name = "object", type = "Object", value = "1 field", id = 1, expandable = true } }))
    else
      peer:write(frame(id, { { name = "field", type = "Int64", value = "42" } }))
    end
  end
  assert(workspace.open({ term_id = 49 }))
  local state = ready(49)
  local root = state.variables[1]
  local changes, original = {}, sessions.on_change
  sessions.on_change = function(session)
    if session == state then
      table.insert(changes, session.status)
    end
    original(session)
  end
  assert(sessions.expand(49, root, true))
  wait_for(function()
    return root.children ~= nil
  end)
  sessions.on_change = original
  assert(vim.deep_equal(changes, { "expanding", "ready" }), vim.inspect(changes))
  local display = root.children[1]._workspace_display
  local requests = terminals[49].requests
  assert(sessions.expand(49, root, false))
  assert(sessions.expand(49, root, true))
  assert(not state.pending and terminals[49].requests == requests)
  assert(root.children[1]._workspace_display == display, "Loaded child formatting should be reused")
end)

test("unchanged renders skip buffer writes and invalidate formatting on data or width changes", function()
  assert(workspace.open({ term_id = 50 }))
  local state = ready(50)
  local root = state.variables[1]
  local display = root._workspace_display
  local tick = vim.api.nvim_buf_get_changedtick(workspace.buffer)
  workspace.render()
  workspace.render()
  assert(vim.api.nvim_buf_get_changedtick(workspace.buffer) == tick)
  assert(root._workspace_display == display)
  root.name, root.value, root.type, root.dimensions = "\228\189\160\229\165\189", "updated", "String", "2 x 3"
  workspace.render()
  assert(root._workspace_display ~= display)
  local text = table.concat(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false), "\n")
  assert(text:find(root.name, 1, true) and text:find("[2 x 3] updated", 1, true) and text:find("String", 1, true))
  display = root._workspace_display
  local ambiwidth = vim.o.ambiwidth
  vim.o.ambiwidth = ambiwidth == "single" and "double" or "single"
  workspace.render()
  vim.o.ambiwidth = ambiwidth
  assert(root._workspace_display ~= display, "Display-width rules must invalidate the cache")
  display = root._workspace_display
  vim.api.nvim_win_set_width(workspace.window, 28)
  workspace.render()
  assert(root._workspace_display ~= display and root._workspace_display.width == 27)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false)) do
    assert(vim.fn.strdisplaywidth(line) <= 27)
  end
end)

test("refresh preserves the viewport of a deeply scrolled field list", function()
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, { { name = "object", type = "Object", value = "60 fields", id = 1, expandable = true } }))
    else
      local fields = {}
      for index = 1, 60 do
        fields[index] = { name = "field" .. index, type = "Int64", value = tostring(index) }
      end
      peer:write(frame(id, fields))
    end
  end
  assert(workspace.open({ term_id = 47 }))
  local state = ready(47)
  assert(sessions.expand(47, state.variables[1], true))
  wait_for(function()
    return state.variables[1].children ~= nil
  end)
  for line, text in ipairs(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false)) do
    if text:find("field45", 1, true) then
      vim.api.nvim_win_set_cursor(workspace.window, { line, 0 })
    end
  end
  vim.api.nvim_win_call(workspace.window, function()
    vim.cmd("normal! zz")
  end)
  workspace.render()
  local before = vim.api.nvim_win_call(workspace.window, vim.fn.winsaveview)
  assert(workspace.refresh({ term_id = 47 }))
  wait_for(function()
    return state.status == "ready" and state.variables[1].children ~= nil
  end)
  local after = vim.api.nvim_win_call(workspace.window, vim.fn.winsaveview)
  assert(before.lnum == after.lnum)
  assert(before.topline == after.topline, vim.inspect({ before = before, after = after }))
end)

test("child failures are displayed without an infinite expansion retry", function()
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, { { name = "object", type = "Object", value = "1 field", id = 1, expandable = true } }))
    else
      peer:write("ERROR\t" .. id .. "\t" .. hex("Object changed") .. "\n")
    end
  end
  assert(workspace.open({ term_id = 43 }))
  local state = ready(43)
  local root = state.variables[1]
  assert(sessions.expand(43, root, true))
  wait_for(function()
    return root.error ~= nil
  end)
  assert(root.error == "Object changed")
  assert(not state.pending)
  assert(terminals[43].requests == 2)
end)

test("outdated helpers report the required Julia restart", function()
  auto_connect = false
  assert(workspace.open({ term_id = 45 }))
  local state = sessions.sessions[45]
  connect(terminals[45], nil, 1)
  wait_for(function()
    return state.status == "disconnected"
  end)
  assert(state.message:find("restart Julia", 1, true))
end)

test("disconnect cancels a debounced automatic update", function()
  config.options.workspace.refresh_delay = 100
  assert(workspace.open({ term_id = 46 }))
  local state = ready(46)
  terminals[46].peer:write("CHANGED\n")
  wait_for(function()
    return state.auto_timer ~= nil
  end)
  sessions.disconnect(46)
  assert(not state.auto_timer and not state.client)
  assert(state.status == "disconnected")
end)

test("narrow and wide panels clip by display width and keep fields aligned", function()
  assert(workspace.open({ term_id = 44 }))
  ready(44)
  for _, width in ipairs({ 28, 48, 72 }) do
    vim.api.nvim_win_set_width(workspace.window, width)
    workspace.render()
    local actual = vim.api.nvim_win_get_width(workspace.window)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(workspace.buffer, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) < actual)
    end
  end
end)

test("find uses the root index, focuses a scalar and avoids a redundant refresh", function()
  assert(workspace.open({ term_id = 51 }))
  local state = ready(51)
  local requests = terminals[51].requests
  assert(state.variables_by_name.answer == state.variables[1])
  assert(workspace.find("Main.answer", { term_id = 51 }))
  assert(vim.api.nvim_get_current_win() == workspace.window)
  assert(workspace.preferred_path == state.variables[1].path)
  assert(terminals[51].requests == requests and not state.pending)
  local line = vim.api.nvim_win_get_cursor(workspace.window)[1]
  assert(vim.api.nvim_buf_get_lines(workspace.buffer, line - 1, line, false)[1]:find("answer", 1, true))
end)

test("find waits for the first snapshot and expands a visually selected variable", function()
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, { { name = "person", type = "Person", value = "1 field", id = 1, expandable = true } }))
    else
      peer:write(frame(id, { { name = "city", type = "String", value = '"Paris"' } }))
    end
  end
  vim.cmd("enew!")
  vim.bo.filetype = "julia"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = person + 1" })
  local source = vim.api.nvim_get_current_buf()
  vim.cmd("normal! gg04lv5l" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  vim.cmd("'<,'>CodeRunWorkspaceFind term=52")
  wait_for(function()
    local state = sessions.sessions[52]
    return state and state.variables[1] and state.variables[1].children ~= nil
  end)
  local state = ready(52)
  assert(vim.api.nvim_get_current_win() == workspace.window)
  assert(state.expanded[state.variables[1].path])
  assert(workspace.preferred_path == state.variables[1].path)
  assert(terminals[52].requests == 2, "Find should request one snapshot and one expansion")
  assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "x = person + 1")
  assert(workspace.find("person", { term_id = 52 }))
  assert(state.expanded[state.variables[1].path], "Repeated find must not collapse the variable")
  assert(terminals[52].requests == 2)
end)

test("find refreshes a missing name once and reports absence without moving focus", function()
  assert(workspace.open({ term_id = 53 }))
  local state = ready(53)
  local previous = vim.api.nvim_get_current_win()
  assert(workspace.find("missing", { term_id = 53 }))
  wait_for(function()
    return #messages > 0
  end)
  assert(state.sequence == 2 and terminals[53].requests == 2)
  assert(messages[1]:find("missing", 1, true))
  assert(vim.api.nvim_get_current_win() == previous)
  assert(not workspace.pending_find)
end)

test("find locates newly created Unicode names after one refresh and rebuilds the name index", function()
  assert(workspace.open({ term_id = 54 }))
  local state = ready(54)
  local name = vim.fn.nr2char(945) .. "!"
  responder = function(peer, id)
    peer:write(frame(id, { { name = name, type = "Int64", value = "99" } }, false, 2))
  end
  assert(workspace.find(name, { term_id = 54 }))
  wait_for(function()
    return not workspace.pending_find
  end)
  assert(state.variables_by_name[name] == state.variables[1])
  assert(not state.variables_by_name.answer)
  assert(state.sequence == 2)
  assert(vim.api.nvim_get_current_win() == workspace.window)
end)

test("find waits for an in-flight snapshot instead of selecting a stale node", function()
  assert(workspace.open({ term_id = 55 }))
  local state = ready(55)
  local complete
  responder = function(peer, id)
    complete = function()
      peer:write(frame(id, { { name = "fresh", type = "Int64", value = "9" } }, false, 2))
    end
  end
  assert(workspace.refresh({ term_id = 55 }))
  wait_for(function()
    return complete ~= nil
  end)
  assert(workspace.find("fresh", { term_id = 55 }))
  assert(workspace.pending_find)
  complete()
  wait_for(function()
    return not workspace.pending_find
  end)
  assert(workspace.preferred_path == state.variables_by_name.fresh.path)
  assert(terminals[55].requests == 2)
end)

test("find reports truncated snapshots and rejects whitespace without sending expressions", function()
  responder = function(peer, id)
    peer:write(frame(id, { { name = "answer", type = "Int64", value = "42" } }, true))
  end
  assert(workspace.find("not_visible", { term_id = 56 }))
  wait_for(function()
    return #messages > 0
  end)
  assert(messages[1]:find("truncated", 1, true))
  assert(messages[1]:find("max_items", 1, true))
  local requests = terminals[56].requests
  assert(not workspace.find("answer + 1", { term_id = 56 }))
  assert(not workspace.find("\n", { term_id = 56 }))
  assert(terminals[56].requests == requests)
end)

test("closing or switching panels cancels an asynchronous find", function()
  auto_connect = false
  assert(workspace.find("answer", { term_id = 57 }))
  assert(workspace.pending_find)
  workspace.close()
  connect(terminals[57])
  ready(57)
  assert(not workspace.pending_find and not workspace.window)
  auto_connect = true
  assert(workspace.find("missing", { term_id = 57 }))
  assert(workspace.open({ term_id = 58 }))
  ready(58)
  assert(not workspace.pending_find and workspace.term_id == 58)
  assert(#messages == 0)
end)

test("find requires confirmation for unknown terminals and honors explicit names", function()
  local term = package.loaded["toggleterm.terminal"].Terminal:new({ id = 59 })
  term:spawn()
  assert(not workspace.command("find", "answer term=59"))
  assert(not term.bootstrap)
  assert(workspace.command("find", "answer term=59 attach", "ignored"))
  wait_for(function()
    return not workspace.pending_find
  end)
  assert(vim.api.nvim_get_current_win() == workspace.window)
  assert(not workspace.command("find", "answer term=invalid"))
end)

test("subtree rendering changes only its lines and preserves shifted highlights", function()
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, {
        { name = "object", type = "Object", value = "1 field", id = 1, expandable = true },
        { name = "tail", type = "String", value = '"keep"' },
      }))
    else
      peer:write(frame(id, { { name = "field", type = "Int64", value = "42" } }))
    end
  end
  assert(workspace.open({ term_id = 60 }))
  local state = ready(60)
  local root = state.variables[1]
  assert(sessions.expand(60, root, true))
  wait_for(function()
    return root.children ~= nil
  end)
  local writes, highlighted = {}, 0
  local set_lines, add_highlight = vim.api.nvim_buf_set_lines, vim.api.nvim_buf_add_highlight
  vim.api.nvim_buf_set_lines = function(buffer, first, last, strict, lines)
    if buffer == workspace.buffer then
      writes[#writes + 1] = { first, last, #lines }
    end
    return set_lines(buffer, first, last, strict, lines)
  end
  vim.api.nvim_buf_add_highlight = function(buffer, ...)
    if buffer == workspace.buffer then
      highlighted = highlighted + 1
    end
    return add_highlight(buffer, ...)
  end
  local ok, err = pcall(function()
    assert(sessions.expand(60, root, false))
    assert(sessions.expand(60, root, true))
  end)
  vim.api.nvim_buf_set_lines, vim.api.nvim_buf_add_highlight = set_lines, add_highlight
  assert(ok, err)
  assert(vim.deep_equal(writes, { { 6, 8, 1 }, { 6, 7, 2 } }), vim.inspect(writes))
  assert(highlighted == 9, tostring(highlighted))
  local namespace = vim.api.nvim_create_namespace("coderunner.workspace")
  local marks = vim.api.nvim_buf_get_extmarks(workspace.buffer, namespace, { 8, 0 }, { 8, -1 }, { details = true })
  assert(#marks == 3, vim.inspect(marks))
  local tick = vim.api.nvim_buf_get_changedtick(workspace.buffer)
  workspace.render()
  assert(vim.api.nvim_buf_get_changedtick(workspace.buffer) == tick)
end)

test("find waits for dirty data and reports a connection timeout once", function()
  assert(workspace.open({ term_id = 61 }))
  local state = ready(61)
  responder = function(peer, id)
    peer:write(frame(id, { { name = "answer", type = "Int64", value = "99" } }, false, 2))
  end
  state.dirty = true
  assert(workspace.find("answer", { term_id = 61 }))
  wait_for(function()
    return not workspace.pending_find
  end)
  assert(state.variables_by_name.answer.value == "99" and state.sequence == 2)
  local current = vim.api.nvim_get_current_win()
  auto_connect = false
  config.options.workspace.timeout = 100
  assert(workspace.find("answer", { term_id = 62 }))
  wait_for(function()
    return sessions.sessions[62].status == "disconnected"
  end)
  assert(not workspace.pending_find)
  assert(#messages == 1 and messages[1]:find("connect", 1, true))
  assert(vim.api.nvim_get_current_win() == current)
end)

test("a newer find replaces an older request while connecting", function()
  auto_connect = false
  assert(workspace.find("missing", { term_id = 63 }))
  assert(workspace.find("answer", { term_id = 63 }))
  connect(terminals[63])
  wait_for(function()
    return not workspace.pending_find
  end)
  local state = ready(63)
  assert(workspace.preferred_path == state.variables_by_name.answer.path)
  assert(terminals[63].requests == 1 and #messages == 0)
end)

test("find retries an existing error state but reports a failed lookup refresh once", function()
  assert(workspace.open({ term_id = 64 }))
  local state = ready(64)
  for _, status in ipairs({ "error", "timeout" }) do
    state.status, state.message = status, "Previous request failed"
    assert(workspace.find("answer", { term_id = 64 }))
    wait_for(function()
      return not workspace.pending_find
    end)
    assert(state.status == "ready" and #messages == 0)
  end
  responder = function(peer, id)
    peer:write("ERROR\t" .. id .. "\t" .. hex("Lookup refresh failed") .. "\n")
  end
  assert(workspace.find("missing", { term_id = 64 }))
  wait_for(function()
    return not workspace.pending_find
  end)
  assert(#messages == 1 and messages[1] == "Lookup refresh failed")
  assert(state.sequence == 4 and not state.pending)
end)

test("incremental updates retain preceding row and header highlights", function()
  responder = function(peer, id)
    peer:write(frame(id, {
      { name = "first", type = "Int64", value = "1" },
      { name = "second", type = "Int64", value = "2" },
    }))
  end
  assert(workspace.open({ term_id = 65 }))
  local state = ready(65)
  local namespace = vim.api.nvim_create_namespace("coderunner.workspace")
  local function marks(line)
    return vim.api.nvim_buf_get_extmarks(workspace.buffer, namespace, { line, 0 }, { line, -1 }, { details = true })
  end
  assert(#marks(6) == 3)
  state.variables[2].value = "changed"
  workspace.render()
  assert(#marks(6) == 3, vim.inspect(marks(6)))
  assert(workspace.refresh({ term_id = 65 }))
  ready(65)
  assert(#marks(1) == 1, vim.inspect(marks(1)))
  assert(#marks(6) == 3 and #marks(7) == 3)
end)

test("WinClosed cancels a find before reopening the same terminal panel", function()
  auto_connect = false
  local source = vim.api.nvim_get_current_win()
  assert(workspace.find("answer", { term_id = 66 }))
  vim.api.nvim_set_current_win(workspace.window)
  vim.cmd("close")
  assert(not workspace.pending_find and not workspace.window)
  assert(workspace.open({ term_id = 66 }))
  connect(terminals[66])
  ready(66)
  assert(vim.api.nvim_get_current_win() == source)
  assert(not workspace.pending_find)
end)

test("find retries an earlier failed child expansion", function()
  local children = 0
  responder = function(peer, id, _, fields)
    if fields[1] == "REFRESH" then
      peer:write(frame(id, { { name = "object", type = "Object", value = "1 field", id = 1, expandable = true } }))
    else
      children = children + 1
      if children == 1 then
        peer:write("ERROR\t" .. id .. "\t" .. hex("First expansion failed") .. "\n")
      else
        peer:write(frame(id, { { name = "field", type = "Int64", value = "42" } }))
      end
    end
  end
  assert(workspace.find("object", { term_id = 67 }))
  wait_for(function()
    return sessions.sessions[67].status == "error"
  end)
  assert(workspace.find("object", { term_id = 67 }))
  wait_for(function()
    return sessions.sessions[67].variables[1].children ~= nil
  end)
  assert(children == 2)
  assert(sessions.sessions[67].status == "ready")
  assert(vim.api.nvim_get_current_win() == workspace.window)
end)

test("closing the last normal window leaves a usable editor buffer", function()
  assert(workspace.open({ term_id = 48 }))
  ready(48)
  vim.api.nvim_set_current_win(workspace.window)
  vim.cmd("only")
  workspace.inspect()
  workspace.close()
  assert(not workspace.window)
  assert(vim.api.nvim_get_current_buf() ~= workspace.buffer)
  assert(vim.bo.buftype == "")
end)

print(("\nWorkspace: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
