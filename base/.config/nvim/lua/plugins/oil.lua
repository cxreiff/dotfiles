return {
    {
        "stevearc/oil.nvim",
        version = "v2.*",
        event = { "VimEnter */*,.*", "BufNew */*,.*" },
        opts = {
            keymaps = {
                ["<C-h>"] = false,
                ["<C-l>"] = false,
                ["<C-k>"] = "actions.refresh",
            },
            view_options = {
                show_hidden = true,
            },
            columns = {
                "icon",
            },
        },
        keys = {
            { "-", "<cmd>Oil<cr>", desc = "open parent directory" },
        },
    }
}
