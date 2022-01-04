local api = vim.api
local npcall = vim.F.npcall
local lsputil = require 'vim.lsp.util'

local M = {}

-- Most of the code below are borrowed from nvim.lsp.util.
-- The overall idea is quite striaghtforward. A LSP markdown response is first
-- processed by glow. Then, the we calcuate the height and the width for the
-- processed content. Finally, we open a floating terminal window to display the
-- rendered contents.

-- Most are Borrowed from nvim.lsp.util
local function close_preview_autocmd(events, winnr, bufnrs)
  local augroup = 'preview_window_' .. winnr

  -- close the preview window when entered a buffer that is not
  -- the floating window buffer or the buffer that spawned it
  vim.cmd(string.format([[
    augroup %s
      autocmd!
      autocmd BufEnter * lua require('glow-hover').close_preview_window(%d, {%s})
    augroup end
  ]], augroup, winnr, table.concat(bufnrs, ',')))

  vim.cmd(string.format([[
    augroup %s
      autocmd TermClose * ++once %s
    augroup end
  ]], augroup, 'call feedkeys(\'i\')'))

  if #events > 0 then
    vim.cmd(string.format([[
      augroup %s
        autocmd %s <buffer> lua require('glow-hover').close_preview_window(%d)
      augroup end
    ]], augroup, table.concat(events, ','), winnr))
  end
end

function M.set_boarder_highlight_autocmd(background, winnr)
    local augroup = 'preview_window_' .. winnr
    if vim.fn.hlexists('HoverFloatBorder') ~= 1 then
        if background == 'light' then
            vim.cmd(string.format([[
            augroup %s
            autocmd BufWinEnter * hi! FloatBorder ctermbg=None ctermfg=39
            augroup end
            ]], augroup))
        elseif background == 'dark' then
            vim.cmd(string.format([[
            augroup %s
            autocmd BufWinEnter * hi! FloatBorder ctermbg=None ctermfg=239
            augroup end
            ]], augroup))
        end
    else
            vim.cmd(string.format([[
            augroup %s
            autocmd BufWinEnter * hi! link FloatBorder HoverFloatBorder
            augroup end
            ]], augroup))
    end
end

-- Most are Borrowed from nvim.lsp.util
function M.close_preview_window(winnr, bufnrs)
  vim.schedule(function()
    -- exit if we are in one of ignored buffers
    if bufnrs and vim.tbl_contains(bufnrs, api.nvim_get_current_buf()) then
      return
    end

    local augroup = 'preview_window_' .. winnr
    vim.cmd(string.format([[
      augroup %s
        autocmd!
      augroup end
      augroup! %s
    ]], augroup, augroup))
    pcall(vim.api.nvim_win_close, winnr, true)
  end)
end

-- Borrowed from nvim.lsp.util
local function find_window_by_var(name, value)
  for _, win in ipairs(api.nvim_list_wins()) do
    if npcall(api.nvim_win_get_var, win, name) == value then
      return win
    end
  end
end

-- Most are Borrowed from nvim.lsp.util
function M.close_previous_previews(opts)

  opts.wrap = opts.wrap ~= false -- wrapping by default
  opts.stylize_markdown = opts.stylize_markdown ~= false
  opts.focus = opts.focus ~= false
  opts.close_events = opts.close_events or
                        {"CursorMoved", "CursorMovedI", "InsertCharPre"}

  local bufnr = api.nvim_get_current_buf()

  -- check if this popup is focusable and we need to focus
  if opts.focus_id and opts.focusable ~= false and opts.focus then
    -- Go back to previous window if we are in a focusable one
    local current_winnr = api.nvim_get_current_win()
    if npcall(api.nvim_win_get_var, current_winnr, opts.focus_id) then
      api.nvim_command("wincmd p")
      return bufnr, current_winnr
    end
    do
      local win = find_window_by_var(opts.focus_id, bufnr)
      if win and api.nvim_win_is_valid(win) and vim.fn.pumvisible() == 0 then
        -- focus and return the existing buf, win
        api.nvim_set_current_win(win)
        api.nvim_command("stopinsert")
        return api.nvim_win_get_buf(win), win
      end
    end
  end

  -- check if another floating preview already exists for this buffer
  -- and close it if needed
  local existing_float = npcall(api.nvim_buf_get_var, bufnr,
    "lsp_floating_preview")
  if existing_float and api.nvim_win_is_valid(existing_float) then
    api.nvim_win_close(existing_float, true)
  end

  return opts
end

-- Open a terminal in a floating window and display glow generated contents.
function M.open_floating_term(contents, opts)
  local width, height = lsputil._make_floating_popup_size(contents)
  local float_opts = lsputil.make_floating_popup_options(math.min(width,
    opts.width), height)
  float_opts.border = opts.border

  local bufnr = api.nvim_get_current_buf()
  local parent_winnr = api.nvim_get_current_win()
  local floating_bufnr = api.nvim_create_buf(false, true)
  M.set_boarder_highlight_autocmd(opts.background, floating_bufnr)
  local floating_winnr = api.nvim_open_win(floating_bufnr, true, float_opts)

  local tfn = os.tmpname()
  local tf = io.open(tfn, 'w')
  for _, line in ipairs(contents) do
    tf:write(line .. '\n')
  end
  tf:flush()
  local cmd = string.format("%s %s", opts.tail_cmd, tfn)
  vim.fn.termopen(cmd, {
    on_exit = function()
      tf:close();
      os.remove(tfn)
    end
  })
  api.nvim_set_current_win(parent_winnr)
  api.nvim_win_set_option(floating_winnr, 'foldenable', false)
  api.nvim_win_set_option(floating_winnr, 'wrap', opts.wrap)
  api.nvim_buf_set_option(floating_bufnr, 'modifiable', false)
  api.nvim_buf_set_option(floating_bufnr, 'bufhidden', 'wipe')
  api.nvim_buf_set_keymap(floating_bufnr, "n", "q", "<cmd>bdelete<cr>", {
    silent = true,
    noremap = true,
    nowait = true
  })

  close_preview_autocmd(opts.close_events, floating_winnr,
    {floating_bufnr, bufnr})
  if opts.focus_id then
    api.nvim_win_set_var(floating_winnr, opts.focus_id, bufnr)
  end
  api.nvim_buf_set_var(bufnr, "lsp_floating_preview", floating_winnr)
  return floating_winnr, floating_bufnr
end

function M.hovehandler(markdown_lines, opts)
  local lines = ''
  local maxstrwidth = 0
  for _, line in ipairs(markdown_lines) do
    maxstrwidth = math.max(vim.fn.strdisplaywidth(line), maxstrwidth)
    lines = lines .. line .. '\n'
  end
  local colorscheme = api.nvim_get_option('background')
  opts.background = colorscheme
  opts.width = math.min(maxstrwidth + opts.padding, opts.max_width)


  local tfn = os.tmpname()
  local tf = io.open(tfn, 'w')
  tf:write(lines)
  tf:flush()
  local cmd = string.format("%s -w %d -s %s %s", opts.glow_path, opts.width,
    colorscheme, tfn)
  local handle = io.popen(cmd)
  local rendered = handle:read("*a")
  handle:close()
  tf:close()
  os.remove(tfn)

  local renderedLines = {}
  for line in rendered:gmatch("([^\n]*)\n?") do
    renderedLines[#renderedLines + 1] = line:gsub('%s+$', '')
  end

  renderedLines = lsputil._trim(renderedLines)
  opts = M.close_previous_previews(opts)
  return M.open_floating_term(renderedLines, opts)
end

function M.setup(opts)
  opts = opts or {}
  opts.padding = opts.padding or 10
  opts.border = opts.border or 'shadow'
  opts.max_width = opts.max_width or 50
  opts.glow_path = opts.glow_path or 'glow'
  opts.tail_cmd = opts.tail_cmd or 'tail -f -n +0'

  vim.lsp.handlers['textDocument/hover'] =
    function(_, result, _, _)
      if not (result and result.contents) then
        print("No available info.")
        return
      end
      local markdown_lines = vim.lsp.util.convert_input_to_markdown_lines(
        result.contents)
      markdown_lines = vim.lsp.util.trim_empty_lines(markdown_lines)
      if vim.tbl_isempty(markdown_lines) then
        print("No available info.")
        return
      end
      M.hovehandler(markdown_lines, opts)
    end
end

return M
