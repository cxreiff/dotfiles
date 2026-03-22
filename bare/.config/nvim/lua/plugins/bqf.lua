return {
    "kevinhwang91/nvim-bqf",
    version = "v1.*",
    opts = {
        auto_resize_height = true,
        preview = {
            auto_preview = false,
            show_title = false,
            bud_label = false,
        },
        filter = {
            fzf = {
                extra_opts = { "--bind", "ctrl-o:toggle-all", "--delimiter", "│" }
            }
        },
        func_map = {
            openc = "<CR>",
            open = "o",
        },
    },
}
