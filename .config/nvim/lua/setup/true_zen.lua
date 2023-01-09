return function()
  require('true-zen').setup {
    modes = {
      ataraxis = {
        callbacks = {
          open_pos = function()
            vim.cmd [[ set showtabline=0 ]]
          end,
          close_post = function()
            vim.cmd [[ set showtabline=1 ]]
          end,
        },
      },
    },
    integrations = {
      lualine = true
    }
  }
end

