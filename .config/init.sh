echo
echo "=== running init script ==="
echo

# utilities

macos() {
    [[ $(uname) = "Darwin" ]]
}

linux() {
    [[ $(uname) = "Linux" ]]
}

# checks

if ! macos && ! linux; then
    echo "only compatible with mac or linux. quitting."
fi

# installation

echo
echo "=== installing homebrew ==="
echo

if linux; then
    sudo apt update
    sudo apt install build-essential procps curl file git
fi

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew tap Homebrew/bundle

echo
echo "=== authenticating with github ==="
echo

brew install gh
read -p "github token: " -s token; echo
read -p "ssh passphrase: " -s passphrase; echo
read -p "device title: " -s title; echo
echo $token | gh auth login --with-token
ssh-keygen -t ed25519 -C "cooper@cxreiff.com" -N "$passphrase" -f github
eval "$(ssh-agent -s)"
gh ssh-key add ~/.ssh/github.pub -t "$title"

if macos; then
    printf "Host github.com\n  \
        AddKeysToAgent yes\n  \
        UseKeychain yes\n  \
        IdentityFile ~/.ssh/github" > ~/.ssh/config
    echo $passphrase | ssh-add --apple-use-keychain ~/.ssh/github
else
    echo $passphrase | ssh-add -p ~/.ssh/github
fi

echo
echo "=== cloning dotfiles ==="
echo

alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
git clone --bare git@github.com:cxreiff/dotfiles.git $HOME/.dotfiles
mkdir -p .dotbackup
config checkout 2>&1 | egrep "\s+\." | awk {'print $1'} | xargs -I{} mv {} .dotbackup/{}
dotfiles checkout
dotfiles config --local status.showUntrackedFiles no

echo
echo "=== installing brews ==="
echo

brew bundle --file ~/.config/Brewfile

echo
echo "=== installing rust ==="
echo

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

echo
echo "=== installing pnpm ==="
echo

curl -fsSL https://get.pnpm.io/install.sh | sh -

echo
echo "=== installing node ==="
echo

pnpm env use --global lts

echo
echo "=== installing vim-plug ==="
echo

curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

echo
echo "=== installing tmux plugin manager ==="
echo

git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

echo
echo "=== installing irssi plugins ==="
echo

curl https://scripts.irssi.org/scripts/adv_windowlist.pl --create-dirs -o ~/.irssi/scripts/autorun/adv_windowlist.pl
curl https://scripts.irssi.org/scripts/nickcolor.pl --create-dirs -o ~/.irssi/scripts/autorun/nickcolor.pl
curl https://scripts.irssi.org/scripts/usercount.pl --create-dirs -o ~/.irssi/scripts/autorun/usercount.pl
curl https://scripts.irssi.org/scripts/mouse.pl --create-dirs -o ~/.irssi/scripts/autorun/mouse.pl

if macos; then
    echo
    echo "=== creating developer folder ==="
    echo

    touch ~/Developer

    echo
    echo "=== configuring iterm ==="
    echo

    defaults write com.googlecode.iterm2.plist PrefsCustomFolder -string "~/.config/iterm2"
    defaults write com.googlecode.iterm2.plist LoadPrefsFromCustomFolder -bool true

elif linux; then
    echo
    echo "=== quieting login ==="
    echo

    touch ~/.hushlogin
fi

echo
echo "=== init finished ==="
echo

