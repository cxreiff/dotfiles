
echo "\n=== running init script ==="

# utilities

git_latest_version() {
   basename $(curl -fs -o/dev/null -w %{redirect_url} https://github.com/$1/releases/latest)
}

# installation

echo "\n=== creating developer folder ===\n"

touch ~/Developer

echo "\n=== installing homebrew ===\n"

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew tap Homebrew/bundle

echo "\n=== installing brews ===\n"

brew bundle --file ~/.config/Brewfile

echo "\n=== configuring iterm ===\n"

defaults write com.googlecode.iterm2.plist PrefsCustomFolder -string "~/.config/iterm2"
defaults write com.googlecode.iterm2.plist LoadPrefsFromCustomFolder -bool true

echo "\n=== installing rust ===\n"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

echo "\n=== installing pnpm ===\n"

curl -fsSL https://get.pnpm.io/install.sh | sh -

echo "\n=== installing node ===\n"

pnpm env use --global lts

echo "\n=== installing vim-plug ===\n"

curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

echo "\n=== installing tmux plugin manager ===\n"

git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

echo "\n=== installing irssi plugins ===\n"

curl https://scripts.irssi.org/scripts/adv_windowlist.pl --create-dirs -o ~/.irssi/scripts/autorun/adv_windowlist.pl
curl https://scripts.irssi.org/scripts/nickcolor.pl --create-dirs -o ~/.irssi/scripts/autorun/nickcolor.pl
curl https://scripts.irssi.org/scripts/usercount.pl --create-dirs -o ~/.irssi/scripts/autorun/usercount.pl
curl https://scripts.irssi.org/scripts/mouse.pl --create-dirs -o ~/.irssi/scripts/autorun/mouse.pl

echo "\n=== init finished ===\n"

