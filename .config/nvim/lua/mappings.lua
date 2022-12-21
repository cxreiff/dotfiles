
vim.keymap.set('n', '<leader>j', ':m+<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>k', ':m-2<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>h', '<<', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>l', '>>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>m', ':t.<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>sv', ':source $MYVIMRC<CR>', { noremap = true })

-- lsp
vim.keymap.set('n', '<leader>f', ':LspZeroFormat!<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>a', ':lua vim.lsp.buf.code_action()<CR>', { noremap = true, silent = true })

-- focus mode
vim.keymap.set('n', '<leader>g', ':TZAtaraxis<CR>', { noremap = true, silent = true })

-- fuzzy finder
vim.keymap.set('n', '<leader>p', ':Telescope find_files<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>o', ':Telescope live_grep<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>h', ':Telescope help_tags<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>b', ':Telescope buffers<CR>', { noremap = true, silent = true })

-- trouble drawer
vim.keymap.set('n', '<leader>i', ':TroubleToggle<CR>', { noremap = true, silent = true })

-- terminal toggle
vim.api.nvim_create_user_command('FTermToggle', require('FTerm').toggle, { bang = true })
vim.keymap.set('n', '<leader>t', ':FTermToggle<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<C-t>', ':FTermToggle<CR>', { noremap = true, silent = true })
vim.keymap.set('t', '<C-t>', '<C-n><cmd>:FTermToggle<CR>', { noremap = true, silent = true })
vim.keymap.set('t', '<ESC>', '<C-n><cmd>:FTermToggle<CR>', { noremap = true, silent = true })

