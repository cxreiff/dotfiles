return {
  build = function()
    local ts_update = require('nvim-treesitter.install').update({ with_sync = true })
    ts_update()
  end,
  config = function()
    require('nvim-treesitter.configs').setup {
      ensure_installed = { 'rust', 'toml' },
      auto_install = true,
      highlight = {
        disable = { 'lua' },
        additional_vim_regex_highlighting = false,
      },
      indent = {
        enable = true,
      },
      rainbow = {
        enable = true,
        extended_mode = true,
        max_file_lines = nil,
      }
    }
  end,
}

