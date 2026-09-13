return {
    "pocco81/true-zen.nvim",
    opts = {
        modes = {
            ataraxis = {
                callbacks = {
                    open_pos = function()
                        vim.cmd [[ set showtabline=0 ]]
                        vim.cmd [[ ScrollbarHide ]]
                    end,
                    close_pos = function()
                        vim.cmd [[ set showtabline=1 ]]
                        vim.cmd [[ ScrollbarShow ]]
                    end,
                },
            },
        },
        integrations = {
            lualine = true,
            tmux = true,
        },
    },
    keys = {
        { "<leader>z", "<cmd>TZAtaraxis<cr>", desc = "zen mode" },
    },
}
