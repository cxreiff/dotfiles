vim.keymap.set('n', '<leader>j', ':m+<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>k', ':m-2<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>h', '<<', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>l', '>>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>m', ':t.<CR>', { noremap = true, silent = true })

-- lsp
vim.keymap.set('n', '<leader>f', ':LspZeroFormat!<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>a', ':lua vim.lsp.buf.code_action()<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>r', ':RustRunnables<CR>', { noremap = true, silent = true })

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
vim.cmd("command! -count=99 TermSplit lua require('toggleterm').exec(vim.fn.input(\"cmd: \"), <count>, 90, nil, \"vertical\")")
vim.cmd("command! -count=1 TermFloat <count>ToggleTerm<CR>")
vim.keymap.set('n', '<leader>s', ':TermSplit<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<leader>t', ':TermFloat<CR>', { noremap = true, silent = true })

-- terminal keymaps
function _G.set_terminal_keymaps()
  local opts = { buffer = 0 }
  vim.keymap.set('t', '<ESC>', [[<C-\><C-n>:ToggleTerm<CR>]], opts)
  vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]], opts)
  vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], opts)
  vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], opts)
  vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]], opts)
end
vim.cmd('autocmd! TermOpen term://* lua set_terminal_keymaps()')

