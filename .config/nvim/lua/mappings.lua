local default_opts = { noremap = true, silent = true }

vim.keymap.set('n', '<A-j>', ':MoveLine(1)<CR>', default_opts)
vim.keymap.set('n', '<A-k>', ':MoveLine(-1)<CR>', default_opts)
vim.keymap.set('v', '<A-j>', ':MoveBlock(1)<CR>', default_opts)
vim.keymap.set('v', '<A-k>', ':MoveBlock(-1)<CR>', default_opts)
vim.keymap.set('n', '<leader>j', ':MoveLine(1)<CR>', default_opts)
vim.keymap.set('n', '<leader>k', ':MoveLine(-1)<CR>', default_opts)
vim.keymap.set('v', '<leader>j', ':MoveBlock(1)<CR>', default_opts)
vim.keymap.set('v', '<leader>k', ':MoveBlock(-1)<CR>', default_opts)
vim.keymap.set({ 'n', 'v' }, '<leader>m', ':t.<CR>', default_opts)
vim.keymap.set({ 'n', 'v' }, '<leader>;', ':', default_opts)
vim.keymap.set('t', '<S-space', '<space><CR>', default_opts)

-- window navigation
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-t>', ':tabnew<CR>', default_opts)
vim.keymap.set('n', '<leader>t', ':enew<CR>', default_opts)
vim.keymap.set('n', '<leader>s', ':vnew<CR>', default_opts)
vim.keymap.set('n', '<leader>w', ':Bdelete<CR>', default_opts)

-- hopword
vim.keymap.set({ 'n', 'v' }, '<leader><Space>', require('hop').hint_words, default_opts)

-- lsp
vim.keymap.set('n', '<leader>f', ':LspZeroFormat!<CR>', default_opts)

-- focus mode
vim.keymap.set('n', '<leader>z', ':TZAtaraxis<CR>', default_opts)

-- fuzzy finder
vim.keymap.set('n', '<leader>p', ':Telescope find_files hidden=true<CR>', default_opts)
vim.keymap.set('n', '<leader>o', ':Telescope live_grep hidden=true<CR>', default_opts)
vim.keymap.set('n', '<leader>?', ':Telescope help_tags<CR>', default_opts)
vim.keymap.set('n', '<leader>b', ':Telescope buffers<CR>', default_opts)
vim.keymap.set('n', '<leader>x', ':Telescope commands<CR>', default_opts)
vim.keymap.set('n', '<leader>c', ':Telescope colorscheme<CR>', default_opts)
vim.keymap.set('n', '<leader>v', ':Telescope termfinder<CR>', default_opts)
vim.keymap.set('n', '<leader>d', ':Telescope lsp_definitions<CR>', default_opts)
vim.keymap.set('n', '<leader>r', ':Telescope lsp_references<CR>', default_opts)
vim.keymap.set('n', '<leader>y', ':Telescope diagnostics<CR>', default_opts)
vim.keymap.set('n', '<leader>u', ':Telescope lsp_document_symbols<CR>', default_opts)
vim.keymap.set('n', '<leader>i', ':Telescope lsp_dynamic_workspace_symbols<CR>', default_opts)

-- terminal toggle
function _G.term_exec_from_input(count)
  local input = vim.fn.input("cmd: ")
  if input == "" then
    return
  else
    require('toggleterm').exec(input, count, 100, nil, "vertical")
  end
end

vim.cmd [[
command! -count=1 TermCommand lua term_exec_from_input(<count>)
command! -count=1 TermFloat <count>ToggleTerm direction="float"<CR>
command! -count=1 TermSplit <count>ToggleTerm direction="vertical" size=100<CR>
command! -nargs=1 -count=1 Sh <count>TermExec direction="vertical" size=100 cmd=<q-args>
cnoreabbrev sh Sh
]]
vim.keymap.set('n', '<leader>n', ':TermCommand<CR>', default_opts)
vim.keymap.set('n', '<leader>g', ':TermFloat<CR>', default_opts)
vim.keymap.set('n', '<leader>h', ':TermSplit<CR>', default_opts)

-- terminal keymaps
function _G.set_terminal_keymaps()
  local term_opts = { buffer = 0 }
  vim.keymap.set('t', '<ESC>', [[<C-\><C-n>:q<CR>]], term_opts)
  vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]], term_opts)
  vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], term_opts)
  vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], term_opts)
  vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]], term_opts)
end

vim.cmd('autocmd! TermOpen term://* lua set_terminal_keymaps()')

if vim.g.neovide then
  -- Allow clipboard copy paste in neovide
  vim.g.neovide_input_use_logo = 1
  vim.keymap.set('', '<D-v>', '<C-R><C-P>*', default_opts)
  vim.keymap.set('!', '<D-v>', '<C-R><C-P>*', default_opts)
  vim.keymap.set('t', '<D-v>', '<C-R><C-P>*', default_opts)
  vim.keymap.set('v', '<D-v>', '<C-R><C-P>*', default_opts)
end
