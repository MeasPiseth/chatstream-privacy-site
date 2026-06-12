# chatstream-privacy-site

## Cursor Cloud specific instructions

This repository is a **static HTML/CSS site** (no build system, package manager, tests, or
runtime dependencies). It contains the privacy policy and data deletion pages for the
"ChatStreamingManage" app: `privacy-policy.html`, `data-deletion.html`, and `style.css`.

### Running it

There is nothing to install. Serve the static files from the repo root with any static
file server, e.g.:

```
python3 -m http.server 8000
```

Then open `http://localhost:8000/privacy-policy.html`. The privacy policy links to
`data-deletion.html` via the "this form" link.

### Lint / test / build

There are no lint, test, or build steps — the files are plain static assets edited directly.
