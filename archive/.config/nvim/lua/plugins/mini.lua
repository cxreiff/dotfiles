return {
    "echasnovski/mini.nvim",
    version = "*",
    config = function()
        require("mini.basics").setup()
        require("mini.bufremove").setup()
        require("mini.icons").setup()
        -- require("mini.pairs").setup()
        require('mini.move').setup()

        require("mini.diff").setup {
            view = {
                style = "sign",
                signs = { add = "┃", change = "┃", delete = "┃" },
            },
            delay = {
                text_change = 20,
            },
        }

        vim.keymap.set("n", "<leader>w", require("mini.bufremove").delete)
    end,
}
