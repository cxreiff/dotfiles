return {
    "folke/zen-mode.nvim",
    cmd = "ZenMode",
    keys = {
        { "<leader>z", "<cmd>ZenMode<cr>", desc = "zen mode" },
    },
    opts = {
        plugins = {
            tmux = { enabled = true },
        },
        on_open = function()
            vim.cmd("set showtabline=0")
            vim.cmd("ScrollbarHide")
        end,
        on_close = function()
            vim.cmd("set showtabline=1")
            vim.cmd("ScrollbarShow")
        end,
    },
}
