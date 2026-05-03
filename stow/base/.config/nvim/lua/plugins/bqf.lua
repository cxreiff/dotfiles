return {
    "kevinhwang91/nvim-bqf",
    version = "v1.*",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    init = function()
        -- bqf v1.x calls require('nvim-treesitter.configs') unconditionally.
        -- That module no longer exists on nvim-treesitter `main`. Fake it.
        package.preload["nvim-treesitter.configs"] = function()
            return {
                is_enabled = function(_, _, bufnr)
                    return vim.treesitter.highlighter.active[bufnr or 0] ~= nil
                end,
            }
        end
    end,
    opts = {
        auto_resize_height = true,
        preview = {
            auto_preview = false,
            show_title = false,
        },
        filter = {
            fzf = {
                extra_opts = { "--bind", "ctrl-o:toggle-all", "--delimiter", "│" }
            }
        },
    },
    config = function(_, opts)
        -- bqf also calls parsers.get_parser/ft_to_lang. On `main`, the parsers
        -- module is just a spec table. Add the legacy method shape it expects.
        local parsers = require("nvim-treesitter.parsers")
        if not parsers.get_parser then
            parsers.get_parser = function(bufnr, lang)
                local ok, p = pcall(vim.treesitter.get_parser, bufnr, lang)
                return ok and p or nil
            end
            parsers.ft_to_lang = function(ft)
                return vim.treesitter.language.get_lang(ft)
            end
        end
        require("bqf").setup(opts)
    end,
}
