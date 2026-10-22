local config = require("coderunner.config")
local uv = vim.uv or vim.loop
local M = { sessions = {}, known = {} }
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local MAX_BYTES = 8 * 1024 * 1024

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function stop_timer(session)
  close(session.timer)
  session.timer = nil
end

local function emit(session)
  if M.on_change then
    M.on_change(session)
  end
end

local function release(session)
  stop_timer(session)
  close(session.server)
  close(session.client)
  for client in pairs(session.candidates or {}) do
    close(client)
  end
  session.server, session.client, session.pending = nil, nil, nil
  session.authenticated = false
end

local function fail(session, message)
  if M.sessions[session.term_id] ~= session then
    return
  end
  release(session)
  M.known[session.term_id] = nil
  session.status, session.message = "disconnected", message
  emit(session)
end

local function timer(session, callback)
  stop_timer(session)
  local handle = uv.new_timer()
  session.timer = handle
  handle:start(
    config.options.workspace.timeout,
    0,
    vim.schedule_wrap(function()
      if M.sessions[session.term_id] == session and session.timer == handle then
        stop_timer(session)
        callback()
      end
    end)
  )
end

local function decode(value)
  assert(#value % 2 == 0 and not value:find("[^%da-f]"), "Invalid text encoding")
  return (value:gsub("..", function(byte)
    return string.char(tonumber(byte, 16))
  end))
end

local function receive(session, line)
  local fields = vim.split(line, "\t", { plain = true })
  local pending = session.pending
  if not pending or tonumber(fields[2]) ~= pending.id then
    return
  end
  if fields[1] == "BEGIN" then
    assert(#fields == 2 and not pending.rows, "Invalid snapshot header")
    pending.rows = {}
  elseif fields[1] == "VAR" then
    assert(#fields == 6 and pending.rows, "Invalid variable record")
    assert(#pending.rows < config.options.workspace.max_items, "Too many variables")
    local row = {}
    for index, name in ipairs({ "name", "type", "dimensions", "value" }) do
      assert(#fields[index + 2] <= 8192, "Variable field too long")
      row[name] = decode(fields[index + 2])
    end
    table.insert(pending.rows, row)
  elseif fields[1] == "END" then
    assert(#fields == 3 and pending.rows and (fields[3] == "0" or fields[3] == "1"), "Invalid snapshot end")
    session.variables, session.truncated = pending.rows, fields[3] == "1"
    session.pending = nil
    session.status, session.message = "ready", nil
    session.updated = os.date("%H:%M:%S")
    stop_timer(session)
    emit(session)
  elseif fields[1] == "ERROR" then
    assert(#fields == 3, "Invalid error record")
    session.pending = nil
    session.status, session.message = "error", decode(fields[3])
    stop_timer(session)
    emit(session)
  else
    error("Unknown workspace record")
  end
end

function M.track(term_id, term)
  if term then
    M.known[term_id] = { terminal = term, job_id = term.job_id }
  end
end

function M.disconnect(term_id)
  local session = M.sessions[term_id]
  if session then
    fail(session, "Disconnected")
  end
end

function M.refresh(term_id)
  local session = M.sessions[term_id]
  if not session or not session.authenticated then
    return false
  end
  local terminal = require("toggleterm.terminal")
  local current = terminal.get(term_id, true)
  if current ~= session.terminal or current.job_id ~= session.job_id then
    fail(session, "Julia terminal changed; reconnect with attach")
    return false
  end
  if session.pending then
    return true
  end
  session.sequence = session.sequence + 1
  session.pending = { id = session.sequence, bytes = 0 }
  session.status, session.message = "refreshing", nil
  timer(session, function()
    session.pending = nil
    session.status, session.message = "timeout", "Refresh timed out; showing last snapshot"
    emit(session)
  end)
  local options = config.options.workspace
  local request = ("REFRESH\t%d\t%d\t%d\n"):format(session.sequence, options.max_items, options.preview_length)
  session.client:write(request, function(err)
    if err then
      vim.schedule(function()
        fail(session, "Connection write failed: " .. err)
      end)
    end
  end)
  emit(session)
  return true
end

local function listen(session, token)
  session.server = assert(uv.new_tcp())
  assert(session.server:bind("127.0.0.1", 0))
  assert(session.server:listen(
    4,
    vim.schedule_wrap(function(err)
      if M.sessions[session.term_id] ~= session or not session.server or session.authenticated then
        return
      end
      if err then
        fail(session, "Connection failed: " .. err)
        return
      end
      local client = uv.new_tcp()
      local accepted = session.server:accept(client)
      if not accepted then
        close(client)
        return
      end
      session.candidates[client] = true
      local buffer, authenticated = "", false
      client:read_start(vim.schedule_wrap(function(read_err, data)
        if M.sessions[session.term_id] ~= session or client:is_closing() then
          return
        end
        if read_err or not data then
          session.candidates[client] = nil
          close(client)
          if authenticated then
            fail(session, "Julia connection closed")
          end
          return
        end
        buffer = buffer .. data
        if session.pending then
          session.pending.bytes = session.pending.bytes + #data
        end
        if #buffer > MAX_BYTES or (session.pending and session.pending.bytes > MAX_BYTES) then
          fail(session, "Workspace response exceeded size limit")
          return
        end
        while true do
          local newline = buffer:find("\n", 1, true)
          if not newline then
            if not authenticated and #buffer > 256 then
              session.candidates[client] = nil
              close(client)
            end
            return
          end
          local line = buffer:sub(1, newline - 1)
          buffer = buffer:sub(newline + 1)
          if not authenticated then
            if line ~= "HELLO\t" .. token .. "\t1" or session.authenticated then
              session.candidates[client] = nil
              close(client)
              return
            end
            authenticated, session.authenticated = true, true
            session.client = client
            M.track(session.term_id, session.terminal)
            session.candidates[client] = nil
            for candidate in pairs(session.candidates) do
              close(candidate)
            end
            session.candidates = {}
            close(session.server)
            session.server = nil
            stop_timer(session)
            M.refresh(session.term_id)
          else
            local ok = pcall(receive, session, line)
            if not ok then
              fail(session, "Invalid workspace response")
              return
            end
          end
        end
      end))
    end)
  ))
  return session.server:getsockname().port
end

local function julia_string(value)
  -- Julia string literals also interpolate '$', unlike JSON string literals.
  return '"'
    .. value:gsub('[\\"$\r\n\t]', {
      ["\\"] = "\\\\",
      ['"'] = '\\"',
      ["$"] = "\\$",
      ["\r"] = "\\r",
      ["\n"] = "\\n",
      ["\t"] = "\\t",
    })
    .. '"'
end

function M.connect(term_id, attach)
  local ok, terminal = pcall(require, "toggleterm.terminal")
  if not ok then
    return nil, "toggleterm.nvim is required"
  end
  local term = terminal.get(term_id, true)
  local existing = M.sessions[term_id]
  if existing and term == existing.terminal and term.job_id == existing.job_id then
    if existing.authenticated or existing.status == "connecting" then
      return existing
    end
  end
  if existing and (term ~= existing.terminal or term.job_id ~= existing.job_id) then
    fail(existing, "Julia terminal changed; reconnect with attach")
  end
  local known = M.known[term_id]
  if term and not attach and not (known and known.terminal == term and known.job_id == term.job_id) then
    return nil,
      ("Terminal %d is not a known Julia REPL; use :CodeRunWorkspace term=%d attach to confirm"):format(
        term_id,
        term_id
      )
  end
  if existing then
    release(existing)
  end
  if not term then
    local command = config.get_language("julia").start_cmd
    if not command or command == "" then
      return nil, "languages.julia.start_cmd is not configured"
    end
    local spawned, result = pcall(function()
      local created = terminal.Terminal:new({ id = term_id, cmd = command })
      created:spawn()
      return created
    end)
    if not spawned then
      return nil, "Unable to start Julia: " .. tostring(result)
    end
    term = result
    M.track(term_id, term)
  end
  local session = {
    term_id = term_id,
    terminal = term,
    job_id = term.job_id,
    status = "connecting",
    variables = {},
    candidates = {},
    sequence = 0,
  }
  M.sessions[term_id] = session
  local initialized, message = pcall(function()
    local token = uv.random(24):gsub(".", function(byte)
      return ("%02x"):format(byte:byte())
    end)
    local port = listen(session, token)
    timer(session, function()
      fail(session, "Julia did not connect; check the REPL and reconnect with attach")
    end)
    local path = julia_string(root .. "/scripts/workspace.jl")
    local bootstrap = (
      "if !isdefined(Main, :CodeRunnerWorkspace); Base.include(Main, %s); end; "
      .. "Main.CodeRunnerWorkspace.start(%d, %s);\n"
    ):format(path, port, julia_string(token))
    -- PTY input is queued during Julia startup; readiness comes from HELLO,
    -- not from guessing how long compilation takes.
    term:send(bootstrap, true)
  end)
  if not initialized then
    fail(session, "Unable to initialize workspace: " .. tostring(message))
    return nil, session.message
  end
  emit(session)
  return session
end

local group = vim.api.nvim_create_augroup("CodeRunnerJuliaSessions", { clear = true })
vim.api.nvim_create_autocmd("TermClose", {
  group = group,
  callback = function(event)
    for id, session in pairs(M.sessions) do
      if session.terminal.bufnr == event.buf then
        fail(session, "Julia terminal exited")
        M.known[id] = nil
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    for _, session in pairs(M.sessions) do
      release(session)
    end
  end,
})

return M
