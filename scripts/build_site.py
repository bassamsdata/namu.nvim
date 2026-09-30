#!/usr/bin/env python3
"""Build the static website from its landing page and the Markdown guides."""

import argparse
import html
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
GUIDES = {
    "Namu_config.md": ("configuration.html", "Configuration"),
    "recipes.md": ("recipes.html", "Recipes"),
    "action_intergration.md": ("actions.html", "Actions & integrations"),
}
LINKS = {
    "../README.md": "index.html",
    "configuration.lua": "assets/configuration.lua",
    **{source: destination for source, (destination, _) in GUIDES.items()},
}


def rewrite_links(markdown):
    def replace(match):
        url = match.group(1)
        path, separator, fragment = url.partition("#")
        if path in LINKS:
            url = LINKS[path] + separator + fragment
        elif path.startswith("../lua/"):
            url = "https://github.com/bassamsdata/namu.nvim/blob/main/" + url[3:]
        return "](" + url + ")"

    return re.sub(r"\]\(([^\s)]+)\)", replace, markdown)


def code_blocks(content):
    # Pandoc's line anchors are unnecessary in copyable snippets.
    content = re.sub(r'<a[^>]*href="#cb\d+-\d+"[^>]*></a>', "", content)
    content = re.sub(r' id="cb\d+(?:-\d+)?"', "", content)
    return re.sub(
        r"(<pre\b[^>]*>.*?</pre>)",
        r'<div class="code-block"><button class="copy-button" type="button">Copy</button>\1</div>',
        content,
        flags=re.S,
    )


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.ids = set()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            if attrs["id"] in self.ids:
                raise ValueError(f"Duplicate ID in {self.path.name}: {attrs['id']}")
            self.ids.add(attrs["id"])
        for field in ("href", "src"):
            if field in attrs:
                self.urls.append(attrs[field])


def validate(output):
    pages = {}
    for path in output.glob("*.html"):
        page = Page(path)
        page.feed(path.read_text())
        pages[path] = page
    for path, page in pages.items():
        for url in page.urls:
            parts = urlsplit(url)
            if parts.scheme or parts.netloc:
                continue
            target = (path.parent / unquote(parts.path)).resolve() if parts.path else path
            if not target.is_relative_to(output) or not target.exists():
                raise ValueError(f"Broken local link in {path.name}: {url}")
            if target in pages and parts.fragment and unquote(parts.fragment) not in pages[target].ids:
                raise ValueError(f"Missing anchor in {path.name}: {url}")
    print(f"Validated assets, links, anchors, and IDs across {len(pages)} pages.")


def build(output):
    output = output.resolve()
    source = ROOT / "site"
    # Do not overwrite source files when a caller chooses an output directory.
    docs = ROOT / "doc"
    if (
        source.is_relative_to(output) or output.is_relative_to(source)
        or docs.is_relative_to(output) or output.is_relative_to(docs)
    ):
        raise ValueError("Choose a build directory outside site/ and doc/.")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / "assets", output / "assets", dirs_exist_ok=True)
    shutil.copyfile(ROOT / "doc/configuration.lua", output / "assets/configuration.lua")
    shutil.copyfile(source / ".nojekyll", output / ".nojekyll")
    version = (ROOT / "version.txt").read_text().strip()

    def current_version(page):
        page = re.sub(r'(<span class="version">)v[^<]+', rf"\g<1>v{version}", page)
        return re.sub(r"/releases/tag/v[^\"]+", f"/releases/tag/v{version}", page)

    (output / "index.html").write_text(current_version((source / "index.html").read_text()))
    template = current_version((source / "templates/page.html").read_text())
    help_text = subprocess.run(["pandoc", "--help"], check=True, capture_output=True, text=True).stdout
    highlight = "--syntax-highlighting=pygments" if "--syntax-highlighting" in help_text else "--highlight-style=pygments"
    for source_name, (destination, title) in GUIDES.items():
        markdown = rewrite_links((ROOT / "doc" / source_name).read_text())
        content = subprocess.run(
            ["pandoc", "--from=gfm", "--to=html5", highlight],
            input=markdown, capture_output=True, text=True, check=True,
        ).stdout
        page = template.replace("{{title}}", html.escape(title)).replace("{{content}}", code_blocks(content))
        (output / destination).write_text(page)
    validate(output)
    print(f"Built Namu documentation in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_site", help="Build directory (default: _site)")
    build(parser.parse_args().output)
