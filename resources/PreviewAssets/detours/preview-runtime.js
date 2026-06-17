(function () {
  "use strict";

  function textFromTemplate(id) {
    var node = document.getElementById(id);
    return node ? node.textContent || "" : "";
  }

  function disableNavigation(root) {
    root.querySelectorAll("a").forEach(function (link) {
      link.removeAttribute("href");
      link.setAttribute("role", "text");
      link.setAttribute("tabindex", "-1");
      link.addEventListener("click", function (event) {
        event.preventDefault();
        event.stopPropagation();
      });
    });
  }

  function renderMarkdown() {
    var target = document.getElementById("rendered-markdown");
    if (!target || typeof window.markdownit !== "function") {
      return;
    }

    if (target.innerHTML.trim().length > 0) {
      disableNavigation(target);
      return;
    }

    var md = window.markdownit({ html: false, linkify: false, typographer: false });
    md.renderer.rules.link_open = function (tokens, idx, options, env, self) {
      tokens[idx].attrs = [["class", "inert-link"], ["role", "text"]];
      return self.renderToken(tokens, idx, options);
    };
    md.renderer.rules.image = function (tokens, idx) {
      var alt = tokens[idx].content || "image";
      return '<span class="blocked-image">Image blocked: ' + md.utils.escapeHtml(alt) + "</span>";
    };

    target.innerHTML = md.render(textFromTemplate("source-payload"));
    disableNavigation(target);
  }

  function renderSource() {
    document.querySelectorAll("code[data-highlight-language]").forEach(function (block) {
      if (block.getAttribute("data-static-highlight") === "true") {
        return;
      }
      if (window.hljs) {
        window.hljs.highlightElement(block);
      }
    });
  }

  function bindToggles() {
    var wrapToggle = document.getElementById("wrap-toggle");
    if (wrapToggle) {
      wrapToggle.addEventListener("click", function () {
        document.body.classList.toggle("wrap-lines");
        wrapToggle.setAttribute(
          "aria-pressed",
          document.body.classList.contains("wrap-lines") ? "true" : "false"
        );
      });
    }

    var renderedToggle = document.getElementById("markdown-rendered-toggle");
    var sourceToggle = document.getElementById("markdown-source-toggle");
    var rendered = document.getElementById("rendered-markdown");
    var source = document.getElementById("source-preview");
    function showSource(show) {
      if (!rendered || !source || !renderedToggle || !sourceToggle) {
        return;
      }
      rendered.hidden = show;
      source.hidden = !show;
      renderedToggle.setAttribute("aria-pressed", show ? "false" : "true");
      sourceToggle.setAttribute("aria-pressed", show ? "true" : "false");
    }
    if (renderedToggle) {
      renderedToggle.addEventListener("click", function () { showSource(false); });
    }
    if (sourceToggle) {
      sourceToggle.addEventListener("click", function () { showSource(true); });
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    renderMarkdown();
    renderSource();
    bindToggles();
    disableNavigation(document);
  });
})();
