# CodeRunner.nvim

Send Python code cells or Tree-sitter code items from Neovim to a
`toggleterm.nvim` terminal.

## How it works

CodeRunner is enabled only for the `python` filetype by default. Other
filetypes can be enabled through configuration.

For cell commands, CodeRunner finds the code cell around the cursor by looking
for language-specific cell markers:

- Python and Julia: `# %%`
- MATLAB: `%%`

When `:CodeRunBlock` or `:CodeRunCell` is executed, the plugin:

1. Finds the nearest cell marker above the cursor and the next marker below it.
2. Reads the lines inside that range.
3. Drops blank lines and language comment-only lines.
4. Opens or reuses a `toggleterm.nvim` terminal.
5. Starts the configured language command when the terminal is new.
6. Sends the filtered code to that terminal.

For `:RunCurrentLine` and `:CodeRunCurrentLine`, CodeRunner uses Tree-sitter to
find the current Python code item. If the cursor is inside a function or class,
the whole nearest function or class is sent. Otherwise, the current statement is
sent, including multi-line calls, assignments, and other split statements.

## Requirements

- Neovim 0.8+
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim)
- A Tree-sitter parser for Python when using `RunCurrentLine`

## Installation

With `lazy.nvim`:

```lua
{
  "your-name/CodeRunner",
  dependencies = { "akinsho/toggleterm.nvim" },
  config = function()
    require("coderunner").setup()
  end,
}
```

The plugin also has a `plugin/coderunner.lua` runtime file, so commands are
registered automatically when it is loaded by a plugin manager.

## Commands

```vim
:CodeRunBlock [args]
:CodeRunCell [args]
:CodeRunCurrentLine [args]
:RunCurrentLine [args]
```

`CodeRunBlock` and `CodeRunCell` do the same thing. `CodeRunCurrentLine` and
`RunCurrentLine` do the same thing.

Arguments are whitespace-separated:

- `1`, `2`, or `term=2`: target toggleterm id.
- `show` / `hide`: show or hide the terminal after sending code.
- `jump` / `nojump`: move to the next cell or next Tree-sitter item after
  sending code.

Examples:

```vim
:CodeRunBlock show jump
:CodeRunBlock hide nojump
:CodeRunBlock term=2 show=false jump=false
:RunCurrentLine term=2 show nojump
```

## Configuration

```lua
require("coderunner").setup({
  term_id = 1,
  startup_delay = 500,
  show_terminal = true,
  jump = true,
  notify = true,
  enabled_filetypes = { "python" },
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
})
```

You can add or override entries in `languages` for any Neovim filetype.

## Keymaps

CodeRunner does not create keymaps internally. Use Neovim's normal keymap API:

```lua
vim.keymap.set("n", "<leader>rb", "<cmd>CodeRunBlock show jump<cr>", {
  desc = "Run current code cell",
})

vim.keymap.set("n", "<leader>rl", function()
  require("coderunner").run_line("show nojump")
end, {
  desc = "Run current Tree-sitter item",
})

vim.keymap.set("n", "<leader>rL", function()
  require("coderunner").run_line("hide jump term=2")
end, {
  desc = "Run current Tree-sitter item in background",
})
```

Lua helpers accept the same argument string as commands:

- `require("coderunner").run_block("hide nojump")`
- `require("coderunner").run_line("term=2 show jump")`
