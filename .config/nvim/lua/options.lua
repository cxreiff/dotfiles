vim.cmd [[

set termguicolors
set noshowmode
set splitright
set splitbelow
set signcolumn=yes

set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2

autocmd BufWritePre <buffer> lua vim.lsp.buf.formatting_sync()

]]

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

