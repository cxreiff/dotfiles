set number
syntax enable
filetype plugin indent on

let g:rustfmt_autosave = 1

call plug#begin()
Plug 'vim-airline/vim-airline'

Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'rust-lang/rust.vim'
Plug 'sainnhe/everforest'
call plug#end()

set background=dark
colorscheme everforest

packloadall
silent! helptags ALL
