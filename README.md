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

Julia submissions suppress automatic REPL result display by default. Single-line
submissions append a trailing `;`; multiline submissions are wrapped in
`begin ... end;` so earlier expressions do not print their results either. The
wrapper adds no local scope and leaves the source buffer unchanged. Explicit
output such as `println` is unaffected. Set
`languages.julia.suppress_output = false` to send the original code without
suppression. Other languages are unchanged.

A multiline submission is evaluated as one block: an exception stops the rest
of that submission, and `ans` receives the block's final result rather than
being updated after each internal expression.

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

## Julia Workspace

Open a read-only sidebar for the Julia process in a toggleterm terminal:

```vim
:CodeRunWorkspace
:CodeRunWorkspace term=2
```

The command toggles the sidebar. It uses `term_id` by default, starts
`languages.julia.start_cmd` if the terminal does not exist, and automatically
recognizes Julia terminals started by CodeRunner during this Neovim session.
For a Julia REPL you started yourself, explicitly confirm the interpreter:

```vim
:CodeRunWorkspace term=2 attach
```

Only use `attach` with an idle Julia REPL, not a shell, Python interpreter,
remote SSH session, or a partially entered Julia expression. The helper is
loaded into that exact process, so existing variables are available without
restarting Julia. Each terminal has an independent connection and snapshot.

The sidebar displays `Main`'s globals in a compact variable / value / type tree.
Built-in array sizes are shown with their previews. Internal names, modules and
explicitly imported bindings are excluded. Wide panels use aligned columns;
narrow panels prioritize variable names and values. `K` always shows the full
bounded summary, including the type.

**Automatic refresh** is enabled by default. A Julia REPL integration sends an
event after each expression finishes, including expressions that throw. This
covers CodeRunner's line, block and selection commands as well as code typed
directly into the REPL. Bursts are debounced, and updates arriving during a
request trigger a subsequent snapshot. There is no polling and no completion
code appended to the terminal input. Expression results, `ans`, top-level
struct definitions and REPL soft scope are preserved. Background tasks that
mutate objects after the REPL expression has returned do not independently
trigger refresh; use `r` in that case.

**Tree browsing** reads struct fields, nested structs, tuples, named tuples and
built-in array elements on demand. Struct children mean instance fields, not a
subtype hierarchy. It uses `getfield`, not user-defined `getproperty` or `show`.
Uninitialized fields show `#undef`; circular references and depth/node limits
are marked instead of recursively traversed. Expansions are retained across
refreshes, while object references and loaded children are rebuilt for the new
snapshot. The selected field and scroll position are preserved when possible.
Each expansion shows at most `max_children` entries, with an omitted-items
marker for larger objects. Dictionary previews remain summaries rather than
expandable key/value views.

- `r` or `:CodeRunWorkspaceRefresh`: refresh immediately.
- `<CR>` / `<Space>`: expand or collapse an object; inspect a leaf.
- `l` / `<Right>`: expand or move to the first child.
- `h` / `<Left>`: collapse or move to the parent.
- `K`: inspect the selected node without the sidebar's width truncation.
- `q`: close the sidebar without stopping Julia or disconnecting.
- `:CodeRunWorkspaceDisconnect`: disconnect without stopping Julia.

Table viewers and function-local debugging are not included.

Refresh and disconnect commands also accept `term=N`. A disconnected process
can be reattached with `:CodeRunWorkspaceRefresh term=N attach`. Connections
and refreshes time out without blocking Neovim. The last complete snapshot is
retained on timeout or disconnect; its timestamp and status remain visible.
After a process exits or is replaced, confirm the new Julia REPL with `attach`.
A long calculation that does not yield can delay a refresh; a timeout does not
interrupt Julia or cancel user code.

Workspace uses Julia's `Sockets` and `REPL` standard libraries and an
authenticated local loopback connection. No Julia packages are installed,
project files are not changed, and variable data is not parsed from terminal
output. Nothing is loaded into Julia until a workspace command requests a
connection. The REPL hook is installed once and becomes a no-op after
disconnection. If a REPL does not support the hook, the sidebar displays
`Manual` and manual refresh remains available. Integration-tested with Julia
1.12.6; remote processes are not supported yet.

When upgrading from the original Workspace version, restart the Julia process
as well as Neovim: the helper protocol has changed. An old helper is rejected
with a restart message rather than silently reusing incompatible objects.

Optional settings (shown with defaults):

```lua
require("coderunner").setup({
  enabled_filetypes = { "python", "julia" },
  workspace = {
    width = 60,             -- 24..200; initially capped at half the screen
    position = "right",     -- "left" or "right"
    timeout = 15000,        -- 100..120000 milliseconds
    auto_refresh = true,   -- REPL execution-completion events
    refresh_delay = 150,   -- 0..5000 ms debounce
    max_items = 500,        -- 1..2000 variables; '+' indicates truncation
    max_children = 100,    -- 1..500 fields/elements per expansion
    preview_length = 120,  -- 16..512 characters, plus truncation marker
  },
})
```

Workspace commands do not require a Tree-sitter parser or an enabled Julia
filetype. Existing code-sending commands and other languages are unchanged.

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
      suppress_output = true,
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
CI runs both steps. `make test` also exercises workspace UI and IPC handling
with simulated Julia peers, without requiring Julia or toggleterm.

`make test-julia` checks conservative variable previews and the helper's real
socket protocol using Julia's standard libraries only.

`make test-integration` additionally exercises a real Julia REPL and shell,
including workspace startup, same-process snapshots, execution-completion
refresh (plugin and manual input), errors, REPL semantics, nested struct
updates, reconnection, process isolation and terminal exit. It
requires Julia, the parsers, and an installed toggleterm.nvim. Set
`TOGGLETERM_RTP=/path/to/toggleterm.nvim` if the plugin is not under
`stdpath("data")/site/pack/core/opt/toggleterm.nvim`.

`make bench-workspace` runs opt-in expansion microbenchmarks: Julia field
traversal, real loopback TCP responses, and cached expand/collapse rendering
with 50, 500 and 2000 root variables. It reports first-use and warm median times,
without timing thresholds in CI. Helper loading is outside these timings;
common traversal code is precompiled during loading, without reading user
objects. This needs Julia and Neovim, but no parsers or toggleterm.
