vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.scrolloff = 4
vim.opt.shm:append("I")
vim.opt.clipboard:append("unnamedplus")

-- Use OSC 52 for clipboard when running over SSH so yanks reach the local
-- system clipboard via the terminal emulator instead of the remote host.
if vim.env.SSH_TTY then
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
      ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
    },
    paste = {
      ["+"] = require("vim.ui.clipboard.osc52").paste("+"),
      ["*"] = require("vim.ui.clipboard.osc52").paste("*"),
    },
  }
end

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

-- auto reload buffer
vim.api.nvim_create_autocmd({"FocusGained", "BufEnter"}, {
  pattern = "*",
  command = "checktime",
})

-- support for sway config
vim.filetype.add({
  extension = {
    swayconfig = "swayconfig"
  },
})
