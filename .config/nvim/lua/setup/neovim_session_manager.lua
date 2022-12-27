return function(use)
  use {
    'Shatur/neovim-session-manager',
    requires = {
      { 'nvim-lua/plenary.nvim' },
    },
    config = function()
      require('session_manager').setup {
        autoload_mode = require('session_manager.config').AutoloadMode.Disabled,
        autosave_only_in_session = true,
        autosave_ignore_buftypes = {
          'terminal',
        }
      }
    end,
  }
end
