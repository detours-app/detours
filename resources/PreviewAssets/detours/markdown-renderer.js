(function (root) {
  "use strict";

  function lineText(state, line) {
    return state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
  }

  function parseSeverityBar(state, startLine, endLine) {
    var firstLine = lineText(state, startLine).trim();
    var contentStart = startLine;
    var closingFence = null;
    var fenceMatch = firstLine.match(/^(`{3,}|~{3,})\{=html\}\s*$/);

    if (fenceMatch) {
      contentStart += 1;
      if (contentStart >= endLine) {
        return null;
      }
      firstLine = lineText(state, contentStart).trim();
      closingFence = new RegExp("^" + fenceMatch[1].charAt(0) + "{" + fenceMatch[1].length + ",}\\s*$");
    }

    if (firstLine !== '<div class="sevbar">') {
      return null;
    }

    var cellPattern = /^\s*<div\s+class="cell\s+(c-(?:critical|high|medium|low))">\s*<span\s+class="n">([^<>]{1,32})<\/span>\s*<span\s+class="l">([^<>]{1,64})<\/span>\s*<\/div>\s*$/;
    var cells = [];
    var line = contentStart + 1;

    while (line < endLine && line - contentStart < 16) {
      var rawLine = lineText(state, line);
      if (rawLine.trim() === "</div>") {
        if (cells.length === 0) {
          return null;
        }
        var nextLine = line + 1;
        if (closingFence) {
          if (nextLine >= endLine || !closingFence.test(lineText(state, nextLine).trim())) {
            return null;
          }
          nextLine += 1;
        }
        return { cells: cells, nextLine: nextLine };
      }

      var match = rawLine.match(cellPattern);
      if (!match) {
        return null;
      }
      cells.push({ severityClass: match[1], count: match[2].trim(), label: match[3].trim() });
      line += 1;
    }

    return null;
  }

  function severityBarPlugin(md) {
    function severityBarRule(state, startLine, endLine, silent) {
      var parsed = parseSeverityBar(state, startLine, endLine);
      if (!parsed) {
        return false;
      }
      if (silent) {
        return true;
      }

      var token = state.push("detours_severity_bar", "div", 0);
      token.block = true;
      token.meta = parsed.cells;
      state.line = parsed.nextLine;
      return true;
    }

    md.block.ruler.before("fence", "detours_severity_bar", severityBarRule);
    md.renderer.rules.detours_severity_bar = function (tokens, index) {
      var cells = tokens[index].meta.map(function (cell) {
        return '<div class="cell ' + cell.severityClass + '"><span class="n">'
          + md.utils.escapeHtml(cell.count) + '</span><span class="l">'
          + md.utils.escapeHtml(cell.label) + "</span></div>";
      });
      return '<div class="sevbar">\n' + cells.join("\n") + "\n</div>\n";
    };
  }

  function highlightCode(code, language) {
    if (!root.hljs || !language || !root.hljs.getLanguage(language)) {
      return "";
    }
    try {
      return root.hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
    } catch (_) {
      return "";
    }
  }

  function render(source) {
    if (typeof root.markdownit !== "function") {
      throw new Error("markdown-it is unavailable");
    }

    var md = root.markdownit({ html: false, linkify: false, typographer: false, highlight: highlightCode });
    md.use(severityBarPlugin);
    md.renderer.rules.link_open = function () {
      return '<span class="inert-link" role="text">';
    };
    md.renderer.rules.link_close = function () {
      return "</span>";
    };
    md.renderer.rules.image = function (tokens, index) {
      var alt = tokens[index].content || "image";
      return '<span class="blocked-image">Image blocked: ' + md.utils.escapeHtml(alt) + "</span>";
    };
    return md.render(source);
  }

  root.DetoursMarkdownRenderer = { render: render };
})(window);
