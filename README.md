A personal fork of [Factory Floor](https://github.com/alltuner/factoryfloor) and [Vibefloor](https://github.com/AndresGonzalez5/vibefloor)

```
git clone --bare git@github.com:org/project.git .bare
echo "gitdir: ./.bare" > .git
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch --all --prune
```

```
# fish
set def (git symbolic-ref --short HEAD)   # the bare clone left HEAD on the remote default
git config wt.default $def
git branch root $def
git symbolic-ref HEAD refs/heads/root
git worktree add $def
```

```
# bash
def=$(git symbolic-ref --short HEAD)   # the bare clone left HEAD on the remote default
git config wt.default "$def"
git branch root "$def"
git symbolic-ref HEAD refs/heads/root
git worktree add "$def"
```
