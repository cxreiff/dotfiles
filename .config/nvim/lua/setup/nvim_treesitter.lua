return function(use)
  use {
    'nvim-treesitter/nvim-treesitter',
    run = function()
        local ts_update = require('nvim-treesitter.install').update({ with_sync = true })
        ts_update()
    end,
    config = function()
      require('nvim-treesitter.configs').setup {
        ensure_installed = { "rust", "toml" },
        auto_install = true,
        highlight = {
          disable = { "lua" },
        },
        rainbow = {
          enable = true,
          extended_mode = true,
          max_file_lines = nil,
        }
      }
    end,
  }
end