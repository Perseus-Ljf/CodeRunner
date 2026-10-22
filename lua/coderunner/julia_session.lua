local config = require("coderunner.config")
local uv = vim.uv or vim.loop
local M = { sessions = {}, known = {} }
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local MAX_BYTES = 8 * 1024 * 1024
local pump, schedule_auto

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
  close(session.auto_timer)
  close(session.server)
  close(session.client)
  for client in pairs(session.candidates or {}) do
    close(client)
  end
  for _, node in pairs(session.nodes or {}) do
    node.loading = false
  end
  session.candidates = {}
  session.server, session.client, session.pending, session.auto_timer = nil, nil, nil, nil
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

local function attach_rows(session, rows, parent)
  for _, node in ipairs(rows) do
    node.parent = parent
    node.path = (parent and parent.path or "") .. "/" .. #node.name .. ":" .. node.name
    if node.expandable then
      session.nodes[node.id] = node
    end
  end
end

local function receive(session, line)
  if line == "CHANGED" then
    if config.options.workspace.auto_refresh then
      session.dirty = true
      schedule_auto(session)
    end
    return
  end
  local fields = vim.split(line, "\t", { plain = true })
  local pending = session.pending
  if not pending or tonumber(fields[2]) ~= pending.id then
    return
  end
  if fields[1] == "BEGIN" then
    local generation = tonumber(fields[3])
    assert(#fields == 3 and not pending.rows and generation and generation > 0, "Invalid snapshot header")
    assert(not pending.node or generation == session.generation, "Stale child response")
    pending.generation, pending.rows = generation, {}
  elseif fields[1] == "VAR" then
    assert(#fields == 8 and pending.rows, "Invalid variable record")
    assert(#pending.rows < pending.limit, "Too many variables")
    local row = {}
    for index, name in ipairs({ "name", "type", "dimensions", "value" }) do
      assert(#fields[index + 2] <= 8192, "Variable field too long")
      row[name] = decode(fields[index + 2])
    end
    row.id = tonumber(fields[7])
    row.expandable = fields[8] == "1"
    assert(row.id and row.id >= 0 and row.id % 1 == 0 and (fields[8] == "0" or fields[8] == "1"), "Invalid object id")
    assert((row.id > 0) == row.expandable, "Invalid expandable object")
    table.insert(pending.rows, row)
  elseif fields[1] == "END" then
    assert(#fields == 3 and pending.rows and (fields[3] == "0" or fields[3] == "1"), "Invalid snapshot end")
    if pending.node then
      pending.node.children, pending.node.truncated = pending.rows, fields[3] == "1"
      pending.node.loading, pending.node.error = false, nil
      attach_rows(session, pending.rows, pending.node)
    else
      session.nodes = {}
      session.variables, session.truncated = pending.rows, fields[3] == "1"
      session.generation = pending.generation
      session.updated = os.date("%H:%M:%S")
      attach_rows(session, pending.rows)
    end
    session.pending = nil
    session.status, session.message = "ready", nil
    stop_timer(session)
    pump(session)
    emit(session)
  elseif fields[1] == "ERROR" then
    assert(#fields == 3, "Invalid error record")
    local message = decode(fields[3])
    if pending.node then
      pending.node.error, pending.node.loading = message, false
    end
    session.pending = nil
    session.status, session.message = "error", message
    stop_timer(session)
    emit(session)
    pump(session)
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

local function current(session)
  if not session or not session.authenticated then
    return false
  end
  local terminal = require("toggleterm.terminal").get(session.term_id, true)
  if terminal ~= session.terminal or terminal.job_id ~= session.job_id then
    fail(session, "Julia terminal changed; reconnect with attach")
    return false
  end
  return true
end

local function request(session, node)
  if not current(session) then
    return false
  end
  local options = config.options.workspace
  session.sequence = session.sequence + 1
  local limit = node and options.max_children or options.max_items
  session.pending = { id = session.sequence, bytes = 0, limit = limit, node = node }
  session.status, session.message = node and "expanding" or "refreshing", nil
  if node then
    node.loading, node.error = true, nil
  end
  timer(session, function()
    if node then
      node.loading, node.error = false, "Expansion timed out"
    end
    session.pending = nil
    session.status, session.message = "timeout", "Request timed out; showing last snapshot"
    emit(session)
    -- Retry only on a new execution event or an explicit refresh, not a loop.
    if session.dirty then
      schedule_auto(session)
    end
  end)
  local message = node
      and ("CHILDREN\t%d\t%d\t%d\t%d\t%d\n"):format(
        session.sequence,
        session.generation,
        node.id,
        limit,
        options.preview_length
      )
    or ("REFRESH\t%d\t%d\t%d\n"):format(session.sequence, limit, options.preview_length)
  session.client:write(message, function(err)
    if err then
      vim.schedule(function()
        fail(session, "Connection write failed: " .. err)
      end)
    end
  end)
  emit(session)
  return true
end

function M.refresh(term_id)
  local session = M.sessions[term_id]
  if not current(session) then
    return false
  end
  if session.pending then
    -- A manual root refresh takes priority over a queued child expansion.
    session.refresh_queued = session.pending.node ~= nil
    return true
  end
  close(session.auto_timer)
  session.auto_timer, session.dirty, session.refresh_queued = nil, false, false
  return request(session)
end

schedule_auto = function(session)
  if not session.authenticated or not config.options.workspace.auto_refresh then
    return
  end
  close(session.auto_timer)
  local handle = uv.new_timer()
  session.auto_timer = handle
  handle:start(
    config.options.workspace.refresh_delay,
    0,
    vim.schedule_wrap(function()
      if M.sessions[session.term_id] ~= session or session.auto_timer ~= handle then
        return
      end
      close(handle)
      session.auto_timer = nil
      if not session.pending and session.dirty then
        M.refresh(session.term_id)
      end
    end)
  )
end

local function unloaded(session, nodes)
  for _, node in ipairs(nodes) do
    if node.expandable and session.expanded[node.path] then
      if not node.children and not node.error then
        return node
      end
      local child = unloaded(session, node.children or {})
      if child then
        return child
      end
    end
  end
end

pump = function(session)
  if not session.authenticated or session.pending then
    return
  end
  if session.refresh_queued then
    M.refresh(session.term_id)
  elseif session.dirty and config.options.workspace.auto_refresh then
    schedule_auto(session)
  else
    local node = unloaded(session, session.variables)
    if node then
      request(session, node)
    end
  end
end

function M.expand(term_id, node, expanded)
  local session = M.sessions[term_id]
  if not current(session) or not node.expandable or session.nodes[node.id] ~= node then
    return false
  end
  session.expanded[node.path] = expanded
  if expanded then
    node.error = nil
  end
  emit(session)
  pump(session)
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
      if not session.server:accept(client) then
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
            local fields = vim.split(line, "\t", { plain = true })
            if fields[1] ~= "HELLO" or fields[2] ~= token or session.authenticated then
              session.candidates[client] = nil
              close(client)
              return
            end
            if #fields ~= 4 or fields[3] ~= "2" or (fields[4] ~= "0" and fields[4] ~= "1") then
              fail(session, "Workspace helper is outdated; restart Julia to reconnect")
              return
            end
            authenticated, session.authenticated = true, true
            session.auto_supported = fields[4] == "1"
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
    nodes = {},
    expanded = {},
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
