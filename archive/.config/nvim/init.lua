local settings = require("settings")

vim.g.mapleader = settings.leader
vim.g.maplocalleader = settings.localleader

require("options")
require("mappings")
require("config.lazy")

vim.cmd.colorscheme(settings.colorscheme)
