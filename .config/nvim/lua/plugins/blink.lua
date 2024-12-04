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
                "snippet_forward",
                function(cmp)
                    if require("utils").has_words_before() then
                        return cmp.show()
                    end
                end,
                "fallback",
            },
            ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
            ["<C-Tab>"] = { "show", "fallback" },

            ["<CR>"] = { "accept", "fallback" },
            ["<Esc>"] = {
                "cancel",
                "fallback",
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
                    treesitter = true,
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
        },

        signature = {
            enabled = true
        },
    },
}
