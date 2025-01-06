return {
    "tpope/vim-surround",
    "tpope/vim-commentary",
    { "j-hui/fidget.nvim", version = "v1.*", event = "VeryLazy", opts = {} },
    { "folke/lazydev.nvim", version = "v1.*", ft = "lua", opts = {} },

    -- languages
    { "rust-lang/rust.vim", ft = "rust" },
    { "kaarmu/typst.vim", ft = "typst" },
    { "DingDean/wgsl.vim", ft = "wgsl" },
    {
        "tikhomirov/vim-glsl",
        ft = {
            "glsl",
            "vert",
            "frag",
            "geom",
            "comp",
            "tesc",
            "tese",
        },
    },

    -- color schemes
    "kvrohit/rasmus.nvim",
    "fenetikm/falcon",
    "sainnhe/everforest",
    "w0ng/vim-hybrid",
    "AlessandroYorba/Alduin",
    "AlessandroYorba/Sierra",
    "frenzyexists/aquarium-vim",
    "bcicen/vim-vice",
    "rafamadriz/neon",
    "sainnhe/sonokai",
    "savq/melange",
    "shaunsingh/nord.nvim",
    "kdheepak/monochrome.nvim",
    "rose-pine/neovim",
    "yazeed1s/oh-lucy.nvim",
    "EdenEast/nightfox.nvim",
    "catppuccin/nvim",
    { "ramojus/mellifluous.nvim", dependencies = { "rktjmp/lush.nvim" } },
}
