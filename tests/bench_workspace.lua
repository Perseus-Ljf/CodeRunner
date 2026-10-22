-- Opt-in rendering microbenchmark, independent of Julia and toggleterm.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.columns, vim.o.lines = 140, 40
local uv = vim.uv or vim.loop
require("coderunner").setup()
local terminal = { job_id = 1 }
package.loaded["toggleterm.terminal"] = {
  get = function()
    return terminal
  end,
}
local workspace = require("coderunner.workspace")
local sessions = require("coderunner.julia_session")
workspace.buffer = vim.api.nvim_create_buf(false, true)
workspace.term_id = 1
vim.cmd("botright vertical 60split")
workspace.window = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(workspace.window, workspace.buffer)

local function leaf(name, parent)
  return {
    name = name,
    type = "String",
    dimensions = "",
    value = string.rep("value", 20),
    path = (parent and parent.path or "") .. "/" .. name,
    parent = parent,
  }
end
local function median(values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.floor(#sorted / 2) + 1]
end
local results = {}
for _, count in ipairs({ 50, 500, 2000 }) do
  local folder = {
    id = 1,
    name = "model",
    type = "Model",
    dimensions = "",
    value = "100 fields",
    path = "/model",
    expandable = true,
    children = {},
  }
  for index = 1, 100 do
    folder.children[index] = leaf("field" .. index, folder)
  end
  local variables = { folder }
  for index = 2, count do
    variables[index] = leaf("variable" .. index)
  end
  local session = {
    term_id = 1,
    terminal = terminal,
    job_id = 1,
    authenticated = true,
    auto_supported = true,
    status = "ready",
    variables = variables,
    nodes = { [1] = folder },
    expanded = {},
    updated = "12:00:00",
  }
  sessions.sessions[1] = session
  workspace.preferred_path, workspace.rendered_selection = nil, nil
  workspace.render()
  local samples = {}
  collectgarbage("collect")
  for index = 1, 25 do
    local started = uv.hrtime()
    assert(sessions.expand(1, folder, true))
    assert(sessions.expand(1, folder, false))
    samples[index] = (uv.hrtime() - started) / 1e6
  end
  results[tostring(count)] = { first_ms = samples[1], median_ms = median(samples) }
  print(
    ("Cached expand + collapse, %4d roots: first=%.3f ms median=%.3f ms"):format(count, samples[1], median(samples))
  )
end
if vim.env.CODERUNNER_BENCH_OUTPUT then
  vim.fn.writefile({ vim.fn.json_encode(results) }, vim.env.CODERUNNER_BENCH_OUTPUT)
end
workspace.close()
vim.cmd("qa!")
