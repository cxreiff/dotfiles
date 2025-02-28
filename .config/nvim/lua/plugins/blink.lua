return {
    "saghen/blink.cmp",
    version = "v0.*",
    lazy = false,
    dependencies = {
        "rafamadriz/friendly-snippets",
    },
    opts = {
        keymap = {
            ["<Tab>"] = {
                "select_next",
                function(cmp)
                    if require("utils").has_words_before() then
                        return cmp.show()
                    end
                end,
                "fallback",
            },
            ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
            ["<C-Tab>"] = { "snippet_forward", "show", "fallback" },
            ["<C-`>"] = { "show" },

            ["<PageUp>"] = { "scroll_documentation_up", "fallback" },
            ["<PageDown>"] = { "scroll_documentation_down", "fallback" },

            ["<CR>"] = { "accept", "fallback" },

            ["<Esc>"] = { "cancel", "fallback" },

            cmdline = {
                ["<Esc>"] = {
                    function(cmp)
                        if cmp.is_visible() then
                            cmp.cancel()
                        else
                            vim.api.nvim_feedkeys(
                                vim.api.nvim_replace_termcodes("<C-c>", true, true, true),
                                "n",
                                true
                            )
                        end
                    end,
                },
            },
        },

        appearance = {
            use_nvim_cmp_as_default = true,
        },

        completion = {
            accept = {
                auto_brackets = { enabled = true },
            },
            menu = {
                draw = {
                    treesitter = { "lsp" },
                },
            },
            trigger = {
                show_on_keyword = false,
                show_on_trigger_character = false,
            },
            documentation = {
                auto_show = true,
                auto_show_delay_ms = 40,
                update_delay_ms = 40,
            },
            ghost_text = {
                enabled = false,
            },
            list = {
                selection = {
                    preselect = true,
                    auto_insert = false,
                },
            },
        },

        signature = {
            enabled = false
        },

        sources = {
            default = {
                "lsp",
                "path",
                "snippets",
                "buffer",
            },
        },
    },
}
