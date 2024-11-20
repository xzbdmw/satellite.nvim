local api = vim.api
local fn = vim.fn

local util = require 'satellite.util'
local async = require 'satellite.async'

local HIGHLIGHT = 'SatelliteSearch'
local HIGHLIGHT_CURRENT = 'SatelliteSearchCurrent'

--- @class Satellite.Handlers.SearchConfig: Satellite.Handlers.BaseConfig
local config = {
  enable = true,
  overlap = true,
  priority = 1000,
  symbols = { '⠂', '⠅', '⠇', '⠗', '⠟', '⠿' },
}

--- @class Satellite.Handlers.Search.CacheElem
--- @field changedtick integer
--- @field pattern string
--- @field matches integer[]

--- @type table<integer, Satellite.Handlers.Search.CacheElem>
local cache = {}

local function is_search_mode()
  if
    vim.o.incsearch
    and vim.o.hlsearch
    and api.nvim_get_mode().mode == 'c'
    and vim.tbl_contains({ '/', '?' }, fn.getcmdtype())
  then
    return true
  end
  return false
end

--- @param pattern string
--- @return string
local function smartcaseify(pattern)
  if pattern and vim.o.ignorecase and vim.o.smartcase then
    -- match() does not use 'smartcase' so we must handle it
    local smartcase = pattern:find('[A-Z]') ~= nil
    if smartcase and not vim.startswith(pattern, '\\C') then
      return '\\C' .. pattern
    end
  end
  return pattern
end

--- @return string
local function get_pattern()
  if is_search_mode() then
    return vim.fn.getcmdline()
  end
  return vim.v.hlsearch == 1 and fn.getreg('/') --[[@as string]]
    or ''
end

--- @param bufnr integer
--- @param pattern? string
--- @return table<integer,integer>

--- @type Satellite.Handler
local handler = {
  name = 'search',
}

local function setup_hl()
  api.nvim_set_hl(0, HIGHLIGHT, {
    default = true,
    fg = api.nvim_get_hl_by_name('Search', true).background,
  })

  local has_sc, sc_hl = pcall(api.nvim_get_hl_by_name, 'SearchCurrent', true)
  if has_sc then
    api.nvim_set_hl(0, HIGHLIGHT_CURRENT, {
      default = true,
      fg = sc_hl.background,
    })
  end
end

function handler.setup(config0, update)
  config = vim.tbl_deep_extend('force', config, config0)
  handler.config = config

  local group = api.nvim_create_augroup('satellite_search', {})

  api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = setup_hl,
  })

  setup_hl()
end

--- @param bufnr integer
--- @param pattern? string
--- @return table<integer,integer>
local function update_matches(bufnr, pattern)
  local pos = vim.g.search_pos
  if pos == nil then
    return {}
  end
  local matches = {}
  for _, s in ipairs(pos.sList) do
    if matches[s[1]] == nil then
      matches[s[1]] = 1
    else
      matches[s[1]] = matches[s[1]] + 1
    end
  end
  bufnr = vim.api.nvim_get_current_buf()
  cache[bufnr] = {
    pattern = get_pattern(),
    changedtick = vim.b[bufnr].changedtick,
    matches = matches,
  }
  return matches
end

local function get_illuminate(winid)
  local HL_K_NAMESPACE = vim.api.nvim_create_namespace('illuminate.highlightkeep')
  local extmarks =
    vim.api.nvim_buf_get_extmarks(0, HL_K_NAMESPACE, 0, -1, { details = true, type = 'highlight' })
  local marks = {}
  for _, extmark in ipairs(extmarks) do
    local end_row = extmark[4].end_row
    marks[#marks + 1] = {
      ---@diagnostic disable-next-line: param-type-mismatch
      pos = util.row_to_barpos(winid, end_row),
      symbol = '=',
      highlight = 'Type',
    }
  end
  return marks
end

local function get_trouble(winid)
  local trouble_ns = vim.api.nvim_create_namespace('trouble.highlight')
  local extmarks =
    vim.api.nvim_buf_get_extmarks(0, trouble_ns, 0, -1, { details = true, type = 'highlight' })
  local marks = {}
  for _, extmark in ipairs(extmarks) do
    local end_row = extmark[4].end_row
    marks[#marks + 1] = {
      ---@diagnostic disable-next-line: param-type-mismatch
      pos = util.row_to_barpos(winid, end_row),
      symbol = '=',
      highlight = '@exception',
    }
  end
  return marks
end

function handler.update(bufnr, winid)
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_win_is_valid(winid) then
    return {}
  end

  local marks = {} --- @type SearchMark[]

  local matches = update_matches(bufnr)
  local illuminates = get_illuminate(winid)
  if #illuminates > 0 then
    return illuminates
  end
  local trouble = get_trouble(winid)
  if #trouble > 0 then
    return trouble
  end
  local cursor_lnum = api.nvim_win_get_cursor(winid)[1]

  for lnum, count in pairs(matches) do
    local pos = util.row_to_barpos(winid, lnum - 1)

    if marks[pos] and marks[pos].count then
      count = count + marks[pos].count
    end

    if lnum == cursor_lnum then
      marks[pos] = {
        count = count,
        highlight = HIGHLIGHT_CURRENT,
        unique = true,
      }
    elseif count <= #config.symbols then
      marks[pos] = {
        count = count,
      }
    end
  end

  local ret = {} --- @type Satellite.Mark[]

  for pos, mark in pairs(marks) do
    ret[#ret + 1] = {
      pos = pos,
      unique = mark.unique,
      highlight = HIGHLIGHT,
      symbol = '=',
    }
  end

  return ret
end

require('satellite.handlers').register(handler)
