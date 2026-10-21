# CodeRunner.nvim

Send Python/Julia code cells, Tree-sitter code items, or visual selections from
any filetype in Neovim to a `toggleterm.nvim` terminal.

## How it works

CodeRunner cell and Tree-sitter commands are enabled only for the `python`
filetype by default. To enable Julia as well:

```lua
require("coderunner").setup({
  enabled_filetypes = { "python", "julia" },
})
```

Visual selection commands work in every filetype, independently of this list.

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
find the current Python or Julia code item. In Python, the whole nearest function
or class is sent; elsewhere, the current statement is sent. Julia supports long
and short-form functions (including `where` signatures), anonymous functions,
macro/type/module definitions, macro wrappers, and `do` blocks. Outside a
definition, the current standalone expression or statement is sent, including
multi-line assignments and calls. On a control-flow header (`if`, `for`, `try`,
etc.), the complete statement is sent; inside its body, the current item is sent.
Tree-sitter execution preserves indentation, blank lines and comments, including
those inside strings and Julia block comments.

For `:CodeRunSelection`, select code with `v`, `V`, or `<C-v>` and execute the
command or a visual keymap. Characterwise selections send only the selected
characters, linewise selections keep complete lines, and blockwise selections
send the selected rectangle. Indentation, tabs, trailing spaces, blank lines and
comments are preserved; tabs cut by a rectangle follow Neovim's native yank
behavior. Registers and clipboard settings are restored after extraction.
`jump` does not move the cursor for selection commands.

A new terminal starts the current filetype's `languages[ft].start_cmd` if
configured. For unconfigured filetypes, selection commands use the terminal's
default shell without falling back to Python. Existing terminals are reused as
is: use separate terminal ids for different interpreters. The receiving REPL
must support the submitted code; selection sending does not compile code or
start a language server.

## Requirements

- Neovim 0.8+
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim)
- A Tree-sitter parser for the current language (`python` or `julia`) when using
  `RunCurrentLine`; cell and visual selection commands do not need a parser
- The configured interpreter executable available in Neovim's environment

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
:'<,'>CodeRunSelection [args]
```

`CodeRunBlock` and `CodeRunCell` do the same thing. `CodeRunCurrentLine` and
`RunCurrentLine` do the same thing. `CodeRunSelection` accepts the visual range
inserted by `:` and preserves the selection's columns and mode. Without a range,
it uses the live or most recent visual selection in the current buffer. An
explicit line range such as `:2,5CodeRunSelection` sends complete lines (a range
matching the last visual marks uses that selection). Empty or whitespace-only
selections are not sent.

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
:'<,'>CodeRunSelection term=2 show
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

vim.keymap.set("x", "<leader>rs", function()
  require("coderunner").run_selection("show term=2")
end, {
  desc = "Send selected code",
})
```

Lua helpers accept the same argument string as commands:

- `require("coderunner").run_block("hide nojump")`
- `require("coderunner").run_line("term=2 show jump")`
- `require("coderunner").run_selection("term=2 show")`

The lower-level `send_selection({ term_id = 2, show_terminal = true })` helper
also accepts an options table.

## Tests

Run the headless regression suite with `make test`. It uses real Python and
Julia Tree-sitter parsers and a mocked terminal, and needs no test framework.
If these parsers are not already installed, `make test-deps` downloads pinned
parser sources and builds them under `tests/.deps` (requires Git and a C compiler).
CI runs both steps.

`make test-integration` additionally exercises a real Julia REPL and shell. It
requires Julia, the parsers, and an installed toggleterm.nvim. Set
`TOGGLETERM_RTP=/path/to/toggleterm.nvim` if the plugin is not under
`stdpath("data")/site/pack/core/opt/toggleterm.nvim`.
