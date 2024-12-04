local opts = { noremap = true, silent = true }

-- do not copy on paste for lowercase p
vim.keymap.set("v", "p", "P", opts);
vim.keymap.set("v", "P", "p", opts);

-- shortcut for semicolon
vim.keymap.set({ "n", "v" }, "<leader>;", ":", opts)

-- duplicate line
vim.keymap.set({ "n", "v" }, "<leader>m", ":t.<cr>", opts)

-- window navigation
vim.keymap.set({ "n", "i", "t", "v" }, "<C-t>", ":tabnew<cr>", opts)
vim.keymap.set("n", "<leader>t", ":enew<cr>", opts)
vim.keymap.set("n", "<leader>s", ":vnew<cr>", opts)
vim.keymap.set("n", "<leader>q", ":close<cr>", opts)

-- create splits when navigating beyond last split
function _G.split_nav(key)
  local current = vim.fn.winnr()
  vim.cmd("wincmd " .. key)
  if current == vim.fn.winnr() then
    if key == "j" then
      vim.cmd("new")
    elseif key == "k" then
      vim.cmd("set nosplitbelow")
      vim.cmd("new")
      vim.cmd("set splitbelow")
    elseif key == "h" then
      vim.cmd("set nosplitright")
      vim.cmd("vnew")
      vim.cmd("set splitright")
    elseif key == "l" then
      vim.cmd("vnew")
    end
    vim.cmd("wincmd " .. key)
  end
end
vim.keymap.set({"n", "i", "v", "t"}, "<C-h>", function() _G.split_nav("h") end, opts)
vim.keymap.set({"n", "i", "v", "t"}, "<C-k>", function() _G.split_nav("k") end, opts)
vim.keymap.set({"n", "i", "v", "t"}, "<C-l>", function() _G.split_nav("l") end, opts)
vim.keymap.set({"n", "i", "v", "t"}, "<C-j>", function() _G.split_nav("j") end, opts)

