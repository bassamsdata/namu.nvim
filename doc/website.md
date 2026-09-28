# Documentation website

GitHub Pages hosts the website, and Cloudflare manages DNS for `namu.bassamai.com`. Changes to the site, its Markdown guides, or `version.txt` on `main` automatically build and deploy through the [Documentation workflow](../.github/workflows/pages.yml). Pull requests build and validate the site without deploying it.

## Edit and preview

- Edit [site/index.html](../site/index.html) for the landing page and interactive example layout.
- Edit [site/assets/style.css](../site/assets/style.css) for appearance and [site/assets/app.js](../site/assets/app.js) for interactions.
- Edit [Namu_config.md](Namu_config.md), [recipes.md](recipes.md), and [action_intergration.md](action_intergration.md) for the guide pages. The build generates their HTML, including syntax highlighting and copy buttons.
- Edit [site/templates/page.html](../site/templates/page.html) for the guide pages' shared navigation and reading controls.
- Edit [configuration.lua](configuration.lua) for the downloadable starter config. The build copies it to the website.

Install Python 3.9+ and Pandoc, then run from the repository root:

```sh
python3 scripts/build_site.py
python3 -m http.server 8766 --bind 127.0.0.1 --directory _site
```

Open <http://127.0.0.1:8766/>. The build checks internal links, asset paths, anchors, and duplicate IDs. `_site/` is generated and ignored by Git; commit the sources instead. The site uses relative URLs and supports both a custom domain and GitHub's `/namu.nvim/` project path.

## Add videos or GIFs

Copy media into `site/assets/`, then update the matching entry in [site/assets/media.js](../site/assets/media.js). Paths are relative to the website's homepage:

```js
symbols: {
  src: "assets/symbols.mp4",
  type: "video",
  alt: "Searching symbols and previewing their source",
  caption: "Filter symbols, preview the code, and select a result.",
  poster: "assets/symbols-poster.webp", // Optional.
  captions: "assets/symbols.vtt", // Optional English WebVTT captions.
},
jump: {
  src: "assets/jump.gif",
  type: "image",
  alt: "Pressing semicolon and a jump label to select a symbol",
  caption: "Jump labels are enabled by default.",
},
```

The entries are `symbols`, `jump`, `workspace`, `diagnostics`, `calls`, `actions`, and `extras`. A null `src` displays an example view with a recording or guide link. Videos have native playback controls and optional captions; images use alt text. Nothing autoplays. Prefer MP4 or WebM for longer recordings and use a poster for a useful first frame.

## Connect the domain

In the repository's **Settings → Pages**, the publishing source is **GitHub Actions** and the custom domain is `namu.bassamai.com`. An Actions deployment does not need a `CNAME` file; GitHub stores the domain in the Pages settings.

In Cloudflare, open **bassamai.com → DNS → Records** and add:

| Field | Value |
| --- | --- |
| Type | `CNAME` |
| Name | `namu` |
| Target | `bassamsdata.github.io` |
| Proxy status | **DNS only** (grey cloud) |
| TTL | **Auto** |

The target is the GitHub account hostname, without `/namu.nvim/`. Only this subdomain needs the new record. After DNS resolves and GitHub issues its certificate, turn on **Enforce HTTPS** in Settings → Pages. GitHub notes that the option can take up to 24 hours to become available.

See [GitHub's custom domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site) and [Cloudflare's DNS record instructions](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/).
