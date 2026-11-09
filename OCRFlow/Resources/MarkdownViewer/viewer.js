(function () {
  "use strict";

  const md = window.markdownit({ html: true, linkify: true, breaks: false, typographer: false });
  let figures = [];
  let figureOrdinal = 0;
  let figureLabel = "Image";

  // Figures are placeholders `![标签]()` in document order; each takes the
  // crop for its ordinal, or says what it stood for when there is none.
  md.renderer.rules.image = function (tokens, index) {
    const alt = tokens[index].content || figureLabel;
    const source = figures[figureOrdinal++];
    if (source) return '<img class="figure" alt="' + md.utils.escapeHtml(alt) + '" src="' + md.utils.escapeHtml(source) + '">';
    return '<span class="figure-missing">' + md.utils.escapeHtml(alt) + "</span>";
  };

  // --- What HTML may stay -----------------------------------------------------
  // Recognised text is text from a page, and HTML is allowed in it because
  // tables arrive as HTML. So whatever markdown-it lays out is cut down to
  // formatting before it is shown: the tags markdown-it and the recognisers
  // write keep the attributes that shape them; script, frames, forms and the
  // like go with everything in them; any other tag gives way to its text.
  // The policy in viewer.html stands behind this.

  const allowedTags = new Set([
    "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code",
    "ul", "ol", "li", "a", "img", "span", "div", "center",
    "em", "strong", "b", "i", "u", "s", "del", "ins", "mark", "small", "sup", "sub",
    "table", "caption", "colgroup", "col", "thead", "tbody", "tfoot", "tr", "th", "td"
  ]);
  const droppedTags = new Set([
    "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "noscript",
    "noembed", "noframes", "template", "svg", "math", "link", "meta", "base", "title",
    "input", "textarea", "source", "track", "portal", "xmp", "plaintext"
  ]);
  const allowedAttributes = new Set(["colspan", "rowspan", "span", "align", "start", "alt", "title", "href", "src",
                                     "class", "style"]);

  function keepsAttribute(element, name, value) {
    // A formula is put back by its placeholder; one inside an attribute
    // would come out as markup there.
    if (!allowedAttributes.has(name) || /OCRMATH\d+X/.test(value)) return false;
    const tag = element.localName;
    if (name === "href") return tag === "a" && /^(https?:|mailto:)/i.test(value.trim());
    // Only the figures' own inline images.
    if (name === "src") return tag === "img" && /^data:image\/(jpeg|png);base64,/i.test(value);
    if (name === "class") return (tag === "img" && value === "figure") || (tag === "span" && value === "figure-missing");
    // markdown-it aligns a Markdown table's columns this way.
    if (name === "style") return (tag === "th" || tag === "td") && /^text-align:(left|right|center)$/.test(value);
    if (name === "start") return tag === "ol";
    if (name === "span") return tag === "col" || tag === "colgroup";
    return true;
  }

  function sanitizeTree(root) {
    for (const element of Array.from(root.querySelectorAll("*"))) {
      // Inside something already taken out.
      if (!root.contains(element)) continue;
      const tag = element.localName;
      if (droppedTags.has(tag) || element.namespaceURI !== "http://www.w3.org/1999/xhtml") {
        element.remove();
      } else if (!allowedTags.has(tag)) {
        element.replaceWith(...element.childNodes);
      } else {
        cleanAttributes(element);
        if (tag === "img" && !element.hasAttribute("src")) element.remove();
      }
    }
    // A table being edited is cleaned from the table itself down.
    if (root.nodeType === Node.ELEMENT_NODE) cleanAttributes(root);
  }

  function cleanAttributes(element) {
    for (const attribute of Array.from(element.attributes)) {
      if (!keepsAttribute(element, attribute.name, attribute.value)) element.removeAttribute(attribute.name);
    }
  }

  // Parsed in a template, whose content is inert: nothing in it loads or
  // runs while it is cleaned.
  function sanitize(html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    sanitizeTree(template.content);
    return template.innerHTML;
  }

  // --- Maths ------------------------------------------------------------------
  // Formulas are lifted out before Markdown sees them — an underscore in
  // `d_{k}` would otherwise turn into emphasis — and set by KaTeX afterwards.

  function looksLikeMath(body) {
    const t = body.trim();
    if (!t) return false;
    if (/[\\^_]/.test(t) || /[+\-=<>*/]/.test(t)) return true;
    // `$f$` is a variable; `$2 and $3` are prices.
    return !/\s/.test(t) && t.length <= 24;
  }

  function renderMath(tex, display) {
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: "ignore",
                                         trust: false, output: "html" });
    } catch (error) {
      return '<span class="math-error">' + md.utils.escapeHtml(tex) + "</span>";
    }
  }

  function liftMath(source, store) {
    const keep = (tex, display) => {
      store.push({ tex: tex, display: display });
      return "OCRMATH" + (store.length - 1) + "X";
    };
    let text = source;
    text = text.replace(/\$\$([\s\S]+?)\$\$/g, (_, tex) => "\n\n" + keep(tex, true) + "\n\n");
    text = text.replace(/\\\[([\s\S]+?)\\\]/g, (_, tex) => "\n\n" + keep(tex, true) + "\n\n");
    // A display formula the model began and never closed — cut off by the
    // token limit — is still a formula.
    text = text.replace(/\\\[([\s\S]+)$/g, (_, tex) => "\n\n" + keep(tex, true) + "\n\n");
    text = text.replace(/\\\(([\s\S]+?)\\\)/g, (_, tex) => keep(tex, false));
    text = text.replace(/\$([^$\n]+?)\$/g, (whole, tex) => looksLikeMath(tex) ? keep(tex, false) : whole);
    return text;
  }

  function restoreMath(html, store) {
    return html.replace(/OCRMATH(\d+)X/g, (_, n) => {
      const item = store[Number(n)];
      return item ? renderMath(item.tex, item.display) : "";
    });
  }

  // In table cells the model writes LaTeX bare: `d_{model}`, `\epsilon _{ls}`,
  // `params \times 10^{6}`. A word with a command, subscript or superscript in
  // it is set as maths; a `_{ls}` set apart by a space joins the word before.
  function setBareCellMath(cell) {
    if (cell.querySelector(".katex")) return;
    const text = cell.textContent;
    if (!/[\\^_]/.test(text)) return;
    const words = [];
    for (const word of text.split(/\s+/).filter(Boolean)) {
      const last = words[words.length - 1];
      if (last && (/^[_^]/.test(word) || /[_^]$/.test(last))) words[words.length - 1] = last + word;
      else words.push(word);
    }
    cell.innerHTML = words.map(word => /[\\^_]/.test(word)
      ? renderMath(word, false) : md.utils.escapeHtml(word)).join(" ");
  }

  // Bare commands in prose — "\left\lfloor\frac{n-1}{2}\right\rfloor players
  // remain" — are maths too; the run ends at the first plain word.
  function setBareProseMath(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: node => node.parentElement.closest(".katex, code, pre, td, th")
        ? NodeFilter.FILTER_REJECT
        : (/\\[a-zA-Z]+/.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT)
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    const run = /\\[a-zA-Z]+(?:\s*(?:\{[^{}]*\}|[_^](?:\{[^{}]*\}|[A-Za-z0-9])|\\[a-zA-Z]+|[()\[\]|.,+\-=0-9]))*/g;
    for (const node of nodes) {
      const span = document.createElement("span");
      span.innerHTML = md.utils.escapeHtml(node.nodeValue).replace(run, tex => renderMath(tex, false));
      node.replaceWith(span);
    }
  }

  // --- Document ---------------------------------------------------------------

  // Each region's own text and kind, for editing it where it is shown.
  let regions = {};
  let editing = null;
  let pendingPayload = null;

  function render(payload) {
    // A document that changed underneath an edit waits until the edit is
    // done; replacing it would throw the typing away.
    if (editing) { pendingPayload = payload; return; }
    regions = {};
    for (const fragment of payload.fragments || []) {
      if (fragment.block !== null && fragment.block !== undefined && fragment.text !== null
          && fragment.text !== undefined) {
        regions[fragment.block] = { text: fragment.text, kind: fragment.kind || "text" };
      }
    }
    figures = payload.figures || [];
    figureLabel = payload.figureLabel || figureLabel;
    figureOrdinal = 0;
    if (payload.accent) {
      const root = document.documentElement.style;
      root.setProperty("--accent", payload.accent);
      root.setProperty("--accent-soft", payload.accent + "29");
    }

    const doc = document.getElementById("doc");
    const parts = (payload.fragments || []).map(fragment => {
      const store = [];
      const html = restoreMath(sanitize(md.render(liftMath(fragment.markdown || "", store))), store);
      const attributes = fragment.block === null || fragment.block === undefined
        ? "" : ' data-block="' + fragment.block + '"';
      return "<section" + attributes + (fragment.flagged ? ' class="flagged"' : "") + ">" + html + "</section>";
    });
    doc.innerHTML = parts.join("");

    for (const table of doc.querySelectorAll("table")) {
      if (!table.querySelector("th") && table.rows.length > 1) table.classList.add("implicit-header");
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      table.replaceWith(wrap);
      wrap.appendChild(table);
      for (const cell of table.querySelectorAll("td, th")) setBareCellMath(cell);
    }
    setBareProseMath(doc);
    select(payload.selected);
  }

  function select(block) {
    for (const section of document.querySelectorAll("section.selected")) section.classList.remove("selected");
    if (block === null || block === undefined) return;
    const section = document.querySelector('section[data-block="' + block + '"]');
    if (!section) return;
    // Marked, never scrolled to: the document stays where the reader left it.
    section.classList.add("selected");
  }

  function post(message) {
    if (window.webkit && window.webkit.messageHandlers.ocrflow) window.webkit.messageHandlers.ocrflow.postMessage(message);
  }

  // --- Editing in place ----------------------------------------------------
  // A double-click turns the region itself into its editor, right where it
  // is: prose becomes editable text, a table editable cells, a formula its
  // LaTeX with the result set live above it. Clicking elsewhere or ⌘↩ keeps
  // the change, Esc drops it.

  function stripDelimiters(tex) {
    let t = tex.trim();
    for (const [open, close] of [["$$", "$$"], ["\\[", "\\]"], ["\\(", "\\)"], ["$", "$"]]) {
      if (t.startsWith(open) && t.endsWith(close) && t.length > open.length + close.length) {
        return t.slice(open.length, t.length - close.length).trim();
      }
    }
    if (t.startsWith("\\[") || t.startsWith("\\(")) t = t.slice(2);
    return t.trim();
  }

  function caretAt(element, x, y) {
    const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    const selection = window.getSelection();
    if (range && element.contains(range.startContainer)) {
      selection.removeAllRanges();
      selection.addRange(range);
      return;
    }
    const end = document.createRange();
    end.selectNodeContents(element);
    end.collapse(false);
    selection.removeAllRanges();
    selection.addRange(end);
  }

  function beginEdit(section, x, y) {
    const block = Number(section.dataset.block);
    const region = regions[block];
    if (!region) return;
    // Parsed before anything changes: a table that is not one leaves the
    // region as it is, not marked as being edited with no editor in it.
    const parsed = region.kind === "table"
      ? new DOMParser().parseFromString(region.text, "text/html").querySelector("table") : null;
    if (region.kind === "table" && !parsed) return;
    if (editing) finishEdit(true);
    const original = section.innerHTML;
    section.classList.add("editing");
    let read;

    if (region.kind === "table") {
      for (const br of parsed.querySelectorAll("br")) br.replaceWith("\n");
      // The editor is a copy put into the page, cut down like the
      // rendered table; the parsed original, never shown, is what is saved.
      const live = parsed.cloneNode(true);
      const cells = Array.from(live.querySelectorAll("td, th"));
      for (const cell of cells) cell.textContent = cell.textContent;
      sanitizeTree(live);
      if (!live.querySelector("th") && live.rows.length > 1) live.classList.add("implicit-header");
      for (const cell of cells) cell.contentEditable = "plaintext-only";
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      wrap.appendChild(live);
      section.innerHTML = "";
      section.appendChild(wrap);
      const target = document.elementFromPoint(x, y);
      const cell = target && target.closest ? target.closest("td, th") : null;
      (cell && live.contains(cell) ? cell : cells[0])?.focus();
      read = () => {
        const sources = parsed.querySelectorAll("td, th");
        cells.forEach((cell, index) => {
          if (sources[index]) sources[index].innerHTML = md.utils.escapeHtml(cell.textContent).replace(/\n/g, "<br>");
        });
        return parsed.outerHTML;
      };
    } else if (region.kind === "formula") {
      const preview = document.createElement("div");
      const input = document.createElement("textarea");
      input.className = "edit-latex";
      input.rows = 1;
      input.value = region.text;
      const update = () => {
        preview.innerHTML = renderMath(stripDelimiters(input.value), true);
        input.style.height = "auto";
        input.style.height = input.scrollHeight + "px";
      };
      input.addEventListener("input", update);
      input.addEventListener("keydown", event => {
        if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); finishEdit(true); }
      });
      section.innerHTML = "";
      section.append(preview, input);
      update();
      input.focus();
      read = () => input.value;
    } else {
      const box = document.createElement("div");
      box.className = "edit-text";
      box.contentEditable = "plaintext-only";
      box.textContent = region.text;
      section.innerHTML = "";
      section.appendChild(box);
      box.focus();
      caretAt(box, x, y);
      read = () => box.innerText.replace(/\n$/, "");
    }
    editing = { block: block, section: section, original: original, text: region.text, read: read };
  }

  function finishEdit(keep) {
    if (!editing) return;
    const current = editing;
    editing = null;
    const text = keep ? current.read() : current.text;
    current.section.classList.remove("editing");
    if (keep && text !== current.text) {
      // The native side saves it and sends the document back, rendered.
      regions[current.block].text = text;
      post({ save: current.block, text: text });
    } else {
      current.section.innerHTML = current.original;
    }
    if (pendingPayload) {
      const payload = pendingPayload;
      pendingPayload = null;
      render(payload);
    }
  }

  document.addEventListener("mousedown", event => {
    if (editing && !editing.section.contains(event.target)) finishEdit(true);
  }, true);
  document.addEventListener("keydown", event => {
    if (!editing) return;
    if (event.key === "Escape") { event.preventDefault(); finishEdit(false); }
    else if (event.key === "Enter" && event.metaKey) { event.preventDefault(); finishEdit(true); }
  });

  // A click selects a region; a second click on the same one soon after opens
  // it for editing. Counted here rather than left to `dblclick`, which a slow
  // or unsteady double click — and some input methods — never produce.
  let lastClick = { block: null, time: 0 };
  document.addEventListener("click", event => {
    const section = event.target.closest("section[data-block]");
    if (!section || (editing && editing.section === section)) return;
    const block = Number(section.dataset.block);
    const now = Date.now();
    if (lastClick.block === block && now - lastClick.time < 450) {
      lastClick = { block: null, time: 0 };
      window.getSelection().removeAllRanges();
      beginEdit(section, event.clientX, event.clientY);
      return;
    }
    lastClick = { block: block, time: now };
    if (window.getSelection().isCollapsed) post({ select: block });
  });

  window.OCRFlow = { render: render, select: select };
  post({ ready: true });
})();
