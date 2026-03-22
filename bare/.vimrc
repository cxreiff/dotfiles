
set background=dark
let mapleader = ' '

call plug#begin()
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'tpope/vim-sensible'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-vinegar'
Plug 'tpope/vim-commentary'
Plug 'rust-lang/rust.vim'
Plug 'sainnhe/everforest'
Plug 'franbach/miramare'
call plug#end()

colorscheme miramare

set number
set shm+=I
set belloff=all
set ttimeoutlen=10


packloadall
silent! helptags ALL
