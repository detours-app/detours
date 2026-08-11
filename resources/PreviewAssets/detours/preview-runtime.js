(function () {
  "use strict";

  function textFromTemplate(id) {
    var node = document.getElementById(id);
    if (!node) {
      return "";
    }
    return node.content ? node.content.textContent || "" : node.textContent || "";
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
    if (!target) {
      return;
    }

    if (!window.DetoursMarkdownRenderer || typeof window.DetoursMarkdownRenderer.render !== "function") {
      target.innerHTML = '<div class="warning">Detours could not load the Markdown renderer. The source view remains available.</div>';
      document.documentElement.dataset.markdownPreviewReady = "failed";
      return;
    }

    try {
      target.innerHTML = window.DetoursMarkdownRenderer.render(textFromTemplate("source-payload"));
      disableNavigation(target);
      target.dataset.renderer = "markdown-it";
      window.__detoursMarkdownPreviewHTML = target.innerHTML;
      document.documentElement.dataset.markdownPreviewReady = "true";
    } catch (_) {
      target.innerHTML = '<div class="warning">Detours could not render this Markdown document. The source view remains available.</div>';
      document.documentElement.dataset.markdownPreviewReady = "failed";
    }
  }

  function renderHTML() {
    var frame = document.getElementById("rendered-html-frame");
    if (!frame) {
      return;
    }

    var failure = document.getElementById("html-render-failure");
    if (!window.DOMPurify || typeof window.DOMPurify.sanitize !== "function") {
      frame.hidden = true;
      if (failure) {
        failure.hidden = false;
      }
      return;
    }

    var sanitized = window.DOMPurify.sanitize(textFromTemplate("html-source-payload"), {
      USE_PROFILES: { html: true },
      WHOLE_DOCUMENT: false,
      FORCE_BODY: true,
      FORBID_TAGS: ["base", "embed", "frame", "frameset", "iframe", "link", "meta", "noscript", "object", "script"],
      FORBID_ATTR: ["action", "autofocus", "cite", "data", "formaction", "href", "ping", "poster", "srcset"],
      ALLOWED_URI_REGEXP: /^data:image\/(?:avif|gif|jpeg|png|webp);base64,[a-z0-9+/=\s]+$/i
    });
    window.__detoursHTMLPreviewSanitized = sanitized;

    var framePolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; "
      + "font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; "
      + "base-uri 'none'; form-action 'none'";
    var frameDocument = "<!doctype html><html><head><meta charset=\"utf-8\">"
      + "<meta http-equiv=\"Content-Security-Policy\" content=\"" + framePolicy + "\">"
      + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><body>"
      + sanitized + "</body></html>";
    var objectURL = URL.createObjectURL(new Blob([frameDocument], { type: "text/html" }));
    var releaseObjectURL = function () {
      URL.revokeObjectURL(objectURL);
      window.removeEventListener("pagehide", releaseObjectURL);
    };
    frame.addEventListener("load", function () {
      document.documentElement.dataset.htmlPreviewReady = "true";
      releaseObjectURL();
    }, { once: true });
    window.addEventListener("pagehide", releaseObjectURL, { once: true });
    frame.src = objectURL;
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

  function bindTogglePair(renderedToggleID, sourceToggleID, renderedID, sourceID) {
    var renderedToggle = document.getElementById(renderedToggleID);
    var sourceToggle = document.getElementById(sourceToggleID);
    var rendered = document.getElementById(renderedID);
    var source = document.getElementById(sourceID);
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

  function bindToggles() {
    bindTogglePair("markdown-rendered-toggle", "markdown-source-toggle", "rendered-markdown", "source-preview");
    bindTogglePair("html-rendered-toggle", "html-source-toggle", "rendered-html", "html-source-preview");
  }

  document.addEventListener("DOMContentLoaded", function () {
    renderMarkdown();
    renderHTML();
    renderSource();
    bindToggles();
  });
})();
