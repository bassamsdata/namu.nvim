(() => {
  "use strict";
  const demo = document.querySelector("#sidebar-example");
  if (!demo) return;
  const $ = (selector) => demo.querySelector(selector);
  const files = {
    "garden.lua": {
      lines: ["local Garden = {}", "", "function Garden.seed(plot)", "  return plot:prepare()", "end", "", "function Garden.water(plot)", "  plot:grow()", "end", "", "function Garden.harvest(plot)", "  return plot:collect()", "end", "", "return Garden"],
      symbols: [{ name: "Garden", kind: "Module", line: 1, end: 15 }, { name: "seed", kind: "Function", line: 3, end: 5 }, { name: "water", kind: "Function", line: 7, end: 9 }, { name: "harvest", kind: "Function", line: 11, end: 13 }],
    },
    "plot.lua": {
      lines: ["local Plot = {}", "", "function Plot.prepare()", "  return { ready = true }", "end", "", "function Plot.grow()", "  return 'growing'", "end", "", "function Plot.collect()", "  return 'harvest'", "end", "", "return Plot"],
      symbols: [{ name: "Plot", kind: "Module", line: 1, end: 15 }, { name: "prepare", kind: "Function", line: 3, end: 5 }, { name: "grow", kind: "Function", line: 7, end: 9 }, { name: "collect", kind: "Function", line: 11, end: 13 }],
    },
  };
  const all = Object.entries(files).flatMap(([file, data]) => data.symbols.map((symbol) => ({ ...symbol, file, id: `${file}:${symbol.line}` })));
  const storageKey = "namu-sidebar-demo-favorites";
  let favorites = [];
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey));
    if (Array.isArray(saved)) favorites = all.filter((item) => saved.includes(item.id)).map((item) => item.id);
  } catch {}
  let file = "garden.lua";
  let cursor = 1;
  let favoriteView = false;
  let preview = true;
  let follow = true;
  let labels = false;
  let selected = all[0].id;
  let previousKey = "";
  let visible = [];
  const labelKeys = "asdhjklwertyuiozxcvbn";
  const search = $("#sb-search");
  const results = $("#sb-results");

  function announce(message) { $("#sb-status").textContent = message; }
  function selectedItem() { return visible.find((item) => item.id === selected); }
  function persist() {
    try { localStorage.setItem(storageKey, JSON.stringify(favorites)); }
    catch { announce("Favorites work here until this page closes; browser storage is unavailable."); }
  }
  function followCursor() {
    if (!follow) return;
    const matches = visible.filter((item) => item.file === file && item.line <= cursor && item.end >= cursor);
    matches.sort((a, b) => (a.end - a.line) - (b.end - b.line));
    if (matches[0]) selected = matches[0].id;
  }
  function drawCode() {
    const item = selectedItem();
    const shownFile = preview && item ? item.file : file;
    const code = $("#sb-code");
    code.replaceChildren();
    code.setAttribute("aria-label", `${shownFile} code lines; click to move the cursor`);
    files[shownFile].lines.forEach((text, index) => {
      const number = index + 1;
      const line = document.createElement("button");
      line.type = "button";
      line.className = "sb-code-line";
      line.dataset.line = number;
      line.setAttribute("aria-label", `${shownFile} line ${number}: ${text || "blank"}`);
      line.classList.toggle("sb-range", Boolean(preview && item && number >= item.line && number <= item.end));
      line.classList.toggle("sb-cursor", shownFile === file && number === cursor);
      line.textContent = text || " ";
      line.addEventListener("click", () => {
        file = shownFile;
        cursor = number;
        draw();
        followCursor();
        draw();
        $("#sb-code").children[index]?.focus({ preventScroll: true });
        announce(`Code cursor: ${file}:${cursor}. Following ${follow ? "on" : "off"}.`);
      });
      code.append(line);
    });
    $("#sb-location").textContent = `${shownFile}:${preview && item ? item.line : cursor}`;
  }
  function draw() {
    const query = search.value.trim().toLowerCase();
    const kind = /^\/(fn|mo)/.exec(query);
    const text = kind ? query.slice(kind[0].length) : query;
    visible = all.filter((item) => (favoriteView ? favorites.includes(item.id) : item.file === file)
      && (!kind || item.kind === (kind[1] === "fn" ? "Function" : "Module"))
      && `${item.name} ${favoriteView ? item.file : ""}`.toLowerCase().includes(text));
    if (!visible.some((item) => item.id === selected)) selected = visible[0]?.id;
    results.replaceChildren();
    if (!visible.length) {
      const empty = document.createElement("p");
      empty.className = "no-results";
      empty.textContent = favoriteView && !favorites.length ? "Save a symbol with m, then find it here." : "No matching symbols. Try /fn or clear the search.";
      results.append(empty);
    }
    visible.forEach((item, index) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "symbol-row" + (item.id === selected ? " selected" : "");
      row.setAttribute("aria-pressed", String(item.id === selected));
      row.setAttribute("aria-label", `${item.name}, ${item.kind}, ${item.file} line ${item.line}${favorites.includes(item.id) ? ", saved favorite" : ""}`);
      for (const [className, content] of [[labels ? "label" : "current-arrow", labels ? labelKeys[index] : item.id === selected ? "›" : " "], ["symbol-kind", item.kind === "Function" ? "ƒ" : "◇"], ["symbol-name", item.name], ["line-number", `${favorites.includes(item.id) ? "★ " : ""}${favoriteView ? item.file + ":" : ""}${item.line}`]]) {
        const span = document.createElement("span");
        span.className = className;
        span.textContent = content;
        row.append(span);
      }
      row.addEventListener("click", () => {
        selected = item.id;
        draw();
        results.children[index]?.focus({ preventScroll: true });
        announce(`Selected ${item.name}. Enter jumps; m saves a favorite.`);
      });
      results.append(row);
    });
    $("#sb-symbols").setAttribute("aria-pressed", String(!favoriteView));
    $("#sb-favorites").setAttribute("aria-pressed", String(favoriteView));
    $("#sb-favorite-count").textContent = favorites.length;
    $("#sb-preview").setAttribute("aria-pressed", String(preview));
    $("#sb-follow").setAttribute("aria-pressed", String(follow));
    $("#sb-labels").setAttribute("aria-pressed", String(labels));
    $("#sb-remove").hidden = !favoriteView;
    $("#sb-remove").disabled = !selectedItem();
    $("#sb-save").disabled = !selectedItem() || favorites.includes(selected);
    $("#sb-jump").disabled = !selectedItem();
    demo.querySelectorAll("[data-sb-file]").forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.sbFile === file)));
    drawCode();
  }
  function save() {
    const item = selectedItem();
    if (!item || favorites.includes(item.id)) return;
    favorites.push(item.id);
    announce(`Saved ${item.name} to favorites. Reopen this page to keep your saved examples.`);
    persist();
    draw();
  }
  function remove() {
    const item = selectedItem();
    if (!favoriteView || !item) return;
    favorites = favorites.filter((id) => id !== item.id);
    announce(`Removed ${item.name} from favorites.`);
    persist();
    draw();
  }
  function jump() {
    const item = selectedItem();
    if (!item) return;
    file = item.file;
    cursor = item.line;
    labels = false;
    draw();
    $("#sb-code").children[cursor - 1]?.focus({ preventScroll: true });
    announce(`Jumped to ${file}:${cursor}. The sidebar stays open.`);
  }
  function toggleHelp() {
    const help = $("#sb-help");
    help.hidden = !help.hidden;
    $("#sb-help-toggle").setAttribute("aria-expanded", String(!help.hidden));
  }
  demo.querySelectorAll("[data-sb-file]").forEach((button) => button.addEventListener("click", () => {
    file = button.dataset.sbFile;
    cursor = 1;
    draw();
    followCursor();
    draw();
    announce(`Opened ${file}; symbols refreshed. Your favorites stay saved.`);
  }));
  for (const [id, value] of [["#sb-symbols", false], ["#sb-favorites", true]]) {
    $(id).addEventListener("click", () => {
      favoriteView = value;
      search.value = "";
      draw();
      announce(value ? `${favorites.length} saved favorites.` : `Symbols in ${file}.`);
    });
  }
  $("#sb-preview").addEventListener("click", () => { preview = !preview; draw(); announce(`Preview ${preview ? "on" : "off"}.`); });
  $("#sb-follow").addEventListener("click", () => { follow = !follow; followCursor(); draw(); announce(`Code following ${follow ? "on" : "off"}.`); });
  $("#sb-labels").addEventListener("click", () => { labels = !labels; draw(); });
  $("#sb-help-toggle").addEventListener("click", toggleHelp);
  $("#sb-save").addEventListener("click", save);
  $("#sb-remove").addEventListener("click", remove);
  $("#sb-jump").addEventListener("click", jump);
  search.addEventListener("input", () => { previousKey = ""; labels = false; draw(); });
  demo.addEventListener("pointerdown", () => { previousKey = ""; });
  demo.addEventListener("keydown", (event) => {
    const prefix = previousKey;
    previousKey = "";
    const inSearch = event.target === search;
    const inCode = event.target.closest(".sb-code");
    if (event.altKey || event.metaKey || (event.ctrlKey && !["n", "p", "f", "o"].includes(event.key))) return;
    if (event.key === "Escape") {
      event.preventDefault();
      if (!$("#sb-help").hidden) toggleHelp();
      else if (labels) { labels = false; draw(); }
      else if (inSearch) results.querySelector("button")?.focus();
      else $("#sb-code").children[cursor - 1]?.focus({ preventScroll: true });
      return;
    }
    if (inSearch && !event.ctrlKey) {
      if (event.key === "Enter") { event.preventDefault(); results.querySelector("button")?.focus(); }
      return;
    }
    if (inCode && !event.ctrlKey) return;
    const control = event.ctrlKey ? { f: "#sb-follow", o: "#sb-preview" }[event.key] : { p: "#sb-preview", f: "#sb-follow", ";": "#sb-labels" }[event.key];
    if (control) { event.preventDefault(); $(control).click(); }
    else if (event.key === "/") { event.preventDefault(); search.focus(); }
    else if (event.key === "m" && !event.ctrlKey) { event.preventDefault(); save(); }
    else if (event.key === "Enter" && event.target.closest(".sb-results")) { event.preventDefault(); jump(); }
    else if (prefix === "g" && event.key === "?") { event.preventDefault(); toggleHelp(); }
    else if (prefix === "d" && event.key === "d") { event.preventDefault(); remove(); }
    else if (labels && !event.ctrlKey && labelKeys.includes(event.key) && event.key.length === 1) {
      const item = visible[labelKeys.indexOf(event.key)];
      if (item) { event.preventDefault(); selected = item.id; jump(); }
    } else {
      const next = (event.ctrlKey && event.key === "n") || event.key === "ArrowDown" || (!inSearch && event.key === "j");
      const back = (event.ctrlKey && event.key === "p") || event.key === "ArrowUp" || (!inSearch && event.key === "k");
      if ((next || back) && visible.length) {
        event.preventDefault();
        const index = (visible.findIndex((item) => item.id === selected) + (next ? 1 : visible.length - 1)) % visible.length;
        selected = visible[index].id;
        draw();
        if (!inSearch) results.children[index]?.focus({ preventScroll: true });
      } else if (!event.ctrlKey && (event.key === "g" || event.key === "d")) previousKey = event.key;
    }
  });
  draw();
})();
