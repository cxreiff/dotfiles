local default_opts = { noremap = true, silent = true }

vim.keymap.set('n', '<leader>j', ':m+<CR>', default_opts)
vim.keymap.set('n', '<leader>k', ':m-2<CR>', default_opts)
vim.keymap.set('n', '<leader>m', ':t.<CR>', default_opts)

-- window navigation
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-h>', [[<Cmd>wincmd h<CR>]], default_opts)
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-j>', [[<Cmd>wincmd j<CR>]], default_opts)
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-k>', [[<Cmd>wincmd k<CR>]], default_opts)
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-l>', [[<Cmd>wincmd l<CR>]], default_opts)
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-t>', ':tabnew<CR>', default_opts)
vim.keymap.set('n', '<leader>t', ':enew<CR>', default_opts)
vim.keymap.set('n', '<leader>r', ':vnew<CR>', default_opts)

-- hopword
vim.keymap.set('n', '<leader><Space>', ':HopWord<CR>', default_opts)

-- lsp
vim.keymap.set('n', '<leader>f', ':LspZeroFormat!<CR>', default_opts)

-- focus mode
vim.keymap.set('n', '<leader>z', ':TZAtaraxis<CR>', default_opts)

-- fuzzy finder
vim.keymap.set('n', '<leader>p', ':Telescope find_files<CR>', default_opts)
vim.keymap.set('n', '<leader>o', ':Telescope live_grep<CR>', default_opts)
vim.keymap.set('n', '<leader>?', ':Telescope help_tags<CR>', default_opts)
vim.keymap.set('n', '<leader>b', ':Telescope buffers<CR>', default_opts)
vim.keymap.set('n', '<leader>x', ':Telescope commands<CR>', default_opts)
vim.keymap.set('n', '<leader>c', ':Telescope colorscheme<CR>', default_opts)
vim.keymap.set('n', '<leader>v', ':Telescope termfinder<CR>', default_opts)
vim.keymap.set('n', '<leader>g', ':Telescope diagnostics<CR>', default_opts)
vim.keymap.set('n', '<leader>d', ':Telescope lsp_definitions<CR>', default_opts)
vim.keymap.set('n', '<leader>s', ':Telescope lsp_references<CR>', default_opts)
vim.keymap.set('n', '<leader>h', ':Telescope lsp_dynamic_workspace_symbols<CR>', default_opts)

-- sessions
vim.keymap.set('n', '<leader>w', ':SessionManager save_current_session<CR>', { noremap = true })
vim.keymap.set('n', '<leader>e', ':SessionManager load_session<CR>', default_opts)
vim.keymap.set('n', '<leader>q', ':SessionManager delete_session<CR>', default_opts)

-- terminal toggle
vim.cmd [[
command! -count=1 TermCommand lua require('toggleterm').exec(vim.fn.input("cmd: "), <count>, 90, nil, "vertical")
command! -count=1 TermFloat <count>ToggleTerm direction="float"<CR>
command! -count=1 TermSplit <count>ToggleTerm direction="vertical" size=90<CR>
command! -nargs=1 -count=1 Sh <count>TermExec direction="vertical" size=90 cmd=<q-args>
cnoreabbrev sh Sh
]]
vim.keymap.set('n', '<leader>n', ':TermCommand<CR>', default_opts)
vim.keymap.set('n', '<leader>y', ':TermFloat<CR>', default_opts)
vim.keymap.set('n', '<leader>u', ':TermSplit<CR>', default_opts)

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

