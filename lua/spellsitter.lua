local query = require'vim.treesitter.query'
local get_parser = vim.treesitter.get_parser

local api = vim.api

local M = {}

local cfg
local ns

local marks = {}

-- Main spell checking function
local spell_check_iter

local function add_extmark(bufnr, lnum, col, len)
  -- TODO: This errors because of an out of bounds column when inserting
  -- newlines. Wrapping in pcall hides the issue.

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, col, {
    end_line = lnum,
    end_col = col+len,
    hl_group = cfg.hl_id,
    ephemeral = true
  })

  if not ok then
    print(('ERROR: Failed to add extmark, lnum=%d pos=%d'):format(lnum, col))
  end
  local lnum1 = lnum+1
  marks[bufnr] = marks[bufnr] or {}
  marks[bufnr][lnum1] = marks[bufnr][lnum1] or {}
  local lbmarks = marks[bufnr][lnum1]
  lbmarks[#lbmarks+1] = {col, col+len}
end

local hl_queries = {}

local function on_line(_, winid, bufnr, lnum)
  marks[bufnr] = marks[bufnr] or {}
  marks[bufnr][lnum+1] = nil

  local parser = get_parser(bufnr)

  local hl_query = hl_queries[parser:lang()]

  local line = api.nvim_buf_get_lines(bufnr, lnum, lnum+1, true)[1]

  parser:for_each_tree(function(tstree, _)
    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > lnum or root_end_row < lnum then
      return
    end

    for id, node in hl_query:iter_captures(root_node, bufnr, lnum, lnum+1) do
      if vim.tbl_contains(cfg.captures, hl_query.captures[id]) then
        local start_row, start_col, end_row, end_col = node:range()
        if lnum >= start_row and lnum <= end_row then
          -- This extracts the substring corresponding to the region we want to
          -- spell check from the line. Since this is a lua function on the line
          -- string, we need to convert the 0 indexed values of the columns, to 1
          -- indexed values. Note here that the value of the end column is end
          -- inclusive, so we need to increment it in addition to the start.
          if lnum ~= start_row then
            -- check from the start of this line
            start_col = 1
          else
            start_col = start_col + 1;
          end

          if lnum ~= end_row then
            -- check until the end of this line
            end_col = -1
          else
            end_col = end_col + 1;
          end

          local l = line:sub(start_col, end_col)
          for col, len in spell_check_iter(l, winid) do
            -- start_col is now 1 indexed, so subtract one to make it 0 indexed again
            add_extmark(bufnr, lnum, start_col + col - 1, len)
          end
        end
      end
    end
  end)
end

local excluded_filetypes = {
  rst = true -- Just let the legacy spellchecker apply to the whole buffer
}

local function buf_enabled(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if pcall(api.nvim_buf_get_var, bufnr, 'current_syntax') then
    return false
  end
  if excluded_filetypes[api.nvim_buf_get_option(bufnr, 'filetype')] then
    return false
  end
  if not api.nvim_buf_is_loaded(bufnr)
    or api.nvim_buf_get_option(bufnr, 'buftype') ~= '' then
    return false
  end
  if vim.tbl_isempty(cfg.captures) then
    return false
  end
  if not pcall(get_parser, bufnr) then
    return false
  end
  return true
end

local function on_win(_, _, bufnr)
  if not buf_enabled(bufnr) then
    return false
  end
  local parser = get_parser(bufnr)
  local lang = parser:lang()
  if not hl_queries[lang] then
    hl_queries[lang] = query.get_query(lang, "highlights")
  end

  -- FIXME: shouldn't be required. Possibly related to:
  -- https://github.com/nvim-treesitter/nvim-treesitter/issues/1124
  parser:parse()
end

-- Quickly enable 'spell' when running mappings as spell.c explicitly checks for
-- it for much of its functionality.
M._wrap_map = function(key)
  if not vim.wo.spell then
    vim.wo.spell = true
    vim.schedule(function()
      vim.wo.spell = false
    end)
  end
  return key
end

M.nav = function(reverse)
  local bufnr = api.nvim_get_current_buf()
  local target = (function()
    -- This api uses a 1 based indexing for the rows (matching the row numbers
    -- within the UI) and a 0 based indexing for columns.
    local row, col = unpack(api.nvim_win_get_cursor(0))

    marks[bufnr] = marks[bufnr] or {}

    local bmarks = marks[bufnr]

    if reverse then
      -- From the current row number to the start in reverse. Here we are
      -- working with a 1 based indexing for the rows, hence the final value is
      -- 1.
      for i = row, 1, -1 do
        -- Run on_line in case that line hasn't been drawn yet.
        -- Here we are converting the 1 indexed values we have been using to a
        -- 0 indexed value which the on_line function takes.
        on_line(nil, 0, bufnr, i-1)
        if bmarks[i] then
          for j = #bmarks[i], 1, -1 do
            local m = bmarks[i][j]
            if i ~= row or col > m[1] then
              -- We are using this directly as input to nvim_win_set_cursor,
              -- which uses a 1 based index, so we set this with i rather than
              -- row_num.
              return {i, m[1]}
            end
          end
        end
      end
    else
      -- From the current row number to the end. Here we are working with 1
      -- indexed values, so we go all the way to the last line of the file.
      for i = row, vim.fn.line('$') do
        -- Run on_line in case that line hasn't been drawn yet
        -- Here we are converting the 1 indexed values we have been using to a
        -- 0 indexed value which the on_line function takes.
        on_line(nil, 0, bufnr, i-1)
        if bmarks[i] then
          for j = 1, #bmarks[i] do
            local m = bmarks[i][j]
            if i ~= row or col < m[1] then
              -- We are using this directly as input to nvim_win_set_cursor,
              -- which uses a 1 based index, so we set this with i rather than
              -- row_num.
              return {i, m[1]}
            end
          end
        end
      end
    end
  end)()

  if target then
    api.nvim_win_set_cursor(0, target)
  end
end

M.attach = vim.schedule_wrap(function(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not buf_enabled(bufnr) then
    return false
  end

  -- Not all these need to be wrapped but spell.c is pretty messy so wrap them
  -- for good measure.
  for _, key in ipairs{
    'z=', 'zW', 'zg', 'zG', 'zw', 'zuW', 'zug', 'zuG', 'zuw'
  } do
    api.nvim_buf_set_keymap(bufnr, 'n', key,
      string.format([[v:lua.package.loaded.spellsitter._wrap_map('%s')]], key),
      {expr=true}
    )
  end

  api.nvim_buf_set_keymap(bufnr, 'n', ']s', [[<cmd>lua require'spellsitter'.nav()<cr>]], {})
  api.nvim_buf_set_keymap(bufnr, 'n', '[s', [[<cmd>lua require'spellsitter'.nav(true)<cr>]], {})
  vim.wo.spell = false
end)

local valid_spellcheckers = {'vimfn', 'ffi'}

function M.setup(cfg_)
  cfg = cfg_ or {}
  cfg.hl = cfg.hl or 'SpellBad'
  cfg.hl_id = api.nvim_get_hl_id_by_name(cfg.hl)
  cfg.captures = cfg.captures or {'comment'}
  cfg.spellchecker = cfg.spellchecker or 'vimfn'

  if not vim.tbl_contains(valid_spellcheckers, cfg.spellchecker) then
    error(string.format('spellsitter: %s is not a valid spellchecker. Must be one of: %s',
      cfg.spellchecker, table.concat(valid_spellcheckers, ', ')))
  end

  ns = api.nvim_create_namespace('spellsitter')

  spell_check_iter = require('spellsitter.spellcheck.'..cfg.spellchecker)

  api.nvim_set_decoration_provider(ns, {
    on_win = on_win,
    on_line = on_line,
  })

  for _, buf in ipairs(api.nvim_list_bufs()) do
    M.attach(buf)
  end

  vim.cmd[[
    augroup spellsitter
    autocmd!
    autocmd BufRead,BufNew,BufNewFile * lua _G.package.loaded.spellsitter.attach()
    augroup END
  ]]
end

return M
