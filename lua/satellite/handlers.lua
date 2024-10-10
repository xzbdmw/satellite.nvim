local api = vim.api

local user_config = require 'satellite.config'.user_config
local async = require 'satellite.async'

--- @class Satellite.Mark
--- Row of the mark, use `require('satellite.util').row_to_barpos(winid, lnum)`
--- to translate an `lnum` from window `winid` to its respective scrollbar row.
--- @field pos integer
---
--- Highlight group of the mark.
--- @field highlight string
---
--- Symbol of the mark. Must be a single character.
--- @field symbol string
---
--- By default, for each position in the scrollbar, Satellite will only use the
--- last mark with that position. This field indicates the mark is special and
--- must be rendered even if there is another mark at the same position from the
--- handler.
--- @field unique? boolean
---
--- @field count? integer

--- @class Satellite.Handler
---
--- Name of the Handler
--- @field name string
---
--- @field config Satellite.Handlers.BaseConfig
---
--- Whether the handler is enabled or not.
--- @field enabled fun(self: Satellite.Handler): boolean
---
--- Setup the handler and autocmds that are required to trigger the handler.
--- @field setup? fun(user_config: Satellite.Handlers.BaseConfig, update: fun())
---
--- This function is called when the handler needs to update. It must return
--- a list of SatelliteMark's
--- @field update fun(bufnr: integer, winid: integer): Satellite.Mark[]
---
--- @field package ns integer
local Handler = {}

local M = {}
M.sign_ns = vim.api.nvim_create_namespace('satellite_sign')
M.gits_sign_ns = vim.api.nvim_create_namespace('satellite_gitsign')
local BUILTIN_HANDLERS = {
  'search',
  'diagnostic',
  'gitsigns',
  'marks',
  'cursor',
  'quickfix',
}

--- @type Satellite.Handler[]
M.handlers = {}

--- @param name string
--- @return boolean
local function enabled(name)
  local handler_config = user_config.handlers[name]
  return not handler_config or handler_config.enable ~= false
end

function Handler:enabled()
  return enabled(self.name)
end

--- @package
--- @param self Satellite.Handler
--- @param bufnr integer
--- @param m Satellite.Mark
--- @param max_pos integer
function Handler:apply_mark(bufnr, m, max_pos)
  if m.pos > max_pos then
    return
  end

  --- @type vim.api.keyset.set_extmark
  local opts = {
    id = not m.unique and m.pos + 1 or nil,
    priority = self.config.priority,
  }
  local start_col = 0
  if self.config.overlap then
    opts.virt_text = { { m.symbol, m.highlight } }
    opts.virt_text_pos = 'overlay'
    opts.hl_mode = 'combine'
    local bar_winid = vim.fn.win_findbuf(bufnr)[1]

    local cfg = vim.api.nvim_win_get_config(bar_winid)
    if bar_winid and cfg.width == 2 then
      local hunks =
        require('gitsigns.actions').get_nav_hunks(api.nvim_get_current_buf(), 'all', true)
      if #hunks == 0 and vim.fn.getcmdline() == '' and vim.v.hlsearch == 0 then
        cfg.col = cfg.col + 1
        cfg.width = 1
        if bar_winid and api.nvim_win_is_valid(bar_winid) then
          api.nvim_win_set_config(bar_winid, cfg)
        end
      else
        start_col = 1
      end
    end
    if m.highlight:find('Cursor', nil, true) and vim.wo.signcolumn == 'yes' then
      local win_info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
      local topline = 0
      if win_info ~= nil then
        topline = win_info.topline
      end
      local line = topline + m.pos - 1
      local id = line
      if line > vim.api.nvim_buf_line_count(0) then
        line = vim.api.nvim_buf_line_count(0) - 1
      end
      pcall(vim.api.nvim_buf_set_extmark, 0, M.sign_ns, line, 0, {
        sign_text = '',
        priority = 100,
        sign_hl_group = 'SignCursor',
      })
    end
  else
    -- Signs are 2 chars so fill the first char with whitespace
    opts.virt_text = { { m.symbol, m.highlight } }
    opts.virt_text_pos = 'overlay'
    start_col = 0
    local bar_winid = vim.fn.win_findbuf(bufnr)[1]
    local cfg = vim.api.nvim_win_get_config(bar_winid)
    if bar_winid and cfg.width ~= 2 then
      cfg.col = cfg.col - 1
      cfg.width = 2
    end

    if bar_winid and api.nvim_win_is_valid(bar_winid) then
      api.nvim_win_set_config(bar_winid, cfg)
    end
  end

  ok, err = pcall(api.nvim_buf_set_extmark, bufnr, self.ns, m.pos, start_col, opts)
  if not ok then
    print(
      string.format(
        'error(satellite.nvim): handler=%s buf=%d row=%d opts=%s, err="%s"',
        self.name,
        bufnr,
        m.pos,
        vim.inspect(opts, { newline = ' ', indent = '' }),
        err
      )
    )
  end
end

--- @package
--- @param self Satellite.Handler
--- @param winid integer
--- @param bwinid integer
Handler.render = async.void(function(self, winid, bwinid)
  if not self:enabled() then
    return
  end

  local bbufnr = api.nvim_win_get_buf(bwinid)

  if not api.nvim_buf_is_loaded(bbufnr) then
    return
  end

  local bufnr = api.nvim_win_get_buf(winid)
  local max_pos = api.nvim_buf_line_count(bbufnr) - 1

  -- async
  local marks = self.update(bufnr, winid)

  if not api.nvim_buf_is_loaded(bbufnr) or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  api.nvim_buf_clear_namespace(0, M.sign_ns, 0, -1)
  api.nvim_buf_clear_namespace(bbufnr, self.ns, 0, -1)

  for _, m in ipairs(marks) do
    self:apply_mark(bbufnr, m, max_pos)
  end
end)

--- @param spec Satellite.Handler
function M.register(spec)
  vim.validate {
    spec = { spec, 'table' },
    name = { spec.name, 'string' },
    setup = { spec.setup, 'function', true },
    update = { spec.update, 'function' },
  }

  spec.ns = api.nvim_create_namespace('satellite.Handler.' .. spec.name)
  setmetatable(spec, { __index = Handler })

  table.insert(M.handlers, spec)
end

local did_init = false
local handler_count = 0
--- @param bwinid integer
--- @param winid integer
function M.render(bwinid, winid)
  local render_fn = function()
    M.init()

    -- Run handlers
    -- Each render function is a void async function so this loop should finish immediately
    for _, handler in ipairs(M.handlers) do
      if api.nvim_win_is_valid(winid) and api.nvim_win_is_valid(bwinid) then
        handler:render(winid, bwinid)
      end
    end
  end

  local start = vim.uv.hrtime()
  local function follow_node()
    local duration = 0.000001 * (vim.loop.hrtime() - start)
    if duration > 2000 then
      return
    end
    if vim.b.ts_parse_over then
      render_fn()
    else
      vim.defer_fn(follow_node, 5)
    end
  end

  local parser_installed = require('nvim-treesitter.parsers').has_parser(vim.bo.filetype)
  if parser_installed then
    render_fn()
  else
    vim.defer_fn(function()
      render_fn()
    end, 20)
  end
end

function M.init()
  if did_init and handler_count == #M.handlers then
    return
  end

  did_init = true

  -- Load builtin handlers
  for _, name in ipairs(BUILTIN_HANDLERS) do
    if enabled(name) then
      require('satellite.handlers.' .. name)
    end
  end

  local update = require('satellite.view').refresh_bars

  -- Initialize handlers
  for _, h in ipairs(M.handlers) do
    if h:enabled() and h.setup then
      h.setup(user_config.handlers[h.name] or {}, update)
    end
  end
  handler_count = #M.handlers
end

return M
