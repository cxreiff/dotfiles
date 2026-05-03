return {
    "neovim/nvim-lspconfig",
    dependencies = {
        "saghen/blink.cmp",
        "mason-org/mason.nvim",
        "mason-org/mason-lspconfig.nvim",
    },
    event = "VeryLazy",
    config = function()
        vim.diagnostic.config({
            virtual_text = false,
            float = {
                source = "if_many",
                header = {},
                padding = true,
                pad_top = 1,
                pad_bottom = 1,
            },
        })

        vim.lsp.config("*", {
            capabilities = require("blink.cmp").get_lsp_capabilities(),
        })

        vim.lsp.config("rust_analyzer", {
            settings = {
                ["rust-analyzer"] = {
                    procMacro = { enable = true },
                    checkOnSave = true,
                    check = { command = "clippy" },
                    diagnostics = {
                        enable = true,
                        disabled = { "unresolved-proc-macro" },
                    },
                },
            },
        })

        vim.lsp.config("ts_ls", {
            handlers = {
                ["textDocument/definition"] = function(err, result, method, ...)
                    if vim.islist(result) and #result > 1 then
                        result = vim.tbl_filter(function(v)
                            return not v.targetUri:match("%.d%.ts$")
                        end, result)
                    end
                    vim.lsp.handlers["textDocument/definition"](err, result, method, ...)
                end,
            },
        })

        vim.api.nvim_create_autocmd("LspAttach", {
            desc = "LSP actions",
            callback = function(event)
                local opts = { buffer = event.buf }

                vim.keymap.set("n", "gk", vim.lsp.buf.hover, opts)
                vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
                vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
                vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
                vim.keymap.set("n", "go", vim.lsp.buf.type_definition, opts)
                vim.keymap.set("n", "gs", vim.lsp.buf.signature_help, opts)
                vim.keymap.set("n", "<leader>e", vim.lsp.buf.rename, opts)
                vim.keymap.set("n", "gr", function()
                    vim.lsp.buf.references({ includeDeclaration = false })
                end, opts)
                vim.keymap.set("n", "gl", function()
                    vim.diagnostic.open_float({ alwaysSource = true })
                end, opts)
                vim.keymap.set({ "n", "x" }, "<leader>f", function()
                    vim.lsp.buf.format({ async = false })
                end, opts)

                local format_on_save = {
                    rust = true,
                    cpp = true,
                    typescript = true,
                    typescriptreact = true,
                }
                if format_on_save[vim.bo.filetype] then
                    vim.api.nvim_create_autocmd("BufWritePre", {
                        buffer = event.buf,
                        callback = function()
                            vim.lsp.buf.format({ async = false })
                        end,
                    })
                end
            end,
        })

        require("mason").setup()
        require("mason-lspconfig").setup({
            ensure_installed = { "lua_ls", "rust_analyzer" },
        })
    end,
}
