# CodeRunner.nvim

Send the current code cell from Neovim to a `toggleterm.nvim` terminal.

## How it works

CodeRunner finds the code cell around the cursor by looking for language-specific
cell markers:

- Python and Julia: `# %%`
- MATLAB: `%%`

When `:CodeRunBlock` or `:CodeRunCell` is executed, the plugin:

1. Finds the nearest cell marker above the cursor and the next marker below it.
2. Reads the lines inside that range.
3. Drops blank lines and language comment-only lines.
4. Opens or reuses a `toggleterm.nvim` terminal.
5. Starts the configured language command when the terminal is new.
6. Sends the filtered code to that terminal.

## Requirements

- Neovim 0.8+
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim)

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
:CodeRunBlock [term_id]
:CodeRunCell [term_id]
```

Both commands do the same thing. `term_id` is optional and defaults to `1`.

## Configuration

```lua
require("coderunner").setup({
  term_id = 1,
  startup_delay = 500,
  notify = true,
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
