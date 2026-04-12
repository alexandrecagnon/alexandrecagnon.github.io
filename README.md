# Website Initialisation

## Add publishable files

From private repo used to build, develop and test the website, copy the following files:

```
_quarto.yml
index.qmd
about.qmd
blog.qmd
notes.qmd
portfolio.qmd
projects.qmd
images/
styles/
includes/
```

## Update _quarto.yml values

Update the following elements in _quarto.yml

```yaml
project:
  output-dir: docs

website:
  site-url: https://YOUR_USERNAME.github.io/
```

## Render full static website files
At the repo root directory, generate the */docs* running

```batch
quarto render
```

## Commit and push repo changes
Push your work on a branch and open a pull request into *main* (direct pushes to *main* are not allowed; see [Merge policy](#merge-policy-branch-protection) below).

## Enable GitHub Pages on the repo
In the repo, go to Settings > Pages > Deploy from branch *main*, folder */docs*


# Website Updates

Repeat the following steps 
- Add publishable files
- Render full static website files
- Commit, push, and merge via pull request (see [Merge policy](#merge-policy-branch-protection))

## Merge policy (branch protection)

The default branch is protected in GitHub with these rules:

- **Require a pull request before merging** — every change lands on the default branch only through an approved pull request.
- **Require review from Code Owners** — at least one approving review from a [code owner](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) is required. Code owners are defined in [.github/CODEOWNERS](.github/CODEOWNERS).
- **Require status checks to pass before merging** — required CI checks must succeed on the pull request before it can be merged.
- **Do not allow bypassing the above settings** — the same rules apply to everyone, including repository administrators; merges cannot skip review or failing checks.
