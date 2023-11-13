
vim.opt.showmode = false
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.signcolumn = 'yes'
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.ruler = false
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.smartindent = true
vim.opt.scrolloff = 4
vim.opt.shm:append('I')
vim.opt.clipboard:append('unnamedplus')

vim.g.markdown_fenced_languages = {
  'rust',
  'typescript',
  'typescriptreact',
  'tsx=typescriptreact',
  'scss',
}

-- close netrw on selection
vim.g.netrw_browse_split = 0
vim.g.netrw_winsize = 30
vim.g.netrw_fastbrowse = 0

-- hide default fonts from tab completion
vim.opt.wildignore:append("\z
  blue.vim,darkblue.vim,default.vim,delek.vim,desert.vim,elflord.vim,\z
  evening.vim,industry.vim,koehler.vim,morning.vim,murphy.vim,pablo.vim,\z
  peachpuff.vim,ron.vim,shine.vim,slate.vim,torte.vim,zellner.vim\z
")

-- terminals always open in insert mode
vim.api.nvim_create_autocmd('BufEnter', {
  pattern = '*',
  command = 'if &buftype ==# "terminal" | startinsert! | endif',
})

-- format on save
vim.api.nvim_create_autocmd('BufWritePre', {
  callback = vim.lsp.buf.format,
})

-- auto reload buffer
vim.api.nvim_create_autocmd({'FocusGained', 'BufEnter'}, {
  pattern = '*',
  command = 'checktime',
})

vim.g.neovide_input_macos_alt_is_meta = true
vim.g.splitjoin_html_attributes_bracket_on_new_line = 1

