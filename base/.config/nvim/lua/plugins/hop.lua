return {
    "smoka7/hop.nvim",
    version = "v2.*",
    cmd = "HopWord",
    opts = {},
    keys = {
        {
            "<leader><space>",
            function() require("hop").hint_words() end,
            mode = {"n", "v"},
            desc = "hop hints",
        },
    },
}
