vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.scrolloff = 4
vim.opt.shm:append("I")
vim.opt.clipboard:append("unnamedplus")

-- Use OSC 52 for clipboard when running over SSH so yanks reach the local
-- system clipboard via the terminal emulator instead of the remote host.
-- Tailscale SSH sets SSH_CONNECTION but not SSH_TTY, so check both.
-- Paste does not use OSC 52: zellij does not answer OSC 52 queries and
-- Alacritty only permits copy, so nvim would hang waiting for a reply.
-- Instead, paste returns whatever was last copied from within nvim.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
  local osc52 = require("vim.ui.clipboard.osc52")
  local last = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }
  local function copy(reg)
    local send = osc52.copy(reg)
    return function(lines, regtype)
      last[reg] = { lines, regtype }
      send(lines, regtype)
    end
  end
  local function paste(reg)
    return function()
      return last[reg]
    end
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
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
