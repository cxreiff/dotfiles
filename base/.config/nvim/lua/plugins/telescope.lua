return {
    "nvim-telescope/telescope.nvim",
    version = "v0.1.*",
    event = "VeryLazy",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "nvim-telescope/telescope-ui-select.nvim",
        "tknightz/telescope-termfinder.nvim",
        { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    opts = {
        defaults = {
            file_ignore_patterns = {
                "%.git",
                "node_modules",
                "build",
                "**/*%.png",
                "**/*%.ico",
                "**/*%.icns",
                "**/*%.plist",
                "**/*%.otf",
                "**/*%.lock",
            },
            mappings = {
                i = {
                    ["<C-n>"] = "cycle_history_next",
                    ["<C-p>"] = "cycle_history_prev",
                    ["<C-j>"] = "move_selection_next",
                    ["<C-k>"] = "move_selection_previous",
                    ["<ESC>"] = "close",
                },
            },
        },
        pickers = {
            find_files = {
                hidden = true,
            },
            buffers = {
                mappings = {
                    i = {
                        ["<C-d>"] = "delete_buffer",
                    },
                },
            },
        },
    },
    keys = {
        { "<leader>p", "<cmd>Telescope find_files hidden=true<cr>" },
        { "<leader>o", "<cmd>Telescope live_grep hidden=true<cr>" },
        { "<leader>?", "<cmd>Telescope help_tags<cr>" },
        { "<leader>b", "<cmd>Telescope buffers<cr>" },
        { "<leader>x", "<cmd>Telescope commands<cr>" },
        { "<leader>c", "<cmd>Telescope colorscheme<cr>" },
        { "<leader>v", "<cmd>Telescope termfinder<cr>" },
        { "<leader>l", "<cmd>Telescope lsp_definitions<cr>" },
        { "<leader>r", "<cmd>Telescope lsp_references<cr>" },
        { "<leader>y", "<cmd>Telescope diagnostics<cr>" },
        { "<leader>u", "<cmd>Telescope lsp_document_symbols<cr>" },
        { "<leader>i", "<cmd>Telescope lsp_dynamic_workspace_symbols<cr>" },
    },
    config = function(_, opts)
        require("telescope").setup(opts)
        require("telescope").load_extension("fzf")
        require("telescope").load_extension("ui-select")
        require("telescope").load_extension("termfinder")
    end,
}
