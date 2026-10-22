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
local function frame(id, variables, truncated)
  local lines = { "BEGIN\t" .. id }
  for _, variable in ipairs(variables) do
    local fields = { "VAR", tostring(id) }
    for _, key in ipairs({ "name", "type", "dimensions", "value" }) do
      table.insert(fields, hex(variable[key] or ""))
    end
    table.insert(lines, table.concat(fields, "\t"))
  end
  table.insert(lines, "END\t" .. id .. "\t" .. (truncated and "1" or "0"))
  return table.concat(lines, "\n") .. "\n"
end
local function connect(term, token)
  local peer = uv.new_tcp()
  table.insert(peers, peer)
  peer:connect("127.0.0.1", term.port, function(err)
    assert(not err, err)
    peer:write("HELLO\t" .. (token or term.token) .. "\t1\n")
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
        local id = tonumber(request:match("^REFRESH\t(%d+)"))
        assert(id, request)
        term.requests = (term.requests or 0) + 1
        if responder then
          responder(peer, id, term)
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
for _, command in ipairs({ "CodeRunWorkspace", "CodeRunWorkspaceRefresh", "CodeRunWorkspaceDisconnect" }) do
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
  assert(lines:find("answer :: Int64", 1, true))
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

print(("\nWorkspace: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
