local M = {}

M.defaults = {
  term_id = 1,
  startup_delay = 500,
  show_terminal = true,
  jump = true,
  notify = true,
  enabled_filetypes = { "python" },
  keymaps = {},
  languages = {
    python = {
      cell_marker = "^%s*# %%",
      comment = "^#",
      start_cmd = "sipy",
    },
    matlab = {
      cell_marker = "^%s*%%",
      comment = "^%%",
      start_cmd = "matlab -nodisplay",
    },
    julia = {
      cell_marker = "^%s*# %%",
      comment = "^#",
      start_cmd = "julia",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

function M.get_language(filetype)
  return M.options.languages[filetype] or M.options.languages.python
end

function M.is_enabled_filetype(filetype)
  return vim.tbl_contains(M.options.enabled_filetypes, filetype)
end

return M
