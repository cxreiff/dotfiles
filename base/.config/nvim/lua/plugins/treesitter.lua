return {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",
    opts = {
        auto_install = true,
        ensure_installed = { "rust", "toml", "wgsl" },
        highlight = {
            enable = true,
        },
        incremental_selection = { enable = true },
        indent = { enable = true },
        autotag = { enable = true },
        rainbow = {
            enable = true,
            extended_mode = true,
            max_file_lines = nil,
        },
        context_commentstring = {
            enable = true,
            enable_autocmd = false,
        },
    },
}
