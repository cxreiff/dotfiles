return {
    "folke/which-key.nvim",
    version = "v3.*",
    event = "VeryLazy",
    opts = {},
    keys = {
        {
            "<leader>?",
            function()
                require("which-key").show({ global = false })
            end,
            desc = "show keymaps",
        },
    },
}
