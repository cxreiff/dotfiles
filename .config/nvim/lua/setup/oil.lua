return function()
  require('oil').setup {
    win_options = {
      concealcursor = "nciv",
    },
    keymaps = {
      ['<C-h>'] = false,
      ['<C-k>'] = 'actions.refresh',
      ['<C-l>'] = false,
    },
    view_options = {
      show_hidden = true,
    },
  }
end
