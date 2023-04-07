return function()
  require('bufferline').setup {
    options = {
      diagnostics = 'nvim_lsp',
      always_show_bufferline = false,
      custom_filter = function(buf)
        if vim.bo[buf].filetype == 'qf' then return false end
        return true
      end,
    },
  }
end
