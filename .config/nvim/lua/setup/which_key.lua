return function()
  local wk = require('which-key')
  wk.setup {}
  wk.add({
  { "<leader>;", desc = "command" },
  { "<leader><space>", desc = "hop" },
  { "<leader>a", desc = "code actions" },
  { "<leader>e", desc = "split line" },
  { "<leader>j", desc = "move line down" },
  { "<leader>k", desc = "move line up" },
  { "<leader>l", desc = "copilot" },
  { "<leader>m", desc = "duplicate line" },
  { "<leader>w", desc = "close buffer" },
  })
end

