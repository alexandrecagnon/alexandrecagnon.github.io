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
Commit and push to *main* branch 

## Enable GitHub Pages on the repo
In the repo, go to Settings > Pages > Deploy from branch *main*, folder */docs*


# Website Updates

Repeat the following steps 
- Add publishable files
- Render full static website files
- Commit and push repo changes