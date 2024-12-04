return {
    "neovim/nvim-lspconfig",
    dependencies = {
        "saghen/blink.cmp",
        "williamboman/mason.nvim",
        "williamboman/mason-lspconfig.nvim",
    },
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
            diagnostic = {
                refreshSupport = false,
            }
        })

        local lspconfig_defaults = require("lspconfig").util.default_config
        lspconfig_defaults.capabilities = vim.tbl_deep_extend(
            "force",
            lspconfig_defaults.capabilities,
            require("blink.cmp").get_lsp_capabilities()
        )

        vim.api.nvim_create_autocmd("LspAttach", {
            desc = "LSP actions",
            callback = function(event)
                local opts = { buffer = event.buf }

                vim.keymap.set("n", "gk", "<cmd>lua vim.lsp.buf.hover()<cr>", opts)
                vim.keymap.set("n", "<C-Space>", "<cmd>lua vim.lsp.buf.hover()<cr>", opts)
                vim.keymap.set("n", "gd", "<cmd>lua vim.lsp.buf.definition()<cr>", opts)
                vim.keymap.set("n", "gD", "<cmd>lua vim.lsp.buf.declaration()<cr>", opts)
                vim.keymap.set("n", "gi", "<cmd>lua vim.lsp.buf.implementation()<cr>", opts)
                vim.keymap.set("n", "go", "<cmd>lua vim.lsp.buf.type_definition()<cr>", opts)
                vim.keymap.set("n", "gs", "<cmd>lua vim.lsp.buf.signature_help()<cr>", opts)
                vim.keymap.set("n", "<leader>e", "<cmd>lua vim.lsp.buf.rename()<cr>", opts)
                vim.keymap.set("n", "gr", "<cmd>lua vim.lsp.buf.references({includeDeclaration = false})<cr>", opts)
                vim.keymap.set("n", "gl", "<cmd>vim.diagnostic.open_float({ alwaysSource = true })<cr>", opts)
                vim.keymap.set({"n", "x"}, "<leader>f", "<cmd>vim.lsp.buf.format({async = false})<cr>", opts)

                if vim.bo.filetype == "rust" or
                    vim.bo.filetype == "cpp" or
                    vim.bo.filetype == "typescript" or
                    vim.bo.filetype == "typescriptreact" then
                    vim.api.nvim_create_autocmd("BufWritePre", {
                        buffer = event.buf,
                        callback = function()
                            vim.lsp.buf.format { async = false }
                        end
                    })
                end
            end,
        })

        require("mason").setup({})
        require("mason-lspconfig").setup({
            ensure_installed = {
                "lua_ls",
                "rust_analyzer",
            },
            handlers = {
                function(server_name)
                    require("lspconfig")[server_name].setup({})
                end,
                ["rust_analyzer"] = function()

                    -- TODO: remove when neovim 0.11 is released
                    -- filters out error messages from rust-analyzer cancelling requests.
                    for _, method in ipairs({ "textDocument/diagnostic", "workspace/diagnostic" }) do
                        local default_diagnostic_handler = vim.lsp.handlers[method]
                        vim.lsp.handlers[method] = function(err, result, context, config)
                            if err ~= nil and err.code == -32802 then
                                return
                            end
                            return default_diagnostic_handler(err, result, context, config)
                        end
                    end

                    require("lspconfig").rust_analyzer.setup {
                        settings = {
                            ["rust-analyzer"] = {
                                procMacro = {
                                    enable = true,
                                },
                                checkOnSave = {
                                    command = "clippy",
                                },
                                diagnostics = {
                                    enabled = true,
                                    disabled = { "unresolved-proc-macro" },
                                    enableExperimental = true,
                                    warningsAsHint = {},
                                },
                            },
                        },
                    }
                end,
                ["ts_ls"] = function()
                    -- filtering out *.d.ts files from jump-to-definition
                    local function filter(arr, fn)
                        if type(arr) ~= "table" then
                            return arr
                        end
                        local filtered = {}
                        for k, v in pairs(arr) do
                            if fn(v, k, arr) then
                                table.insert(filtered, v)
                            end
                        end
                        return filtered
                    end
                    local function filterReactDTS(value)
                        return string.match(value.targetUri, "%.d.ts") == nil
                    end
                    require("lspconfig").ts_ls.setup {
                        handlers = {
                            ["textDocument/definition"] = function(err, result, method, ...)
                                if vim.islist(result) and #result > 1 then
                                    local filtered_result = filter(result, filterReactDTS)
                                    return vim.lsp.handlers["textDocument/definition"](err, filtered_result, method, ...)
                                end
                                vim.lsp.handlers["textDocument/definition"](err, result, method, ...)
                            end
                        }
                    }
                end,
            }
        })
    end,
}
