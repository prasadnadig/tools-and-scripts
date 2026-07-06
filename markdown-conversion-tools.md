# Markdown to HTML conversion with Pandoc

## On a Mac
### Pre-requisites
Install puppetter
```bash
npm install -g puppeteer  
```

### Markdown → HTML (basic)
*Install pandoc to export markdown files as html or pdf.* 
```bash
brew install pandoc
```

```bash
pandoc notes.md \
  -t html \
  -F mermaid-filter \
  --mathjax \
  -o notes.html
```
This works as long as your markdown is basic native markdown without any mermaid diagrams or latex math. For mermaid diagrams, you need to install mermaid-filter as well; see below.
------You can also install mermaid-filter to render mermaid diagrams in the exported html/pdf.

### Markdown → HTML with math 
If your markdown has LaTeX-style math, you need to include the `--mathjax` option when converting to HTML.

```bash
pandoc notes.md \
  -t html \
  --mathjax \
  -o notes.html
```

### Markdown → HTML with Mermaid
If your markdown has mermaid diagrams, you need to install `mermaid-filter` and include the `-F mermaid-filter` option when converting to HTML.

```
brew install node
npm install --global mermaid-filter @mermaid-js/mermaid-cli
```
```
pandoc notes.md \
  -t html \
  -F mermaid-filter \
  -o notes.html
```

### Markdown → HTML with Mermaid + math
Use both `--mathjax` and `-F mermaid-filter` options when converting to HTML if your markdown has both mermaid diagrams and LaTeX-style math.

```bash
pandoc notes.md \
  -t html \
  -F mermaid-filter \
  --mathjax \
  -o notes.html
```

### Markdown → PDF with Mermaid + math (optional, a bit heavier)
(If your math is LaTeX-style, Pandoc + LaTeX will handle it in the PDF)

```bash
brew install --cask basictex
```
```bash
pandoc notes.md \
  -F mermaid-filter \
  --pdf-engine=xelatex \
  -o notes.pdf
```

## Using a Container Image
A very minimal and well-supported way to do this is to use the official Pandoc Docker images. They’re designed exactly for “Markdown → HTML/PDF” and come in small variants.

### Minimal image for Markdown → HTML
```bash
# From the folder containing your markdown file file.md
docker run --rm -v "$(pwd):/data" pandoc/core \
  file.md -o file.html
```

- $(pwd):/data mounts your current directory into /data inside the container.
- file.md is the input; file.html is the output written back to your host directory.

You can add options like --standalone or --mathjax if needed; mathjax is needed to properly render math formulae

```bash
docker run --rm -v "$(pwd):/data" pandoc/core \
  file.md -o file.html --standalone --mathjax
```

### Minimal image for Markdown → PDF
For PDF, you need Pandoc plus a small LaTeX install. Use the official pandoc/latex image.

```bash
# From the folder containing your file.md
docker run --rm -v "$(pwd):/data" pandoc/latex \
  file.md -o file.pdf
```

You can pass extra Pandoc flags (e.g., for fonts/engines):

```bash
docker run --rm -v "$(pwd):/data" pandoc/latex \
  file.md -o file.pdf --pdf-engine=xelatex
```