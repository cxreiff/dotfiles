
call plug#begin()
Plug 'vim-airline/vim-airline'
Plug 'tpope/vim-sensible'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-vinegar'
Plug 'tpope/vim-commentary'
Plug 'mhinz/vim-signify'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'rust-lang/rust.vim'
Plug 'RRethy/vim-hexokinase', {'do': 'make hexokinase'}
Plug 'junegunn/fzf.vim'
Plug 'junegunn/fzf', {'do': { -> fzf#install() }}
Plug 'junegunn/goyo.vim'
Plug 'junegunn/limelight.vim'
Plug 'vim-airline/vim-airline-themes'
Plug 'sainnhe/everforest'
Plug 'w0ng/vim-hybrid'
Plug 'AlessandroYorba/Alduin'
Plug 'AlessandroYorba/Sierra'
Plug 'franbach/miramare'
call plug#end()

syntax enable
set background=dark
colorscheme miramare
set number
set shm+=I
set belloff=all
set ttimeoutlen=10
set mouse=a

let g:rustfmt_autosave = 1
let g:Hexokinase_highlighters = ['foreground']
let g:limelight_conceal_guifg = 'DarkGray'
let g:goyo_width = 100

let g:coc_start_at_startup = 0
let s:coc_enabled = 0
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
nnoremap <silent> <F2> :call ToggleCoc()<CR>

nnoremap <C-p> :Files<CR>
nnoremap <C-l> :Rg<CR>
nnoremap <C-g> :Goyo<CR>
nnoremap <C-t> :wa \| vertical botright term ++kill=term<CR>

autocmd! User GoyoEnter Limelight
autocmd! User GoyoLeave Limelight!

packloadall
silent! helptags ALL
