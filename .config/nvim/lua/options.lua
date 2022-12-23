
vim.cmd [[set noshowmode]]
vim.cmd [[set splitright]]
vim.cmd [[set splitbelow]]
vim.cmd [[set signcolumn=yes]]
vim.cmd [[set number]]
vim.cmd [[set shm+=I]]

vim.cmd [[set expandtab]]
vim.cmd [[set tabstop=2]]
vim.cmd [[set softtabstop=2]]
vim.cmd [[set shiftwidth=2]]

-- hide default fonts from tab completion
vim.cmd [[
set wildignore+=blue.vim,darkblue.vim,default.vim,delek.vim,desert.vim,
\elflord.vim,evening.vim,industry.vim,koehler.vim,morning.vim,murphy.vim,
\pablo.vim,peachpuff.vim,ron.vim,shine.vim,slate.vim,torte.vim,zellner.vim
]]

vim.cmd [[autocmd BufWritePre <buffer> lua vim.lsp.buf.formatting_sync()]]

-- diagnostic icons
local sign = function(opts)
  vim.fn.sign_define(opts.name, {
    texthl = opts.name,
    text = opts.text,
    numhl = ''
  })
end
sign({name = 'DiagnosticSignError', text = '!'})
sign({name = 'DiagnosticSignWarn', text = '?'})
sign({name = 'DiagnosticSignHint', text = ''})
sign({name = 'DiagnosticSignInfo', text = 'i'})

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

