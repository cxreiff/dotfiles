set number
syntax enable
filetype plugin indent on
set shm+=I
set visualbell 
set t_vb=
set ttimeoutlen=10
set mouse=a

call plug#begin()
Plug 'vim-airline/vim-airline'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-fugitive'
Plug 'mhinz/vim-signify'
Plug 'jiangmiao/auto-pairs'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'rust-lang/rust.vim'
Plug 'RRethy/vim-hexokinase', {'do': 'make hexokinase'}
Plug 'junegunn/fzf.vim'
Plug 'junegunn/fzf', {'do': { -> fzf#install() }}
Plug 'junegunn/goyo.vim'
Plug 'junegunn/limelight.vim'
Plug 'sainnhe/everforest'
call plug#end()

set background=dark
colorscheme everforest

let g:rustfmt_autosave = 1
let g:Hexokinase_highlighters = ['foreground']
let g:limelight_conceal_guifg = 'DarkGray'
let g:goyo_width = 100

let g:coc_start_at_startup = 0
let s:coc_enabled = 0
let s:coc_started = 0

autocmd! User GoyoEnter Limelight
autocmd! User GoyoLeave Limelight!

function! ToggleCoc()
	if s:coc_started == 0
		CocStart
		let s:coc_started = 1
	endif
	if s:coc_enabled == 0
		CocEnable
		let s:coc_enabled = 1
		echo 'CoC Enabled'
	else
		CocDisable
		let s:coc_enabled = 0
		echo 'CoC Disabled'
	endif
endfunction
nnoremap <silent> <F5> :call ToggleCoc()<CR>

nnoremap <C-p> :Files<CR>
nnoremap <C-l> :Rg<CR>
nnoremap <C-g> :Goyo<CR>

packloadall
silent! helptags ALL
