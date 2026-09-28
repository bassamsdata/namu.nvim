(() => {
  "use strict";
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => Array.from(document.querySelectorAll(selector));

  const root = document.documentElement;
  const fontSizes = [0.9, 1, 1.1, 1.2, 1.3];
  let fontIndex = Number(root.dataset.fontIndex || 1);
  let theme = root.dataset.theme || "light";
  function applyAppearance(announce = false) {
    root.dataset.theme = theme;
    root.dataset.fontIndex = String(fontIndex);
    root.style.setProperty("--font-scale", fontSizes[fontIndex]);
    $("#font-smaller").disabled = fontIndex === 0;
    $("#font-larger").disabled = fontIndex === fontSizes.length - 1;
    const dark = theme === "dark";
    const label = dark ? "Switch to light mode" : "Switch to dark mode";
    $("#theme-toggle").setAttribute("aria-label", label);
    $("#theme-toggle").setAttribute("title", label);
    $("#theme-toggle").setAttribute("aria-pressed", String(dark));
    if (announce) {
      $("#appearance-status").textContent = `${dark ? "Dark" : "Light"} mode. Font size ${Math.round(fontSizes[fontIndex] * 100)} percent.`;
      try { localStorage.setItem("namu-docs-appearance", JSON.stringify({ theme, fontIndex })); } catch {}
      document.dispatchEvent(new Event("namu:appearancechange"));
    }
  }
  $("#font-smaller").addEventListener("click", () => {
    fontIndex = Math.max(0, fontIndex - 1);
    applyAppearance(true);
  });
  $("#font-larger").addEventListener("click", () => {
    fontIndex = Math.min(fontSizes.length - 1, fontIndex + 1);
    applyAppearance(true);
  });
  $("#theme-toggle").addEventListener("click", () => {
    theme = theme === "dark" ? "light" : "dark";
    applyAppearance(true);
  });
  applyAppearance();

  const menu = $(".menu-button");
  const sidebar = $("#sidebar");
  menu?.addEventListener("click", () => {
    const open = menu.getAttribute("aria-expanded") !== "true";
    sidebar.classList.toggle("open", open);
    menu.setAttribute("aria-expanded", String(open));
  });
  sidebar?.querySelectorAll("a").forEach((link) => link.addEventListener("click", () => {
    sidebar.classList.remove("open");
    menu.setAttribute("aria-expanded", "false");
  }));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && sidebar?.classList.contains("open")) {
      sidebar.classList.remove("open");
      menu.setAttribute("aria-expanded", "false");
      menu.focus();
    }
  });
  const pageName = location.pathname.split("/").pop() || "index.html";
  if (pageName !== "index.html") {
    sidebar?.querySelector(`a[href="${pageName}"]`)?.classList.add("active");
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        sidebar.querySelectorAll("nav a").forEach((link) => link.classList.toggle("active", link.hash === `#${entry.target.id}`));
      });
    }, { rootMargin: "-10% 0px -55% 0px", threshold: 0 });
    $$("main section[id]").forEach((section) => observer.observe(section));
  }

  $$(".copy-button").forEach((button) => button.addEventListener("click", async () => {
    const text = button.parentElement.querySelector("pre").textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
      setTimeout(() => { button.textContent = "Copy"; }, 1600);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(button.parentElement.querySelector("pre"));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = "Select & copy";
      setTimeout(() => { button.textContent = "Copy"; }, 2200);
    }
  }));

  function selectTab(button, buttons) {
    buttons.forEach((tab) => {
      const selected = tab === button;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute("aria-controls"));
      if (panel && !tab.dataset.feature) panel.hidden = !selected;
    });
  }
  const installTabs = $$(".tabs [role=tab]");
  installTabs.forEach((button, index) => {
    button.addEventListener("click", () => selectTab(button, installTabs));
    button.addEventListener("keydown", (event) => {
      let next = index;
      if (event.key === "ArrowRight") next = (index + 1) % installTabs.length;
      else if (event.key === "ArrowLeft") next = (index + installTabs.length - 1) % installTabs.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = installTabs.length - 1;
      else return;
      event.preventDefault();
      selectTab(installTabs[next], installTabs);
      installTabs[next].focus();
    });
  });

  const features = {
    symbols: { title: "Symbols, with their structure intact", description: "Search the current buffer and preview a symbol's location as you move. Tree guides show the relationship between parents and children. Filter by kind when you only need functions or classes.", command: ":Namu symbols", recording: "https://github.com/user-attachments/assets/bb2a14da-cba0-4ae7-b826-4ceb1c828b79", rows: ["Garden", "├─ seed()", "├─ water()", "└─ harvest()"], active: 2 },
    jump: { title: "Press ;. Pick a letter. Jump.", description: "Jump labels give visible rows their own keys. Press ; in a picker, then a label to select that item directly. Manual activation is the default; you can also enable automatic labels for small pickers.", command: "; → a displayed label → select", recording: "#picker-demo", recordingText: "Try the interactive example", rows: ["Garden", "├─ seed()", "├─ water()", "└─ harvest()"], labels: true, active: 2 },
    workspace: { title: "Look across your files", description: "Workspace search asks your language server for project symbols. Watchtower gathers symbols across open buffers so you can navigate without switching files first.", command: ":Namu workspace  /  :Namu watchtower", recording: "https://github.com/user-attachments/assets/e548c3ea-6cdb-4f20-9569-175c57b31039", rows: ["garden.lua", "└─ Garden.water", "plot.lua", "└─ Plot.prepare"], active: 1 },
    diagnostics: { title: "See the problem in context", description: "Browse current-buffer, open-buffer, or available workspace diagnostics. Live preview takes you to the affected code, and supported language servers can provide code actions.", command: ":Namu diagnostics  /  :Namu diagnostics workspace", recording: "https://github.com/user-attachments/assets/02dc0ce5-c87a-445f-a477-ac4f411c6592", rows: ["garden.lua:8", "└─ Unused local variable", "plot.lua:24", "└─ Undefined global"], active: 1 },
    calls: { title: "Follow the path through a function", description: "Explore callers and callees with a language server that supports call hierarchy. View incoming calls, outgoing calls, or both. Control the depth and recursive-call display in configuration.", command: ":Namu call in  /  :Namu call out  /  :Namu call both", recording: "https://github.com/user-attachments/assets/5d30214a-a5d8-46e3-89d4-be71203501e7", rows: ["harvest()", "├─ collect()", "│  └─ store()", "└─ reset()"], active: 1 },
    actions: { title: "Do more with the selection", description: "Select multiple symbols, send locations to quickfix, yank their text, or open a split. Add symbol context to CodeCompanion or Avante when those plugins are installed.", command: "<Tab> select  /  <C-q> quickfix  /  <C-y> yank", recording: "actions.html", recordingText: "Read the actions guide", rows: ["○ Garden", "● ├─ seed()", "● ├─ water()", "○ └─ harvest()"], active: 2 },
    extras: { title: "More ways to find your way", description: "Use Tree-sitter symbols with a parser for your language. Enable ctags, a colorscheme picker, or a vim.ui.select replacement as needed. Optional pickers are configured independently.", command: ":Namu treesitter  /  :Namu ctags  /  :Namu colorscheme", recording: "https://github.com/user-attachments/assets/09ccc178-c067-45bb-8f86-3f8aa183e69d", rows: ["Tree-sitter symbols", "Ctags symbols", "Colorschemes", "vim.ui.select"], active: 0 },
  };
  const featureButtons = $$("[data-feature]");
  function showFeature(button) {
    const key = button.dataset.feature;
    const info = features[key];
    const media = window.NAMU_MEDIA?.[key];
    selectTab(button, featureButtons);
    $("#feature-panel").setAttribute("aria-labelledby", button.id);
    $("#feature-title").textContent = info.title;
    $("#feature-description").textContent = info.description;
    $("#feature-command").textContent = info.command;
    const link = $("#feature-recording");
    link.href = info.recording;
    link.textContent = info.recordingText || "View recording";
    const target = $("#feature-media");
    target.replaceChildren();
    if (media?.src) {
      const figure = document.createElement("figure");
      const asset = document.createElement(media.type === "image" ? "img" : "video");
      if (media.type === "image") {
        asset.alt = media.alt || info.title;
        asset.loading = "lazy";
      } else {
        asset.controls = true;
        asset.preload = "none";
        asset.playsInline = true;
        asset.setAttribute("aria-label", media.alt || info.title);
        if (media.poster) asset.poster = media.poster;
        if (media.captions) {
          const track = document.createElement("track");
          track.kind = "captions";
          track.srclang = "en";
          track.label = "English";
          track.src = media.captions;
          asset.append(track);
        }
      }
      asset.src = media.src;
      const fallback = () => {
        target.replaceChildren(illustration(info, key));
        const note = document.createElement("p");
        note.className = "section-note";
        note.textContent = "This recording could not be loaded.";
        target.append(note);
      };
      asset.addEventListener("error", fallback);
      figure.append(asset);
      if (media.caption) {
        const caption = document.createElement("figcaption");
        caption.textContent = media.caption;
        figure.append(caption);
      }
      target.append(figure);
    } else {
      target.append(illustration(info, key));
    }
  }
  function illustration(info, key) {
    const screen = document.createElement("div");
    screen.className = "feature-illustration";
    screen.setAttribute("aria-label", `${key} example view`);
    const title = document.createElement("div");
    title.className = "illustration-title";
    const name = document.createElement("span");
    name.textContent = `Namu / ${key}`;
    const tag = document.createElement("span");
    tag.textContent = "Example view";
    title.append(name, tag);
    screen.append(title);
    info.rows.forEach((text, index) => {
      const row = document.createElement("div");
      row.className = "illustration-row" + (index === info.active ? " selected" : "");
      const label = document.createElement("span");
      label.textContent = info.labels ? "asdf"[index] : index === info.active ? "›" : " ";
      const content = document.createElement("div");
      content.textContent = text;
      row.append(label, content);
      screen.append(row);
    });
    return screen;
  }
  featureButtons.forEach((button, index) => {
    button.addEventListener("click", () => showFeature(button));
    button.addEventListener("keydown", (event) => {
      let next = index;
      if (event.key === "ArrowDown" || event.key === "ArrowRight") next = (index + 1) % featureButtons.length;
      else if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = (index + featureButtons.length - 1) % featureButtons.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = featureButtons.length - 1;
      else return;
      event.preventDefault();
      showFeature(featureButtons[next]);
      featureButtons[next].focus();
      featureButtons[next].scrollIntoView({ block: "nearest", inline: "nearest" });
    });
  });
  if (featureButtons.length) showFeature(featureButtons[0]);

  const demo = $("#picker-demo");
  if (!demo) return;
  const filter = $("#symbol-filter");
  const list = $("#symbol-list");
  const toggle = $("#toggle-labels");
  const labels = "asdfghjkl";
  const symbols = [
    { name: "Garden", kind: "M", line: 1, end_line: 20, tree: "" },
    { name: "seed", kind: "ƒ", line: 4, end_line: 6, tree: "├─ " },
    { name: "water", kind: "ƒ", line: 8, end_line: 10, tree: "├─ " },
    { name: "harvest", kind: "ƒ", line: 12, end_line: 14, tree: "├─ " },
    { name: "reset", kind: "ƒ", line: 16, end_line: 18, tree: "└─ " },
  ];
  const lines = [
    'local Garden = {}', '', '-- Seed a new plot.',
    'function Garden.seed(plot)', '  return plot:prepare()', 'end', '',
    'function Garden.water(plot)', '  plot:grow()', 'end', '',
    'function Garden.harvest(plot)', '  return plot:collect()',
    'end', '', 'function Garden.reset(plot)', '  plot:clear()', 'end', '', 'return Garden',
  ];
  $(".code-gutter").innerHTML = lines.map((_, i) => i + 1).join("<br>");
  const code = $("#demo-code");
  const escape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  lines.forEach((text, index) => {
    const line = document.createElement("span");
    line.className = "code-line";
    line.dataset.line = String(index + 1);
    line.innerHTML = text.startsWith("--") ? `<span class="lua-comment">${escape(text)}</span>` : escape(text).replace(/\b(local|function|return|end)\b/g, '<span class="lua-keyword">$1</span>').replace(/(Garden\.\w+)/g, '<span class="lua-function">$1</span>');
    code.append(line);
  });
  let filtered = symbols.slice();
  let selected = 0;
  let jump = false;
  let committed = false;
  filter.setAttribute("aria-controls", "symbol-list");
  function highlight() {
    const item = filtered[selected];
    $$(".code-line").forEach((line) => {
      const number = Number(line.dataset.line);
      line.classList.toggle("current", Boolean(item && number >= item.line && number <= item.end_line));
      line.classList.toggle("current-start", Boolean(item && number === item.line));
    });
    $("#selected-location").textContent = item ? `Lines ${item.line}–${item.end_line}` : "—";
    // Keep the whole function in the exposed code area above the mobile picker.
    if (item && matchMedia("(max-width: 960px)").matches) {
      const start = code.querySelector(`[data-line="${item.line}"]`);
      code.scrollTop = Math.max(0, start.offsetTop - code.offsetTop - 24);
    }
  }
  function previewItem(index) {
    if (selected === index) return;
    selected = index;
    committed = false;
    list.querySelectorAll(".symbol-row").forEach((row, at) => {
      row.classList.toggle("selected", at === index);
      row.setAttribute("aria-selected", String(at === index));
    });
    list.setAttribute("aria-activedescendant", `symbol-${index}`);
    $("#demo-mode").textContent = jump ? "Jump mode" : "Filtering";
    highlight();
  }
  function render() {
    list.replaceChildren();
    $("#result-count").textContent = `${filtered.length} ${filtered.length === 1 ? "item" : "items"}`;
    list.removeAttribute("aria-activedescendant");
    filter.removeAttribute("aria-activedescendant");
    if (!filtered.length) {
      const empty = document.createElement("p");
      empty.className = "no-results";
      empty.textContent = "No symbols match. Try another query.";
      list.append(empty);
    }
    filtered.forEach((item, index) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "symbol-row" + (index === selected ? " selected" : "");
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === selected));
      row.id = `symbol-${index}`;
      row.tabIndex = -1;
      for (const [className, text] of [
        [jump ? "label" : "current-arrow", jump ? labels[index] : index === selected ? "›" : " "],
        ["tree", item.tree], ["symbol-kind", item.kind], ["symbol-name", item.name], ["line-number", String(item.line)],
      ]) {
        const span = document.createElement("span");
        span.className = className;
        span.textContent = text;
        if (className !== "symbol-name") span.setAttribute("aria-hidden", "true");
        row.append(span);
      }
      row.addEventListener("pointerenter", (event) => {
        if (event.pointerType === "mouse" || event.pointerType === "pen") previewItem(index);
      });
      row.addEventListener("click", () => {
        selected = index;
        choose();
        list.focus();
      });
      list.append(row);
    });
    if (filtered.length) list.setAttribute("aria-activedescendant", `symbol-${selected}`);
    $("#demo-mode").textContent = jump ? "Jump mode" : committed ? `Selected ${filtered[selected]?.name || ""}` : "Filtering";
    toggle.setAttribute("aria-pressed", String(jump));
    toggle.replaceChildren(document.createTextNode(jump ? "Hide jump labels " : "Show jump labels "));
    const key = document.createElement("kbd");
    key.textContent = ";";
    toggle.append(key);
    filter.readOnly = jump;
    highlight();
  }
  function choose() {
    if (!filtered.length) return;
    jump = false;
    committed = true;
    render();
  }
  function toggleJump() {
    if (!filtered.length) return;
    jump = !jump;
    committed = false;
    render();
    filter.focus();
  }
  filter.addEventListener("input", () => {
    const query = filter.value.toLowerCase().replace(/\s/g, "");
    filtered = symbols.filter((symbol) => {
      let at = 0;
      for (const char of symbol.name.toLowerCase()) if (char === query[at]) at++;
      return at === query.length;
    });
    selected = 0;
    committed = false;
    render();
  });
  function demoKeys(event) {
    if (event.key === ";") { event.preventDefault(); toggleJump(); }
    else if (event.key === "Escape") {
      event.preventDefault();
      if (jump) { jump = false; render(); }
      else { filter.value = ""; filter.dispatchEvent(new Event("input")); }
    } else if (jump && labels.includes(event.key) && event.key.length === 1) {
      const index = labels.indexOf(event.key);
      if (index < filtered.length) { event.preventDefault(); selected = index; choose(); }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (filtered.length) selected = (selected + (event.key === "ArrowDown" ? 1 : filtered.length - 1)) % filtered.length;
      committed = false;
      render();
    } else if (event.key === "Enter") { event.preventDefault(); choose(); }
  }
  demo.addEventListener("keydown", demoKeys);
  toggle.addEventListener("click", toggleJump);
  window.addEventListener("resize", highlight);
  document.addEventListener("namu:appearancechange", () => requestAnimationFrame(highlight));
  render();
})();
