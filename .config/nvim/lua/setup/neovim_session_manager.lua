return function(use)
  use {
    'Shatur/neovim-session-manager',
    config = function()
      require('session_manager').setup {
        autoload_mode = require('session_manager.config').AutoloadMode.Disabled,
        autosave_only_in_session = true,
      }
    end,
  }
end
