return {
    "akinsho/toggleterm.nvim",
    version = "v2.*",
    keys = {
        { "<leader>j" },
        { "<leader>k" },
    },
    config = function()
        require("toggleterm").setup({ size = 100 })

        vim.api.nvim_create_autocmd("TermOpen", {
            pattern = "term://*",
            callback = function(event)
                local opts = { buffer = event.buf }
                vim.keymap.set("t", "<ESC>", [[<C-\><C-n>:q<CR>]], opts)
                vim.keymap.set("t", "<C-h>", [[<Cmd>wincmd h<CR>]], opts)
                vim.keymap.set("t", "<C-j>", [[<Cmd>wincmd j<CR>]], opts)
                vim.keymap.set("t", "<C-k>", [[<Cmd>wincmd k<CR>]], opts)
                vim.keymap.set("t", "<C-l>", [[<Cmd>wincmd l<CR>]], opts)
            end,
        })

        vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TermOpen", "TermEnter" }, {
            pattern = "term://*",
            command = "startinsert!",
        })

        vim.api.nvim_create_user_command("TermFloat", function(o)
            vim.cmd((o.count or 0) .. 'ToggleTerm direction="float"')
        end, { count = 0 })
        vim.api.nvim_create_user_command("TermSplit", function(o)
            vim.cmd((o.count or 0) .. 'ToggleTerm direction="vertical"')
        end, { count = 0 })

        vim.keymap.set("n", "<leader>j", "<cmd>TermFloat<cr>", { silent = true })
        vim.keymap.set("n", "<leader>k", "<cmd>TermSplit<cr>", { silent = true })
    end,
}
