
echo "\n=== running init script ==="

# utilities

git_latest_version() {
   basename $(curl -fs -o/dev/null -w %{redirect_url} https://github.com/$1/releases/latest)
}

# installation

echo "\n=== installing homebrew ===\n"

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew tap Homebrew/bundle

echo "\n=== installing brews ===\n"

brew bundle --file ~/.config/Brewfile

echo "\n=== installing rust ===\n"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

echo "\n=== installing nvm ===\n"

latest_version_number=$(git_latest_version "nvm-sh/nvm");
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${latest_version_number}/install.sh | bash
nvm install node

echo "\n=== installing vim-plug ===\n"

curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

echo "\n=== installing irssi plugins ===\n"

curl https://scripts.irssi.org/scripts/adv_windowlist.pl --create-dirs -o ~/.irssi/scripts/autorun/adv_windowlist.pl
curl https://scripts.irssi.org/scripts/nickcolor.pl --create-dirs -o ~/.irssi/scripts/autorun/nickcolor.pl
curl https://scripts.irssi.org/scripts/usercount.pl --create-dirs -o ~/.irssi/scripts/autorun/usercount.pl
curl https://scripts.irssi.org/scripts/mouse.pl --create-dirs -o ~/.irssi/scripts/autorun/mouse.pl

echo "\n=== init finished ===\n"

