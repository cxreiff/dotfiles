return {
    "aznhe21/actions-preview.nvim",
    keys = {
        {
            "<leader>a",
            function() require("actions-preview").code_actions() end,
            mode = { "n", "v" },
            desc = "code actions",
        },
    }
}
