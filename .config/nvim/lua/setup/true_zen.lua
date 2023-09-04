return function()
  require('true-zen').setup {
    modes = {
      ataraxis = {
        callbacks = {
          open_pos = function()
            vim.cmd [[ set showtabline=0 ]]
            vim.cmd [[ ScrollbarHide ]]
          end,
          close_pos = function()
            vim.cmd [[ set showtabline=1 ]]
            vim.cmd [[ ScrollbarShow ]]
          end,
        },
      },
    },
    integrations = {
      lualine = true
    }
  }
end

