if vim.g.loaded_coderunner == 1 then
  return
end
vim.g.loaded_coderunner = 1

require("coderunner").setup()
