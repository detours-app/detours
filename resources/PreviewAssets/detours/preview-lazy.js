(function () {
  "use strict";

  // A long file is built a screenful at a time. The rest of it rides along as plain text, which the
  // page reads but does not build anything for, and lines are added as they are scrolled towards.
  var CHUNK_LINES = 1200;
  var DISTANCE_FROM_END = 3000;

  // The page scrolls its body, not the window, so the body is what has to be watched and measured.
  function scroller() {
    var body = document.body;
    if (body && body.scrollHeight > body.clientHeight) {
      return body;
    }
    return document.scrollingElement || document.documentElement;
  }

  function start() {
    var list = document.getElementById("source-preview");
    var tail = document.getElementById("source-tail");
    if (!list || !tail) {
      return;
    }

    var rest = tail.textContent || "";
    tail.remove();
    var cursor = 0;

    function nextChunk() {
      if (cursor >= rest.length) {
        return null;
      }
      var end = cursor;
      for (var count = 0; count < CHUNK_LINES; count++) {
        var newline = rest.indexOf("\n", end);
        if (newline === -1) {
          end = rest.length;
          break;
        }
        end = newline + 1;
      }
      var slice = rest.slice(cursor, end);
      cursor = end;
      return slice;
    }

    function appendIfNeeded() {
      if (cursor >= rest.length) {
        scroller().removeEventListener("scroll", onScroll);
        window.removeEventListener("scroll", onScroll);
        return;
      }
      var view = scroller();
      var remaining = view.scrollHeight - view.scrollTop - view.clientHeight;
      if (remaining > DISTANCE_FROM_END) {
        return;
      }
      var slice = nextChunk();
      if (slice) {
        list.insertAdjacentHTML("beforeend", slice);
      }
      // Adding one chunk may still leave the end within reach, on a tall window.
      window.requestAnimationFrame(appendIfNeeded);
    }

    function onScroll() {
      appendIfNeeded();
    }

    scroller().addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("scroll", onScroll, { passive: true });
    appendIfNeeded();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
