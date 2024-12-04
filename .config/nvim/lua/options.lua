vim.opt.showmode = false
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.ruler = false
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.smartindent = true
vim.opt.scrolloff = 4
vim.opt.shm:append("I")
vim.opt.clipboard:append("unnamedplus")
vim.g.splitjoin_html_attributes_bracket_on_new_line = 1

vim.g.markdown_fenced_languages = {
  "rust",
  "typescript",
  "typescriptreact",
  "tsx=typescriptreact",
  "scss",
}

-- hide color schemes from tab completion
vim.opt.wildignore:append("\z
  blue.vim,\z
  darkblue.vim,\z
  delek.vim,\z
  desert.vim,\z
  elflord.vim,\z
  evening.vim,\z
  industry.vim,\z
  koehler.vim,\z
  murphy.vim,\z
  pablo.vim,\z
  peachpuff.vim,\z
  ron.vim,\z
  sorbet.vim,\z
  torte.vim,\z
  vim.vim,\z
  wildcharm.vim,\z
  zaibatsu.vim,\z
")

-- format on save
vim.api.nvim_create_autocmd("BufWritePre", {
  callback = vim.lsp.buf.format,
})

-- auto reload buffer
vim.api.nvim_create_autocmd({"FocusGained", "BufEnter"}, {
  pattern = "*",
  command = "checktime",
})

-- support for wgsl
vim.filetype.add({
    extension = {
        wgsl = "wgsl",
    },
})

-- support for sway config
vim.filetype.add({
  extension = {
    swayconfig = "swayconfig"
  },
})
