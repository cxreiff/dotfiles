
vim.opt.showmode = false
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.signcolumn = 'yes'
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.shm:append('I')
vim.opt.clipboard:append('unnamedplus')

vim.g.markdown_fenced_languages = {
  'rust',
  'typescript',
  'typescriptreact',
  'tsx=typescriptreact',
  'scss',
}

-- hide default fonts from tab completion
vim.opt.wildignore:append("\z
  blue.vim,darkblue.vim,default.vim,delek.vim,desert.vim,elflord.vim,\z
  evening.vim,industry.vim,koehler.vim,morning.vim,murphy.vim,pablo.vim,\z
  peachpuff.vim,ron.vim,shine.vim,slate.vim,torte.vim,zellner.vim\z
")

-- format on save
vim.api.nvim_create_autocmd('BufWritePre', {
  callback = vim.lsp.buf.format,
})

-- close netrw on selection
vim.g.netrw_fastbrowse = 0
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'netrw',
  command = [[ setl bufhidden=wipe ]],
})

-- auto reload buffer
vim.api.nvim_create_autocmd({'FocusGained', 'BufEnter'}, {
  pattern = '*',
  command = 'checktime',
})

-- diagnostic icons
local sign = function(opts)
  vim.fn.sign_define(opts.name, {
    texthl = opts.name,
    text = opts.text,
    numhl = ''
  })
end
sign({ name = 'DiagnosticSignError', text = '!' })
sign({ name = 'DiagnosticSignWarn', text = '?' })
sign({ name = 'DiagnosticSignHint', text = '' })
sign({ name = 'DiagnosticSignInfo', text = 'i' })

-- diagnostic config
vim.diagnostic.config({
  virtual_text = false,
  signs = true,
  update_in_insert = true,
  underline = true,
  severity_sort = false,
  float = {
    border = 'rounded',
    source = 'always',
    header = '',
    prefix = '',
  },
})

