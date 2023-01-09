return function()
  vim.keymap.set(
    {'n', 'v'},
    '<leader>a',
    require('actions-preview').code_actions,
    { noremap = true, silent = true }
  )
end

