return {
    "akinsho/toggleterm.nvim",
    version = "v2.12.*",
    opts = {
        size = 100,
    },
    keys = {
        { "<leader>j" },
        { "<leader>k" },
    },
    config = function()
        require("toggleterm").setup { size = 100 }

        -- set mappings for inside terminal
        function _G.set_terminal_keymaps()
            local opts = {buffer = 0}
            vim.keymap.set("t", "<ESC>", [[<C-\><C-n>:q<CR>]], opts)
            vim.keymap.set("t", "<C-h>", [[<Cmd>wincmd h<CR>]], opts)
            vim.keymap.set("t", "<C-j>", [[<Cmd>wincmd j<CR>]], opts)
            vim.keymap.set("t", "<C-k>", [[<Cmd>wincmd k<CR>]], opts)
            vim.keymap.set("t", "<C-l>", [[<Cmd>wincmd l<CR>]], opts)
        end
        vim.cmd("autocmd! TermOpen term://* lua set_terminal_keymaps()")

        -- terminals always open in insert mode
        vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TermOpen", "TermEnter" }, {
            pattern = "term://*",
            command = "startinsert!",
        })

        -- mappings (not in lazy.nvim keys list because of count functionality)
        local opts = { noremap = true, silent = true }
        vim.cmd [[
            command! -count=0 TermFloat <count>ToggleTerm direction="float"<CR>
            command! -count=0 TermSplit <count>ToggleTerm direction="vertical"<CR>
        ]]
        vim.keymap.set("n", "<leader>j", ":TermFloat<CR>", opts)
        vim.keymap.set("n", "<leader>k", ":TermSplit<CR>", opts)
    end,
}
