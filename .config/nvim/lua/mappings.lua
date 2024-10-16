local opts = { noremap = true, silent = true }

vim.keymap.set({'v'}, 'p', 'P', opts);
vim.keymap.set({'v'}, 'P', 'p', opts);

vim.keymap.set('n', '<A-j>', ':MoveLine(1)<CR>', opts)
vim.keymap.set('n', '<A-k>', ':MoveLine(-1)<CR>', opts)
vim.keymap.set('n', '<A-h>', ':MoveHChar(-1)<CR>', opts)
vim.keymap.set('n', '<A-l>', ':MoveHChar(1)<CR>', opts)
vim.keymap.set('v', '<A-j>', ':MoveBlock(1)<CR>', opts)
vim.keymap.set('v', '<A-k>', ':MoveBlock(-1)<CR>', opts)
vim.keymap.set('v', '<A-h>', ':MoveHBlock(-1)<CR>', opts)
vim.keymap.set('v', '<A-l>', ':MoveHBlock(1)<CR>', opts)
vim.keymap.set('n', '<leader>l', ':MoveWord(1)<CR>', opts)
vim.keymap.set('n', '<leader>h', ':MoveWord(-1)<CR>', opts)

vim.keymap.set({ 'n', 'v' }, '<leader>m', ':t.<CR>', opts)
vim.keymap.set({ 'n', 'v' }, '<leader>;', ':', opts)
vim.keymap.set('t', '<S-space', '<space><CR>', opts)
vim.keymap.set({ 'n', 'v', 't' }, '<s-space>', '<space>', opts)
vim.keymap.set('n', '-', ':Oil<CR>', opts)

-- window navigation
vim.keymap.set({ 'n', 'i', 't', 'v' }, '<C-t>', ':tabnew<CR>', opts)
vim.keymap.set('n', '<leader>t', ':enew<CR>', opts)
vim.keymap.set('n', '<leader>s', ':vnew<CR>', opts)
vim.keymap.set('n', '<leader>w', ':Bdelete<CR>', opts)
vim.keymap.set('n', '<leader>q', ':close<CR>', opts)

-- hopword
vim.keymap.set({ 'n', 'v' }, '<leader><Space>', require('hop').hint_words, opts)

-- trevj formatting
vim.keymap.set('n', '<leader>e', require('trevj').format_at_cursor, opts)

-- lsp
vim.keymap.set('n', '<leader>f', ':LspZeroFormat!<CR>', opts)

-- focus mode
vim.keymap.set('n', '<leader>z', ':TZAtaraxis<CR>', opts)

-- fuzzy finder
vim.keymap.set('n', '<leader>p', ':Telescope find_files hidden=true<CR>', opts)
vim.keymap.set('n', '<leader>o', ':Telescope live_grep hidden=true<CR>', opts)
vim.keymap.set('n', '<leader>?', ':Telescope help_tags<CR>', opts)
vim.keymap.set('n', '<leader>b', ':Telescope buffers<CR>', opts)
vim.keymap.set('n', '<leader>x', ':Telescope commands<CR>', opts)
vim.keymap.set('n', '<leader>c', ':Telescope colorscheme<CR>', opts)
vim.keymap.set('n', '<leader>v', ':Telescope termfinder<CR>', opts)
vim.keymap.set('n', '<leader>d', ':Telescope lsp_definitions<CR>', opts)
vim.keymap.set('n', '<leader>r', ':Telescope lsp_references<CR>', opts)
vim.keymap.set('n', '<leader>y', ':Telescope diagnostics<CR>', opts)
vim.keymap.set('n', '<leader>u', ':Telescope lsp_document_symbols<CR>', opts)
vim.keymap.set('n', '<leader>i', ':Telescope lsp_dynamic_workspace_symbols<CR>', opts)

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
vim.keymap.set('n', '<leader>n', ':TermCommand<CR>', opts)
vim.keymap.set('n', '<leader>j', ':TermFloat<CR>', opts)
vim.keymap.set('n', '<leader>k', ':TermSplit<CR>', opts)

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

-- create splits when navigating beyond last split
function _G.split_nav(key)
  local current = vim.fn.winnr()
  vim.cmd("wincmd " .. key)
  if current == vim.fn.winnr() then
    if key == 'j' then
      vim.cmd("new")
    elseif key == 'k' then
      vim.cmd("set nosplitbelow")
      vim.cmd("new")
      vim.cmd("set splitbelow")
    elseif key == 'h' then
      vim.cmd("set nosplitright")
      vim.cmd("vnew")
      vim.cmd("set splitright")
    elseif key == 'l' then
      vim.cmd("vnew")
    end
    vim.cmd("wincmd " .. key)
  end
end
vim.keymap.set({'n', 'i', 'v', 't'}, '<C-h>', function() _G.split_nav('h') end, opts)
vim.keymap.set({'n', 'i', 'v', 't'}, '<C-k>', function() _G.split_nav('k') end, opts)
vim.keymap.set({'n', 'i', 'v', 't'}, '<C-l>', function() _G.split_nav('l') end, opts)
vim.keymap.set({'n', 'i', 'v', 't'}, '<C-j>', function() _G.split_nav('j') end, opts)

if vim.g.neovide then
  -- Allow clipboard copy paste in neovide
  vim.g.neovide_input_use_logo = 1
  vim.keymap.set('', '<D-v>', '<C-R><C-P>*', opts)
  vim.keymap.set('!', '<D-v>', '<C-R><C-P>*', opts)
  vim.keymap.set('t', '<D-v>', '<C-R><C-P>*', opts)
  vim.keymap.set('v', '<D-v>', '<C-R><C-P>*', opts)
end
