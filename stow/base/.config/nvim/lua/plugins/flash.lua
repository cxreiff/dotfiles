return {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
        {
            "<leader><space>",
            mode = { "n", "x", "o" },
            function() require("flash").jump() end,
            desc = "flash jump",
        },
    },
}
